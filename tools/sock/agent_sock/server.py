"""Sock server：单线程 asyncio + Unix socket + 11 原语处理。

DESIGN.md §2/§3。R-06/R-14：dispatcher 即事件循环，无跨线程写。
"""
from __future__ import annotations

import asyncio
import json
import os
import stat
import time

from . import errors, proto
from .proto import (
    Message, FrameReader, ProtoError,
    REGISTER, HEARTBEAT, DEREGISTER, CARD,
    Q_DECLARE, Q_PUBLISH, Q_CONSUME, Q_UNCONSUME,
    Q_DELIVER, Q_ACK, ERROR,
    T_CREATE, T_GET, T_LIST, T_CLAIM, T_RENEW, T_COMPLETE, T_FAIL, T_CANCEL,
)
from .queue import Queue, QueueDeclare, DEFAULT_ACK_WAIT_S, DEFAULT_MAX_DELIVER
from .tasks import TaskList, DEFAULT_LEASE_S

DEFAULT_SOCK = os.path.expanduser("~/.agent-sock/agent.sock")
HEARTBEAT_LEASE_S = 15
SUSPECT_S = 15
LOST_S = 60
WAL_FLUSH_MS = 10
WAL_FLUSH_N = 100


class Session:
    """agent 会话。"""

    def __init__(self, agent_id: str, writer: asyncio.StreamWriter):
        self.agent_id = agent_id
        self.writer = writer
        self.seq_out = 0
        self.seq_in = 0
        self.last_heartbeat = time.time()
        self.status = "active"  # active | suspect | lost
        self.caps: list[str] = []
        self.subscriptions: dict[str, str] = {}  # queue -> group


