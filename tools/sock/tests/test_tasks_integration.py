"""§11 任务层集成测试：真实 server 子进程 + 真实 Unix socket。"""
import asyncio
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from agent_sock.client import Client, ClientError
from agent_sock import worktree

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ServerProc:
    def __init__(self, tmp):
        self.tmp = tmp
        self.sock = os.path.join(tmp, "s.sock")
        self.data = os.path.join(tmp, "data")
        self.p = None

    def start(self):
        if os.path.exists(self.sock):
            os.unlink(self.sock)
        env = dict(os.environ, PYTHONPATH=HERE, PYTHONDONTWRITEBYTECODE="1")
        self.p = subprocess.Popen(
            [sys.executable, "-m", "agent_sock.server", "--sock", self.sock,
             "--data-dir", self.data], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while not os.path.exists(self.sock):
            if self.p.poll() is not None:
                raise RuntimeError(self.p.stderr.read().decode())
            if time.time() > deadline:
                raise RuntimeError("server did not start")
            time.sleep(0.05)

    def kill9(self):
        if self.p and self.p.poll() is None:
            self.p.send_signal(signal.SIGKILL)
            self.p.wait()


def write(p, text):
    with open(p, "w") as f:
        f.write(text)


def read(p):
    with open(p) as f:
        return f.read()


class TaskIntegration(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.mkdtemp(prefix="lucky-sock-it-")
        self.srv = ServerProc(self.tmp)
        self.srv.start()
        self.clients = []

    async def asyncTearDown(self):
        for c in self.clients:
            c._closed = True
            for t in (c._reader_task, c._heartbeat_task):
                if t:
                    t.cancel()
            if c.writer:
                c.writer.close()
        self.srv.kill9()
        if self.srv.p and self.srv.p.stderr:
            self.srv.p.stderr.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    async def client(self, aid):
        c = Client(agent_id=aid, sock_path=self.srv.sock)
        await c.connect()
        self.clients.append(c)
        return c

    async def test_deps_unblock_event(self):
        c = await self.client("orch")
        events = []

        async def on_d(m):
            if m.body.get("queue") == "events":
                events.append(json.loads(m.body.get("payload") or "{}"))
        c.on_deliver(on_d)
        r = await c._request("queue.consume", {"queue": "events"})
        self.assertEqual(r.type, "queue.consume")
        await c.task_create_batch([{"task_id": "a", "payload": "<x/>"},
                                   {"task_id": "b", "deps": ["a"]}])
        with self.assertRaises(ClientError) as ctx:
            await c.task_claim("b")
        self.assertEqual(ctx.exception.code, "AEVT-4104")
        cl = await c.task_claim()
        self.assertEqual((cl["task_id"], cl["payload"]), ("a", "<x/>"))
        unb = await c.task_complete("a", cl["token"], "ok ]]> done")
        self.assertEqual(unb, ["b"])
        self.assertEqual((await c.task_get("a"))["result"], "ok ]]> done")
        await asyncio.sleep(0.3)
        subjects = [e["subject"] for e in events]
        self.assertIn("task.unblocked", subjects)
        ev = next(e for e in events if e["subject"] == "task.unblocked")
        self.assertEqual(ev["data"], {"task_id": "b", "by": "a"})

    async def test_cycle_rejected(self):
        c = await self.client("orch")
        with self.assertRaises(ClientError) as ctx:
            await c.task_create_batch([{"task_id": "a", "deps": ["b"]},
                                       {"task_id": "b", "deps": ["a"]}])
        self.assertEqual(ctx.exception.code, "AEVT-4103")
        self.assertEqual(await c.task_list(), [])

    async def test_concurrent_claim_exactly_one(self):
        orch = await self.client("orch")
        await orch.task_create_batch([{"task_id": f"t{i}"} for i in range(5)])
        workers = [await self.client(f"w{i}") for i in range(10)]
        # 10 个 worker 同时抢同一个任务：恰好一个赢
        res = await asyncio.gather(*[w.task_claim("t0") for w in workers],
                                   return_exceptions=True)
        wins = [r for r in res if isinstance(r, dict)]
        self.assertEqual(len(wins), 1)
        self.assertTrue(all(isinstance(r, ClientError) and
                            r.code == "AEVT-4104" for r in res
                            if not isinstance(r, dict)))
        # 10 个 worker 抢剩下 4 个任务：每个任务恰好一个赢家
        res = await asyncio.gather(*[w.task_claim() for w in workers])
        got = [r["task_id"] for r in res if r]
        self.assertEqual(sorted(got), ["t1", "t2", "t3", "t4"])
        self.assertEqual(sum(1 for r in res if r is None), 6)

    async def test_fencing_stale_worker(self):
        """A 认领后卡住超过租约；B 认领（token+1）；A 提交被拒；B 提交成功。"""
        orch = await self.client("orch")
        a = await self.client("A")
        b = await self.client("B")
        await orch.task_create("t", payload="job")
        ca = await a.task_claim("t", lease_s=0.3)
        await asyncio.sleep(0.5)
        cb = await b.task_claim("t", lease_s=5)
        self.assertEqual(cb["token"], ca["token"] + 1)
        self.assertEqual(cb["attempts"], 2)
        for op in (a.task_complete("t", ca["token"], "A result"),
                   a.task_renew("t", ca["token"]),
                   a.task_fail("t", ca["token"], "x")):
            with self.assertRaises(ClientError) as ctx:
                await op
            self.assertEqual(ctx.exception.code, "AEVT-4101")
        await b.task_complete("t", cb["token"], "B result")
        t = await orch.task_get("t")
        self.assertEqual((t["state"], t["result"], t["completed_token"]),
                         ("completed", "B result", cb["token"]))

    async def test_renew_and_expiry_by_tick(self):
        orch = await self.client("orch")
        w = await self.client("w")
        await orch.task_create("t", max_attempts=1)
        cl = await w.task_claim("t", lease_s=1.0)
        for _ in range(3):
            await asyncio.sleep(0.6)
            await w.task_renew("t", cl["token"], lease_s=1.0)
        self.assertEqual((await orch.task_get("t"))["state"], "claimed")
        # 停止续租：server 的 1s tick 把它过期；max_attempts=1 -> failed
        await asyncio.sleep(2.5)
        t = await orch.task_get("t")
        self.assertEqual(t["state"], "failed")
        self.assertIn("max attempts", t["error"])

    async def test_restart_recovery_token_monotonic(self):
        orch = await self.client("orch")
        await orch.task_create_batch([{"task_id": "a", "max_attempts": 10},
                                      {"task_id": "b", "deps": ["a"]}])
        tokens = []
        for _ in range(3):
            w = await self.client("w")
            tokens.append((await w.task_claim("a", lease_s=0.2))["token"])
            await asyncio.sleep(0.3)
        live = await (await self.client("w2")).task_claim("a", lease_s=60)
        self.assertEqual(tokens + [live["token"]], [1, 2, 3, 4])
        # kill -9，重启
        for c in self.clients:
            c._closed = True
        self.srv.kill9()
        self.srv.p.stderr.close()
        self.srv.start()
        c = await self.client("after")
        t = await c.task_get("a")
        self.assertEqual((t["state"], t["token"], t["holder"]),
                         ("claimed", 4, "w2"))
        self.assertEqual((await c.task_get("b"))["deps"], ["a"])
        with self.assertRaises(ClientError) as ctx:
            await c.task_complete("a", 3)
        self.assertEqual(ctx.exception.code, "AEVT-4101")
        self.assertEqual(await c.task_complete("a", 4), ["b"])
        cb = await c.task_claim("b")
        self.assertEqual(cb["token"], 1)

    async def test_worktree_merge_gate(self):
        repo = os.path.join(self.tmp, "repo")
        os.makedirs(repo)
        g = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True,
                                      capture_output=True)
        g("init", "-q", "-b", "main")
        g("config", "user.email", "t@t")
        g("config", "user.name", "t")
        write(os.path.join(repo, "f.txt"), "base\n")
        g("add", ".")
        g("commit", "-qm", "base")
        wroot = os.path.join(self.tmp, "wt")
        orch = await self.client("orch")
        a = await self.client("A")
        b = await self.client("B")
        await orch.task_create("t")
        ca = await a.task_claim("t", lease_s=0.3, workroot=wroot)
        wa = worktree.prepare(repo, ca)
        write(os.path.join(wa, "f.txt"), "from A\n")
        subprocess.run(["git", "-C", wa, "commit", "-qam", "A"], check=True)
        await asyncio.sleep(0.5)
        cb = await b.task_claim("t", lease_s=5, workroot=wroot)
        self.assertNotEqual(ca["workdir"], cb["workdir"])
        wb = worktree.prepare(repo, cb)
        write(os.path.join(wb, "f.txt"), "from B\n")
        subprocess.run(["git", "-C", wb, "commit", "-qam", "B"], check=True)
        # 完成前：两个都拒
        with self.assertRaises(worktree.MergeRejected):
            await worktree.merge_gate(orch, repo, "t", cb["token"])
        await b.task_complete("t", cb["token"])
        # A 的结果：token 过期，拒绝合并
        with self.assertRaises(worktree.MergeRejected):
            await worktree.merge_gate(orch, repo, "t", ca["token"])
        await worktree.merge_gate(orch, repo, "t", cb["token"])
        self.assertEqual(read(os.path.join(repo, "f.txt")), "from B\n")
        self.assertFalse(os.path.isdir(wb))
        worktree.cleanup(repo, wa)

    async def test_task_methods_need_registration_and_ids(self):
        c = await self.client("x")
        with self.assertRaises(ClientError) as ctx:
            await c.task_get("nope")
        self.assertEqual(ctx.exception.code, "AEVT-4102")
        with self.assertRaises(ClientError) as ctx:
            await c.task_renew("nope", 1)
        self.assertEqual(ctx.exception.code, "AEVT-4102")


if __name__ == "__main__":
    unittest.main()
