"""Client：连接、请求/应答（in_reply_to 关联）、consume/deliver/ack、重连。

TLA+ 对应：tla/ReqReply.tla（ReplyCorrelates）。
"""
from __future__ import annotations

import asyncio
import time
from collections import defaultdict

from . import errors, proto
from .proto import (
    Message, FrameReader, ProtoError,
    REGISTER, HEARTBEAT, DEREGISTER, CARD,
    Q_DECLARE, Q_PUBLISH, Q_CONSUME, Q_UNCONSUME, Q_ACK, ERROR,
    T_CREATE, T_GET, T_LIST, T_CLAIM, T_RENEW, T_COMPLETE, T_FAIL, T_CANCEL,
)
import json
from .server import DEFAULT_SOCK, HEARTBEAT_LEASE_S


class ClientError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class Client:
    def __init__(self, agent_id: str, sock_path: str = DEFAULT_SOCK,
                 caps: list[str] | None = None):
        self.agent_id = agent_id
        self.sock_path = sock_path
        self.caps = caps or []
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.seq = 0
        self.peer_ack = 0
        self._pending: dict[int, asyncio.Future] = {}  # seq -> future（请求/应答）
        self._deliver_handlers: list = []
        self._event_handlers: list = []
        self._reader_task: asyncio.Task | None = None
        self._heartbeat_task: asyncio.Task | None = None
        self._subscriptions: list[tuple] = []  # 重连后重发 consume
        self._closed = False

    # ---- 连接

    async def connect(self, resume: bool = False) -> None:
        for attempt in range(10):
            try:
                self.reader, self.writer = await asyncio.open_unix_connection(
                    self.sock_path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                await asyncio.sleep(min(2 ** attempt, 30))
        else:
            raise ClientError("ASOCK-1001", f"cannot connect {self.sock_path}")
        self._closed = False
        self._reader_task = asyncio.ensure_future(self._read_loop())
        # register
        resp = await self._request(REGISTER, {
            "caps": {"cap": self.caps}, "resume": "true" if resume else "false"})
        if resp.type == ERROR and resp.body.get("code") == "AEVT-4008":
            raise ClientError("AEVT-4008", "session lost, rebuild state")
        self._heartbeat_task = asyncio.ensure_future(self._heartbeat_loop())
        # 重发订阅
        for args in self._subscriptions:
            await self.consume(*args)

    async def close(self):
        self._closed = True
        for t in (self._reader_task, self._heartbeat_task):
            if t:
                t.cancel()
        if self.writer:
            try:
                await self._request(DEREGISTER, {"reason": "shutdown"})
            except Exception:
                pass
            self.writer.close()

    async def _read_loop(self):
        fr = FrameReader()
        try:
            while not self._closed:
                data = await self.reader.read(65536)
                if not data:
                    break
                for msg in fr.feed(data):
                    self._on_message(msg)
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass
        finally:
            if not self._closed:
                asyncio.ensure_future(self._reconnect())

    async def _reconnect(self):
        await asyncio.sleep(1)
        if self._closed:
            return
        try:
            await self.connect(resume=True)
        except ClientError:
            await asyncio.sleep(5)
            if not self._closed:
                asyncio.ensure_future(self._reconnect())

    async def _heartbeat_loop(self):
        while not self._closed:
            await asyncio.sleep(HEARTBEAT_LEASE_S)
            try:
                await self._fire(HEARTBEAT, {"load": "0.0"})
            except Exception:
                break

    def _on_message(self, msg: Message):
        self.peer_ack = max(self.peer_ack, msg.ack)
        # R-01：in_reply_to 关联应答
        if msg.in_reply_to is not None and msg.in_reply_to in self._pending:
            fut = self._pending.pop(msg.in_reply_to)
            if not fut.done():
                fut.set_result(msg)
            return
        if msg.type == "queue.deliver":
            for h in self._deliver_handlers:
                asyncio.ensure_future(h(msg))
        elif msg.type == ERROR and msg.in_reply_to is None:
            pass  # 异步错误，忽略或记日志
        # events 主题的投递也走 deliver，handler 自行过滤

    # ---- 请求/应答

    def _new_seq(self) -> int:
        self.seq += 1
        return self.seq

    async def _request(self, mtype: str, body: dict,
                       timeout: float = 10.0) -> Message:
        seq = self._new_seq()
        fut = asyncio.get_running_loop().create_future()
        self._pending[seq] = fut
        await self._send(Message(type=mtype, seq=seq, ack=self.peer_ack,
                                 from_=self.agent_id, body=body))
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self._pending.pop(seq, None)

    async def _request_cdata(self, mtype: str, body: dict, cdata: dict,
                             timeout: float = 10.0) -> Message:
        seq = self._new_seq()
        fut = asyncio.get_running_loop().create_future()
        self._pending[seq] = fut
        for k in cdata:
            body.setdefault(k, "")
        await self._send(Message(type=mtype, seq=seq, ack=self.peer_ack,
                                 from_=self.agent_id, body=body), cdata=cdata)
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self._pending.pop(seq, None)

    async def _fire(self, mtype: str, body: dict):
        await self._send(Message(type=mtype, seq=self._new_seq(),
                                 ack=self.peer_ack, from_=self.agent_id,
                                 body=body))

    async def _send(self, msg: Message, cdata: dict | None = None):
        data = proto.encode_with_cdata(msg, cdata or {})
        self.writer.write(data)
        await self.writer.drain()

    def _check_error(self, resp: Message) -> Message:
        if resp.type == ERROR:
            raise ClientError(resp.body.get("code", "ASOCK-2006"),
                              resp.body.get("message", ""))
        return resp

    # ---- 高层 API（封装 queue.*）

    async def declare(self, queue: str, semantics: str,
                      max_depth: int = 10000, overflow: str = "block") -> None:
        resp = await self._request(Q_DECLARE, {
            "queue": queue, "semantics": semantics,
            "max_depth": str(max_depth), "overflow": overflow})
        self._check_error(resp)

    async def publish(self, queue: str, message_id: str,
                      payload: str) -> int:
        """返回 server 分配的 mid。"""
        seq = self._new_seq()
        fut = asyncio.get_running_loop().create_future()
        self._pending[seq] = fut
        msg = Message(type=Q_PUBLISH, seq=seq, ack=self.peer_ack,
                      from_=self.agent_id,
                      body={"queue": queue, "message_id": message_id,
                            "payload": ""})
        await self._send(msg, cdata={"payload": payload})
        try:
            resp = await asyncio.wait_for(fut, 10.0)
        finally:
            self._pending.pop(seq, None)
        self._check_error(resp)
        return int(resp.body.get("mid", "0"))

    async def submit_task(self, task_id: str, spec_bash: str,
                          queue: str = "task.dispatch",
                          timeout_s: int = 600) -> int:
        """提交任务（task 载荷约定）。message_id = task_id（幂等）。"""
        payload = (f"<task><task_id>{task_id}</task_id>"
                   f'<spec executor="bash"><![CDATA['
                   f"{proto.cdata_escape(spec_bash)}]]></spec>"
                   f"<timeout_s>{timeout_s}</timeout_s></task>")
        return await self.publish(queue, task_id, payload)

    async def consume(self, queue: str, group: str | None = None,
                      ack_wait_s: int = 30, max_deliver: int = 5,
                      filter: str | None = None,
                      since: int | None = None) -> None:
        self._subscriptions.append((queue, group, ack_wait_s, max_deliver,
                                    filter, since))
        body = {"queue": queue}
        if group:
            body["group"] = group
        body["ack_wait_s"] = str(ack_wait_s)
        body["max_deliver"] = str(max_deliver)
        if filter:
            body["filter"] = filter
        if since is not None:
            body["since"] = str(since)
        resp = await self._request(Q_CONSUME, body)
        self._check_error(resp)

    async def unconsume(self, queue: str, group: str | None = None) -> None:
        body = {"queue": queue}
        if group:
            body["group"] = group
        resp = await self._request(Q_UNCONSUME, body)
        self._check_error(resp)
        self._subscriptions = [s for s in self._subscriptions if s[0] != queue]

    async def ack(self, queue: str, group: str, delivery_id: str,
                  requeue: bool = False) -> str:
        body = {"queue": queue, "group": group, "delivery_id": delivery_id}
        if requeue:
            body["requeue"] = ""
        resp = await self._request(Q_ACK, body)
        self._check_error(resp)
        return resp.body.get("result", "acked")

    async def cancel_task(self, task_id: str, queue: str = "task.dispatch") -> None:
        """R-05：发 control{signal=cancel}。server 识别后记 tombstone，
        同时消息正常入队（执行方看到后可协作取消 running 任务）。"""
        payload = (f"<control><signal>cancel</signal>"
                   f"<task_id>{task_id}</task_id></control>")
        await self.publish(queue, f"cancel-{task_id}", payload)

    def on_deliver(self, handler):
        self._deliver_handlers.append(handler)

    async def card(self, agent_id: str) -> dict:
        resp = await self._request(CARD, {"agent_id": agent_id})
        self._check_error(resp)
        return resp.body

    # ---- §11 任务层 API

    async def task_create(self, task_id: str = "", payload: str = "",
                          deps: list[str] | None = None, idem_key: str = "",
                          max_attempts: int | None = None) -> dict:
        """创建一个任务。返回任务视图（含 created 标志）。"""
        body = {"task_id": task_id, "deps": ",".join(deps or []),
                "idem_key": idem_key}
        if max_attempts is not None:
            body["max_attempts"] = str(max_attempts)
        resp = self._check_error(await self._request_cdata(
            T_CREATE, body, {"payload": payload}))
        return json.loads(resp.body.get("tasks") or "[]")[0]

    async def task_create_batch(self, specs: list[dict]) -> list[dict]:
        """原子批量创建（批内可互相依赖）。specs 字段同 task_create。"""
        resp = self._check_error(await self._request_cdata(
            T_CREATE, {}, {"batch": json.dumps(specs)}))
        return json.loads(resp.body.get("tasks") or "[]")

    async def task_get(self, task_id: str) -> dict:
        resp = self._check_error(await self._request(T_GET, {"task_id": task_id}))
        return json.loads(resp.body.get("task") or "{}")

    async def task_list(self, state: str = "") -> list[dict]:
        body = {"state": state} if state else {}
        resp = self._check_error(await self._request(T_LIST, body))
        return json.loads(resp.body.get("tasks") or "[]")

    async def task_claim(self, task_id: str = "", lease_s: float = 30.0,
                         workroot: str = "") -> dict | None:
        """原子认领。返回 {task_id, token, lease_expires_at, attempts,
        workdir, payload}；没有可认领任务时返回 None。"""
        body = {"lease_s": repr(float(lease_s))}
        if task_id:
            body["task_id"] = task_id
        if workroot:
            body["workroot"] = workroot
        resp = self._check_error(await self._request(T_CLAIM, body))
        b = resp.body
        if not b.get("task_id"):
            return None
        return {"task_id": b["task_id"], "token": int(b["token"]),
                "lease_expires_at": float(b["lease_expires_at"]),
                "attempts": int(b["attempts"]),
                "workdir": b.get("workdir", "") or "",
                "payload": b.get("payload", "") or ""}

    async def task_renew(self, task_id: str, token: int,
                         lease_s: float = 30.0) -> float:
        resp = self._check_error(await self._request(T_RENEW, {
            "task_id": task_id, "token": str(token),
            "lease_s": repr(float(lease_s))}))
        return float(resp.body["lease_expires_at"])

    async def task_complete(self, task_id: str, token: int,
                            result: str = "") -> list[str]:
        """返回本次完成新解锁的任务 id。"""
        resp = self._check_error(await self._request_cdata(T_COMPLETE, {
            "task_id": task_id, "token": str(token)}, {"result": result}))
        u = resp.body.get("unblocked", "") or ""
        return [x for x in u.split(",") if x]

    async def task_fail(self, task_id: str, token: int, error: str = "",
                        retry: bool = False) -> str:
        resp = self._check_error(await self._request(T_FAIL, {
            "task_id": task_id, "token": str(token), "error": error,
            "retry": "true" if retry else "false"}))
        return resp.body.get("state", "")

    async def task_cancel(self, task_id: str) -> str:
        resp = self._check_error(await self._request(T_CANCEL,
                                                     {"task_id": task_id}))
        return resp.body.get("state", "")