class Server:
    def __init__(self, sock_path: str = DEFAULT_SOCK,
                 data_dir: str | None = None):
        self.sock_path = sock_path
        self.data_dir = data_dir or os.path.expanduser("~/.agent-sock")
        self.queues: dict[str, Queue] = {}
        self.sessions: dict[str, Session] = {}       # agent_id -> Session
        self.conns: dict[asyncio.StreamWriter, Session | None] = {}
        self._wal_pending = 0
        self._wal_timer: asyncio.TimerHandle | None = None
        self._running = False
        os.makedirs(os.path.join(self.data_dir, "queues"), exist_ok=True)
        self._predeclare()
        # §11 共享任务列表。启动时重放 tasks/log.jsonl。
        self.tasks = TaskList(os.path.join(self.data_dir, "tasks"))
        self.tasks.on_exhausted = self._on_task_exhausted
        self.tasks.on_dep_failed = self._on_task_dep_failed
        self._pending_task_events: list[tuple[str, dict]] = []

    # ---- 启动

    def _predeclare(self):
        """§2.4 约定队列预声明。"""
        for name, semantics, overflow in [
            ("task.dispatch", "workqueue", "block"),
            ("approval.requests", "workqueue", "block"),
            ("events", "topic", "drop_oldest"),
        ]:
            self._get_or_create_queue(name, semantics, overflow=overflow)

    def _get_or_create_queue(self, name: str, semantics: str,
                             max_depth: int = 10000,
                             overflow: str = "block") -> Queue:
        q = self.queues.get(name)
        if q is None:
            q = Queue(QueueDeclare(name=name, semantics=semantics,
                                   max_depth=max_depth, overflow=overflow),
                      os.path.join(self.data_dir, "queues", name))
            self.queues[name] = q
        return q

    def _inbox_name(self, agent_id: str) -> str:
        return f"agent.{agent_id}.inbox"

    async def serve(self):
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)
        os.makedirs(os.path.dirname(self.sock_path), exist_ok=True)
        server = await asyncio.start_unix_server(self._on_conn, self.sock_path)
        os.chmod(self.sock_path, 0o600)
        self._running = True
        asyncio.get_running_loop().call_later(1.0, self._tick)
        async with server:
            await server.serve_forever()

    # ---- 连接处理

    async def _on_conn(self, reader: asyncio.StreamReader,
                       writer: asyncio.StreamWriter):
        # SO_PEERCRED：仅本机 uid（§2.1）
        try:
            cred = writer.get_extra_info("peercred")
            if cred is not None and cred["uid"] != os.getuid():
                writer.close()
                return
        except Exception:
            pass
        self.conns[writer] = None
        fr = FrameReader()
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                try:
                    msgs = fr.feed(data)
                except ProtoError as e:
                    # R-04：超限断开
                    await self._send_error(writer, None, e.code, e.message)
                    break
                for msg in msgs:
                    await self._dispatch(writer, msg)
        finally:
            await self._on_disconnect(writer)

    async def _on_disconnect(self, writer: asyncio.StreamWriter):
        sess = self.conns.pop(writer, None)
        if sess is not None:
            # 非优雅断开：in-flight 按 Leave 回收（TLA+ Leave）
            for qname, gname in sess.subscriptions.items():
                q = self.queues.get(qname)
                if q:
                    q.unconsume(sess.agent_id, gname)
        try:
            writer.close()
        except Exception:
            pass

    # ---- 分发

    async def _dispatch(self, writer: asyncio.StreamWriter, msg: Message):
        sess = self.conns.get(writer)
        # ack 捎带：更新已收对方最大 seq
        if sess is not None:
            sess.seq_in = max(sess.seq_in, msg.seq)
        handler = {
            REGISTER: self._h_register,
            HEARTBEAT: self._h_heartbeat,
            DEREGISTER: self._h_deregister,
            CARD: self._h_card,
            Q_DECLARE: self._h_declare,
            Q_PUBLISH: self._h_publish,
            Q_CONSUME: self._h_consume,
            Q_UNCONSUME: self._h_unconsume,
            Q_ACK: self._h_ack,
            T_CREATE: self._h_task_create,
            T_GET: self._h_task_get,
            T_LIST: self._h_task_list,
            T_CLAIM: self._h_task_claim,
            T_RENEW: self._h_task_renew,
            T_COMPLETE: self._h_task_complete,
            T_FAIL: self._h_task_fail,
            T_CANCEL: self._h_task_cancel,
        }.get(msg.type)
        if handler is None:
            await self._send_error(writer, msg, "ASOCK-2002",
                                   f"no handler for {msg.type}")
            return
        try:
            await handler(writer, msg)
        except ProtoError as e:
            await self._send_error(writer, msg, e.code, e.message)
        except errors.ErrorPacket as e:
            await self._send_error(writer, msg, e.code, e.message)
        except Exception as e:  # 防御：单连接异常不杀 server
            await self._send_error(writer, msg, "ASOCK-2006", repr(e))

    def _next_seq(self, sess: Session | None) -> int:
        if sess is None:
            return 1
        sess.seq_out += 1
        return sess.seq_out

    async def _send(self, writer: asyncio.StreamWriter, msg: Message,
                    cdata: dict | None = None):
        data = proto.encode_with_cdata(msg, cdata or {})
        writer.write(data)
        await writer.drain()

    async def _send_error(self, writer: asyncio.StreamWriter,
                          req: Message | None, code: str, message: str):
        sess = self.conns.get(writer)
        err = Message(type=ERROR, seq=self._next_seq(sess),
                      ack=req.seq if req else 0, from_="server",
                      in_reply_to=req.seq if req else None,
                      body={"code": code, "message": message})
        try:
            await self._send(writer, err)
        except Exception:
            pass
        if code == "ASOCK-2004":  # R-04：超限断开
            writer.close()

    # ---- 原语处理

    async def _h_register(self, writer, msg: Message):
        agent_id = msg.from_
        resume = msg.body.get("resume") == "true"
        sess = self.sessions.get(agent_id)
        if sess is not None and sess.status == "lost" and resume:
            await self._send_error(writer, msg, "AEVT-4008",
                                   "session lost, rebuild state")
            return
        sess = Session(agent_id, writer)
        caps = msg.body.get("caps", {})
        if isinstance(caps, dict):
            sess.caps = [v for k, v in caps.items() if k == "cap"]
        elif isinstance(caps, str):
            sess.caps = [caps]
        self.sessions[agent_id] = sess
        self.conns[writer] = sess
        # 预声明收件箱
        self._get_or_create_queue(self._inbox_name(agent_id), "workqueue")
        await self._send(writer, Message(
            type=REGISTER, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq,
            body={"lease_s": str(HEARTBEAT_LEASE_S)}))
        await self._emit_event("agent.started", {"agent_id": agent_id})

    async def _h_heartbeat(self, writer, msg: Message):
        sess = self.conns.get(writer)
        if sess is None:
            await self._send_error(writer, msg, "ASOCK-2001", "not registered")
            return
        sess.last_heartbeat = time.time()
        sess.status = "active"

    async def _h_deregister(self, writer, msg: Message):
        sess = self.conns.pop(writer, None)
        if sess is not None:
            # TLA+ Leave：原子回收 in-flight
            for qname, gname in sess.subscriptions.items():
                q = self.queues.get(qname)
                if q:
                    q.unconsume(sess.agent_id, gname)
            self.sessions.pop(sess.agent_id, None)
            await self._emit_event("agent.stopped",
                                   {"agent_id": sess.agent_id,
                                    "reason": msg.body.get("reason", "")})
        writer.close()

    async def _h_card(self, writer, msg: Message):
        sess = self.conns.get(writer)
        target = msg.body.get("agent_id", "")
        tsess = self.sessions.get(target)
        skills = tsess.caps if tsess else []
        await self._send(writer, Message(
            type=CARD, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq,
            body={"agent_id": target,
                  "skills": {"skill": skills}}))

    async def _h_declare(self, writer, msg: Message):
        sess = self.conns.get(writer)
        name = msg.body.get("queue", "")
        semantics = msg.body.get("semantics", "")
        if not name or semantics not in ("workqueue", "topic"):
            await self._send_error(writer, msg, "AEVT-4007",
                                   "queue.declare requires queue+semantics")
            return
        try:
            max_depth = int(msg.body.get("max_depth", "10000"))
        except ValueError:
            await self._send_error(writer, msg, "AEVT-4007", "bad max_depth")
            return
        overflow = msg.body.get("overflow", "")
        if overflow not in ("block", "drop_oldest"):
            await self._send_error(writer, msg, "AEVT-4007",
                                   "overflow must be block|drop_oldest")
            return
        q = self.queues.get(name)
        if q is not None:
            d = q.decl
            if d.semantics != semantics or d.max_depth != max_depth \
                    or d.overflow != overflow:
                await self._send_error(writer, msg, "AEVT-4007",
                                       "declare conflict with existing queue")
                return
        else:
            self._get_or_create_queue(name, semantics, max_depth, overflow)
        await self._send(writer, Message(
            type=Q_DECLARE, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq,
            body={"queue": name, "ok": "true"}))

    async def _h_publish(self, writer, msg: Message):
        sess = self.conns.get(writer)
        name = msg.body.get("queue", "")
        message_id = msg.body.get("message_id", "")
        q = self.queues.get(name)
        if q is None:
            await self._send_error(writer, msg, "AEVT-4006",
                                   f"queue not declared: {name}")
            return
        if not message_id:
            await self._send_error(writer, msg, "AEVT-4007",
                                   "queue.publish requires message_id")
            return
        # 载荷：优先 CDATA 原文
        payload_text = self._extract_payload(msg)
        try:
            proto.check_payload_size(payload_text.encode("utf-8"))
        except ProtoError as e:
            await self._send_error(writer, msg, e.code, e.message)
            return
        try:
            mid, alert = q.publish(message_id, payload_text.encode("utf-8"))
        except errors.ErrorPacket as e:
            # AEVT-4001 背压：带 retry_after_s
            await self._send(writer, Message(
                type=ERROR, seq=self._next_seq(sess), ack=msg.seq,
                from_="server", in_reply_to=msg.seq,
                body={"code": e.code, "message": e.message,
                      "retry_after_s": "1", "retryable": "true"}))
            return
        self._wal_bump()
        # R-05：control{signal=cancel} 记 tombstone（投递前过滤）
        if "<signal>cancel</signal>" in payload_text:
            tid = self._extract_tag(payload_text, "task_id")
            if tid:
                self.cancel_task(tid)
                await self._emit_event("task.cancelled", {"task_id": tid})
        if alert == "AEVT-4005":
            await self._emit_event("queue.empty_group",
                                   {"queue": name, "code": "AEVT-4005"})
        elif alert == "queue.dropped":
            await self._emit_event("queue.dropped",
                                   {"queue": name, "count": "1",
                                    "reason": "drop_oldest"})
        # task 载荷：发 task.queued 事件
        if "<task>" in payload_text or "<task " in payload_text:
            await self._emit_event("task.queued",
                                   {"task_id": message_id, "queue": name})
        await self._send(writer, Message(
            type=Q_PUBLISH, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq,
            body={"queue": name, "mid": str(mid)}))
        # 主动投递
        await self._pump(name)

    def _extract_payload(self, msg: Message) -> str:
        # CDATA 原文在 raw_xml 里；简单起见取 <payload> 元素文本
        p = msg.body.get("payload", "")
        return p if isinstance(p, str) else ""

    @staticmethod
    def _extract_tag(xml_text: str, tag: str) -> str:
        import re
        m = re.search(rf"<{tag}>(.*?)</{tag}>", xml_text, re.S)
        return m.group(1).strip() if m else ""

    async def _h_consume(self, writer, msg: Message):
        sess = self.conns.get(writer)
        if sess is None:
            await self._send_error(writer, msg, "ASOCK-2001", "not registered")
            return
        name = msg.body.get("queue", "")
        group = msg.body.get("group") or None
        q = self.queues.get(name)
        if q is None:
            await self._send_error(writer, msg, "AEVT-4006",
                                   f"queue not declared: {name}")
            return
        # R-11：topic 下 ack 参数必须缺省
        if q.decl.semantics == "topic" and (
                "ack_wait_s" in msg.body or "max_deliver" in msg.body):
            await self._send_error(writer, msg, "AEVT-4007",
                                   "topic forbids ack_wait_s/max_deliver")
            return
        try:
            ack_wait_s = int(msg.body.get("ack_wait_s", str(DEFAULT_ACK_WAIT_S)))
            max_deliver = int(msg.body.get("max_deliver",
                                           str(DEFAULT_MAX_DELIVER)))
        except ValueError:
            await self._send_error(writer, msg, "AEVT-4007", "bad ack params")
            return
        try:
            g = q.consume(sess.agent_id, group, ack_wait_s, max_deliver)
        except errors.ErrorPacket as e:
            await self._send_error(writer, msg, e.code, e.message)
            return
        sess.subscriptions[name] = g.name
        await self._send(writer, Message(
            type=Q_CONSUME, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq,
            body={"queue": name, "group": g.name, "ok": "true"}))
        # catch-up：since 是 server seq（R-24）
        await self._pump(name)

    async def _h_unconsume(self, writer, msg: Message):
        sess = self.conns.get(writer)
        if sess is None:
            return
        name = msg.body.get("queue", "")
        group = msg.body.get("group") or None
        q = self.queues.get(name)
        if q is not None:
            q.unconsume(sess.agent_id, group)
        sess.subscriptions.pop(name, None)
        await self._send(writer, Message(
            type=Q_UNCONSUME, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq, body={"ok": "true"}))

    async def _h_ack(self, writer, msg: Message):
        sess = self.conns.get(writer)
        if sess is None:
            return
        name = msg.body.get("queue", "")
        group = msg.body.get("group", "")
        q = self.queues.get(name)
        if q is None:
            await self._send_error(writer, msg, "AEVT-4006",
                                   f"queue not declared: {name}")
            return
        try:
            mid = int(msg.body.get("delivery_id", "0"))
        except ValueError:
            await self._send_error(writer, msg, "AEVT-4007", "bad delivery_id")
            return
        requeue = "requeue" in msg.body  # ack+<requeue/>（S3）
        try:
            result = q.ack(group, mid, sess.agent_id, requeue=requeue)
        except errors.ErrorPacket as e:
            await self._send_error(writer, msg, e.code, e.message)
            return
        self._wal_bump()
        if result == "dead":
            m = q.messages.get(mid)
            await self._emit_event("queue.dead",
                                   {"queue": name,
                                    "message_id": m.message_id if m else ""})
        await self._send(writer, Message(
            type=Q_ACK, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq,
            body={"ok": "true", "result": result}))
        await self._pump(name)

    # ---- 投递泵

    async def _pump(self, qname: str):
        """尝试向各组投递。tombstone 过滤在 queue.deliver 内。"""
        q = self.queues.get(qname)
        if q is None:
            return
        for gname, g in q.groups.items():
            if not g.members:
                continue
            # 背压：组 pending 超限暂停投递
            if len(g.pending) >= q.decl.max_depth:
                continue
            while True:
                m = q.deliver(gname)
                if m is None:
                    break
                self._wal_bump()
                await self._deliver_to(q, gname, m)

    async def _deliver_to(self, q: Queue, gname: str, m):
        consumer = m.pend_consumer
        sess = self.sessions.get(consumer)
        if sess is None:
            return
        cdata = {"payload": m.payload.decode("utf-8", "replace")}
        await self._send(sess.writer, Message(
            type=Q_DELIVER, seq=self._next_seq(sess), from_="server",
            body={"queue": q.decl.name, "group": gname,
                  "delivery_id": str(m.mid),
                  "redelivered": "true" if m.pend_count > 1 else "false",
                  "message_id": m.message_id,
                  "payload": ""}), cdata=cdata)

    # ---- 事件

    async def _emit_event(self, subject: str, data: dict):
        q = self.queues.get("events")
        if q is None:
            return
        payload = json.dumps({"subject": subject, "data": data,
                              "ts": time.time()})
        try:
            q.publish(f"evt-{time.time_ns()}", payload.encode())
        except errors.ErrorPacket:
            pass  # events 用 drop_oldest，不应 block
        self._wal_bump()
        await self._pump("events")

    # ---- WAL 批量刷盘（R-07）

    def _wal_bump(self):
        self._wal_pending += 1
        if self._wal_pending >= WAL_FLUSH_N:
            self._wal_flush()
        elif self._wal_timer is None:
            loop = asyncio.get_running_loop()
            self._wal_timer = loop.call_later(WAL_FLUSH_MS / 1000.0,
                                              self._wal_flush)

    def _wal_flush(self):
        self._wal_timer = None
        if self._wal_pending:
            for q in self.queues.values():
                q.snapshot()
            self._wal_pending = 0
        self.tasks.flush()

    # ---- 定时：心跳租约 + ack 超时扫描

    def _tick(self):
        if not self._running:
            return
        now = time.time()
        for agent_id, sess in list(self.sessions.items()):
            idle = now - sess.last_heartbeat
            if idle > LOST_S:
                sess.status = "lost"
                for qname, gname in sess.subscriptions.items():
                    q = self.queues.get(qname)
                    if q:
                        q.unconsume(agent_id, gname)
            elif idle > SUSPECT_S:
                sess.status = "suspect"
        # §11 任务租约过期扫描
        for t in self.tasks.sweep(now):
            self._queue_task_event("task.expired",
                                   {"task_id": t.task_id, "state": t.state,
                                    "token": str(t.token),
                                    "attempts": str(t.attempts)})
        self._drain_task_events()
        for qname, q in self.queues.items():
            for mid, result in q.sweep_timeouts(now):
                if result == "dead":
                    m = q.messages.get(mid)
                    # 死信事件（fire-and-forget，经事件循环发）
                    asyncio.get_running_loop().call_soon(
                        lambda qn=qname, mm=m: asyncio.ensure_future(
                            self._emit_event("queue.dead", {
                                "queue": qn,
                                "message_id": mm.message_id if mm else ""})))
            # 主动投递（超时回池后）
            asyncio.get_running_loop().call_soon(
                lambda qn=qname: asyncio.ensure_future(self._pump(qn)))
        self._wal_flush()
        asyncio.get_running_loop().call_later(1.0, self._tick)

    # ---- §11 任务层

    def _queue_task_event(self, subject: str, data: dict):
        self._pending_task_events.append((subject, data))

    def _drain_task_events(self):
        """同步路径（sweep/钩子）里产生的事件，经事件循环发出。"""
        evs, self._pending_task_events = self._pending_task_events, []
        for subject, data in evs:
            asyncio.ensure_future(self._emit_event(subject, data))

    def _on_task_exhausted(self, t):
        """死信钩子：attempts 用尽。现在只发 task.exhausted 事件。
        fix 的死信路径在这里接入（例如把任务写入死信队列）。"""
        self._queue_task_event("task.exhausted",
                               {"task_id": t.task_id,
                                "attempts": str(t.attempts),
                                "error": t.error})

    def _on_task_dep_failed(self, t, dep: str):
        self._queue_task_event("task.failed",
                               {"task_id": t.task_id, "state": t.state,
                                "error": t.error, "reason": "dep_failed",
                                "dep": dep})

    async def _task_reply(self, writer, msg: Message, body: dict,
                          cdata: dict | None = None):
        sess = self.conns.get(writer)
        self._wal_bump()
        await self._send(writer, Message(
            type=msg.type, seq=self._next_seq(sess), ack=msg.seq,
            from_="server", in_reply_to=msg.seq, body=body), cdata=cdata)
        self._drain_task_events()

    def _require_session(self, writer):
        sess = self.conns.get(writer)
        if sess is None:
            raise errors.make("ASOCK-2001", "not registered")
        return sess

    @staticmethod
    def _int_field(msg: Message, name: str) -> int:
        try:
            return int(msg.body.get(name, ""))
        except ValueError:
            raise errors.make("AEVT-4007", f"bad or missing {name}")

    async def _h_task_create(self, writer, msg: Message):
        batch = msg.body.get("batch", "")
        if batch:
            try:
                specs = json.loads(batch)
                assert isinstance(specs, list)
            except Exception:
                raise errors.make("AEVT-4007", "batch must be a JSON list")
        else:
            deps = msg.body.get("deps", "") or ""
            specs = [{"task_id": msg.body.get("task_id", ""),
                      "payload": self._extract_payload(msg),
                      "deps": [d.strip() for d in deps.split(",") if d.strip()],
                      "idem_key": msg.body.get("idem_key", ""),
                      "max_attempts": msg.body.get("max_attempts", "")}]
        res = self.tasks.create(specs)
        views = []
        for t, created in res:
            v = self.tasks.view(t)
            v["created"] = created
            views.append(v)
            if created:
                await self._emit_event("task.created",
                                       {"task_id": t.task_id,
                                        "claimable": str(v["claimable"]).lower()})
        await self._task_reply(writer, msg, {
            "task_id": views[0]["task_id"] if len(views) == 1 else "",
            "created": str(views[0]["created"]).lower() if len(views) == 1 else "",
            "tasks": ""}, cdata={"tasks": json.dumps(views)})

    async def _h_task_get(self, writer, msg: Message):
        t = self.tasks.get(msg.body.get("task_id", ""))
        await self._task_reply(writer, msg, {"task": ""},
                               cdata={"task": json.dumps(self.tasks.view(t))})

    async def _h_task_list(self, writer, msg: Message):
        ts = self.tasks.list(msg.body.get("state", "") or "")
        await self._task_reply(writer, msg, {"tasks": ""}, cdata={
            "tasks": json.dumps([self.tasks.view(t) for t in ts])})

    async def _h_task_claim(self, writer, msg: Message):
        sess = self._require_session(writer)
        t = self.tasks.claim(sess.agent_id,
                             task_id=msg.body.get("task_id", "") or "",
                             lease_s=msg.body.get("lease_s", "") or DEFAULT_LEASE_S,
                             workroot=msg.body.get("workroot", "") or "")
        if t is None:
            await self._task_reply(writer, msg, {"task_id": ""})
            return
        await self._emit_event("task.claimed", {
            "task_id": t.task_id, "holder": t.holder, "token": str(t.token)})
        await self._task_reply(writer, msg, {
            "task_id": t.task_id, "token": str(t.token),
            "lease_expires_at": repr(t.lease_expires_at),
            "attempts": str(t.attempts), "workdir": t.workdir,
            "payload": ""}, cdata={"payload": t.payload})

    async def _h_task_renew(self, writer, msg: Message):
        self._require_session(writer)
        t = self.tasks.renew(msg.body.get("task_id", ""),
                             self._int_field(msg, "token"),
                             msg.body.get("lease_s", "") or DEFAULT_LEASE_S)
        await self._task_reply(writer, msg, {
            "task_id": t.task_id, "token": str(t.token),
            "lease_expires_at": repr(t.lease_expires_at)})

    async def _h_task_complete(self, writer, msg: Message):
        self._require_session(writer)
        result = msg.body.get("result", "")
        t, unblocked = self.tasks.complete(
            msg.body.get("task_id", ""), self._int_field(msg, "token"),
            result if isinstance(result, str) else "")
        await self._emit_event("task.completed", {
            "task_id": t.task_id, "token": str(t.token)})
        for u in unblocked:
            await self._emit_event("task.unblocked", {"task_id": u.task_id,
                                                      "by": t.task_id})
        await self._task_reply(writer, msg, {
            "task_id": t.task_id, "state": t.state,
            "unblocked": ",".join(u.task_id for u in unblocked)})

    async def _h_task_fail(self, writer, msg: Message):
        self._require_session(writer)
        t = self.tasks.fail(msg.body.get("task_id", ""),
                            self._int_field(msg, "token"),
                            error=msg.body.get("error", "") or "",
                            retry=msg.body.get("retry", "") == "true")
        await self._emit_event("task.failed", {
            "task_id": t.task_id, "state": t.state, "error": t.error})
        await self._task_reply(writer, msg, {"task_id": t.task_id,
                                             "state": t.state})

    async def _h_task_cancel(self, writer, msg: Message):
        self._require_session(writer)
        t = self.tasks.cancel(msg.body.get("task_id", ""))
        await self._emit_event("task.cancelled", {"task_id": t.task_id,
                                                  "source": "tasklist"})
        await self._task_reply(writer, msg, {"task_id": t.task_id,
                                             "state": t.state})

    # ---- 运维 API（CLI 用）

    def queue_depth(self, name: str) -> int:
        q = self.queues.get(name)
        return q.depth() if q else 0

    def dead_letters(self, name: str) -> list[dict]:
        q = self.queues.get(name)
        if not q:
            return []
        return [{"mid": m.mid, "message_id": m.message_id,
                 "pend_count": m.pend_count}
                for m in q.messages.values() if m.state == "dead"]

    def replay_dlq(self, name: str) -> int:
        """死信重放：死信消息重置为 queued。返回重放数。"""
        q = self.queues.get(name)
        if not q:
            return 0
        n = 0
        for m in q.messages.values():
            if m.state == "dead":
                m.state = "queued"
                m.pend_count = 0
                m.pend_consumer = ""
                n += 1
        return n

    def cancel_task(self, task_id: str) -> bool:
        """R-05：记 tombstone。"""
        ok = False
        for q in self.queues.values():
            if q.cancel(task_id):
                ok = True
        return ok


def main():
    import argparse
    ap = argparse.ArgumentParser(prog="asock serve")
    ap.add_argument("--sock", default=DEFAULT_SOCK)
    ap.add_argument("--data-dir", default=None)
    args = ap.parse_args()
    srv = Server(sock_path=args.sock, data_dir=args.data_dir)
    asyncio.run(srv.serve())


if __name__ == "__main__":
    main()
