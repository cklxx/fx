"""持久化、死信、重投退避测试。

单元：AppendLog 撕裂尾部、组提交、日志重放、reject 进死信、退避公式。
集成：真实 server 子进程。写入并收到应答后 kill -9，重启，消息还在；
已 ack 的消息不重投。
"""
import asyncio
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from agent_sock import durable
from agent_sock.durable import AppendLog, GroupCommit
from agent_sock.queue import Queue, QueueDeclare, DEAD_REJECTED, \
    DEAD_EXHAUSTED

PKG_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class TmpDir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


# ---------------------------------------------------------------- AppendLog

class TestAppendLog(TmpDir):
    def test_torn_tail_truncated(self):
        p = os.path.join(self.tmp, "log.jsonl")
        lg = AppendLog(p)
        lg.append({"a": 1})
        lg.append({"a": 2})
        lg.close()
        with open(p, "ab") as f:
            f.write(b'{"a": 3, "pay')  # crash 时写了一半
        lg2 = AppendLog(p)
        self.assertEqual([r["a"] for r in lg2.replay()], [1, 2])
        self.assertEqual(lg2.torn_bytes, len(b'{"a": 3, "pay'))
        lg2.append({"a": 4})  # 新记录不能接在撕裂的半行后面
        self.assertEqual([r["a"] for r in AppendLog(p).replay()], [1, 2, 4])

    def test_corrupt_middle_raises(self):
        p = os.path.join(self.tmp, "log.jsonl")
        with open(p, "w") as f:
            f.write('{"a": 1}\nGARBAGE\n{"a": 2}\n')
        with self.assertRaises(ValueError):
            list(AppendLog(p).replay())

    def test_read_only_does_not_truncate(self):
        p = os.path.join(self.tmp, "log.jsonl")
        with open(p, "w") as f:
            f.write('{"a": 1}\n{"a": 2')
        size = os.path.getsize(p)
        recs = list(AppendLog(p, read_only=True).replay())
        self.assertEqual(recs, [{"a": 1}])
        self.assertEqual(os.path.getsize(p), size)

    def test_rewrite_atomic(self):
        p = os.path.join(self.tmp, "log.jsonl")
        lg = AppendLog(p)
        for i in range(5):
            lg.append({"i": i})
        lg.rewrite([{"i": 9}])
        lg.append({"i": 10})
        self.assertEqual([r["i"] for r in AppendLog(p).replay()], [9, 10])
        self.assertFalse(os.path.exists(p + ".tmp"))

    def test_new_file_fsyncs_dir(self):
        calls = []
        orig = durable.fsync_dir
        durable.fsync_dir = lambda d: calls.append(d)
        try:
            AppendLog(os.path.join(self.tmp, "sub", "log.jsonl")).append({})
        finally:
            durable.fsync_dir = orig
        self.assertIn(self.tmp, calls)                      # 新目录 sub
        self.assertIn(os.path.join(self.tmp, "sub"), calls)  # 新文件


# -------------------------------------------------------------- GroupCommit

class TestGroupCommit(TmpDir):
    def test_one_fsync_per_batch(self):
        async def go():
            gc = GroupCommit()
            logs = [AppendLog(os.path.join(self.tmp, f"l{i}.jsonl"), group=gc)
                    for i in range(3)]
            for i in range(30):
                logs[i % 3].append({"i": i})
            await asyncio.gather(*(gc.commit() for _ in range(30)))
            return gc
        gc = asyncio.run(go())
        self.assertEqual(gc.batches, 1)
        self.assertEqual(gc.records, 30)
        self.assertEqual(gc.synced_gen, gc.write_gen)

    def test_commit_waits_for_fsync(self):
        """commit() 在 fsync 完成前不返回。"""
        gate = threading.Event()
        orig = durable._fsync_all

        def slow(fds):
            gate.wait(5)
            orig(fds)
        durable._fsync_all = slow
        try:
            async def go():
                gc = GroupCommit()
                lg = AppendLog(os.path.join(self.tmp, "l.jsonl"), group=gc)
                lg.append({"x": 1})
                t = asyncio.ensure_future(gc.commit())
                await asyncio.sleep(0.2)
                done_before = t.done()
                gate.set()
                await asyncio.wait_for(t, 5)
                return done_before
            self.assertFalse(asyncio.run(go()))
        finally:
            durable._fsync_all = orig

    def test_fsync_error_fail_stop(self):
        orig = durable._fsync_all

        def boom(fds):
            raise OSError(5, "EIO")
        durable._fsync_all = boom
        try:
            async def go():
                gc = GroupCommit()
                lg = AppendLog(os.path.join(self.tmp, "l.jsonl"), group=gc)
                lg.append({"x": 1})
                with self.assertRaises(OSError):
                    await gc.commit()
                durable._fsync_all = orig
                lg.append({"x": 2})
                with self.assertRaises(OSError):  # 不再确认任何写入
                    await gc.commit()
            asyncio.run(go())
        finally:
            durable._fsync_all = orig


# ---------------------------------------------------------- Queue 重放

class QBase(TmpDir):
    def mkq(self, **kw):
        return Queue(QueueDeclare(name="t", semantics="workqueue"),
                     self.tmp, **kw)


class TestQueueReplay(QBase):
    def test_ack_survives_restart(self):
        q = self.mkq()
        q.consume("c1", "g", backoff_base_s=0)
        for i in range(3):
            q.publish(f"m{i}", b"x")
        d0 = q.deliver("g")
        q.ack("g", d0.mid, "c1")
        d1 = q.deliver("g")       # in-flight 时 crash
        q.snapshot()
        q.log.close()
        q2 = self.mkq()
        self.assertEqual(q2.messages[d0.mid].state, "acked")
        self.assertEqual(q2.messages[d1.mid].state, "queued")  # 回池重投
        self.assertEqual(q2.messages[d1.mid].pend_count, 1)    # 计数保留
        self.assertEqual(q2.groups["g"].members, set())        # 成员清空
        q2.consume("c9", "g", backoff_base_s=0)
        got = [q2.deliver("g").message_id, q2.deliver("g").message_id]
        self.assertEqual(sorted(got), ["m1", "m2"])
        self.assertIsNone(q2.deliver("g"))

    def test_max_deliver_across_restart(self):
        q = self.mkq()
        q.consume("c1", "g", max_deliver=2, backoff_base_s=0)
        q.publish("m", b"x")
        q.deliver("g")
        q.log.close()
        q = self.mkq()
        q.consume("c1", "g", max_deliver=2, backoff_base_s=0)
        d = q.deliver("g")
        self.assertEqual(d.pend_count, 2)
        self.assertEqual(q.ack("g", d.mid, "c1", requeue=True), "dead")

    def test_cancel_and_drop_persist(self):
        q = Queue(QueueDeclare(name="t", semantics="workqueue", max_depth=2,
                               overflow="drop_oldest"), self.tmp)
        q.publish("a", b"1")
        q.publish("b", b"2")
        q.cancel("b")
        q.publish("c", b"3")  # 挤掉 a
        q.log.close()
        q2 = Queue(QueueDeclare(name="t", semantics="workqueue", max_depth=2,
                                overflow="drop_oldest"), self.tmp)
        self.assertEqual(sorted(m.message_id for m in q2.messages.values()),
                         ["b", "c"])
        self.assertIn("b", q2.cancelled)
        mid_c = q2.publish("d", b"4")[0]
        self.assertEqual(mid_c, 4)  # mid 不回退

    def test_compaction_rewrites_log(self):
        q = self.mkq()
        q.consume("c1", "g", backoff_base_s=0)
        for i in range(1100):
            q.publish(f"m{i}", b"x")
            d = q.deliver("g")
            q.ack("g", d.mid, "c1")
        before = os.path.getsize(q.log.path)
        n = q.compact()
        self.assertGreater(n, 0)
        self.assertLess(os.path.getsize(q.log.path), before)
        q.log.close()
        q2 = self.mkq()
        self.assertEqual(len(q2.messages), 1100 - n)
        self.assertEqual(q2.publish("new", b"x")[0], 1101)

    def test_old_format_log_loads(self):
        with open(os.path.join(self.tmp, "log.jsonl"), "w") as f:
            f.write(json.dumps({"mid": 1, "message_id": "old", "payload": "p",
                                "state": "queued", "pend_count": 0}) + "\n")
        with open(os.path.join(self.tmp, "cancelled.json"), "w") as f:
            json.dump(["x"], f)
        q = self.mkq()
        self.assertEqual(q.messages[1].message_id, "old")
        self.assertIn("x", q.cancelled)


# ------------------------------------------------------------------ 死信

class TestDeadLetter(QBase):
    def test_reject_goes_dead_without_redelivery(self):
        q = self.mkq()
        q.consume("c1", "g", max_deliver=5)
        q.publish("poison", b"x")
        d = q.deliver("g")
        self.assertEqual(q.ack("g", d.mid, "c1", reject=True), "dead")
        self.assertIsNone(q.deliver("g"))
        dl = q.dead_letters()
        self.assertEqual(len(dl), 1)
        self.assertEqual(dl[0]["message_id"], "poison")
        self.assertEqual(dl[0]["reason"], DEAD_REJECTED)
        self.assertEqual(dl[0]["pend_count"], 1)
        q.log.close()
        q2 = self.mkq()  # 死信跨重启
        self.assertEqual(q2.dead_letters()[0]["reason"], DEAD_REJECTED)

    def test_exhausted_reason(self):
        q = self.mkq()
        q.consume("c1", "g", max_deliver=2, backoff_base_s=0)
        q.publish("m", b"x")
        for _ in range(2):
            d = q.deliver("g")
            r = q.ack("g", d.mid, "c1", requeue=True)
        self.assertEqual(r, "dead")
        self.assertEqual(q.dead_letters()[0]["reason"], DEAD_EXHAUSTED)

    def test_replay_dead(self):
        q = self.mkq()
        q.consume("c1", "g")
        q.publish("m", b"x")
        d = q.deliver("g")
        q.ack("g", d.mid, "c1", reject=True)
        self.assertEqual(q.replay_dead(), 1)
        q.log.close()
        q2 = self.mkq()
        self.assertEqual(q2.dead_letters(), [])
        self.assertEqual(q2.messages[d.mid].state, "queued")
        self.assertEqual(q2.messages[d.mid].pend_count, 0)


# ------------------------------------------------------------------ 退避

class TestBackoff(QBase):
    def test_delay_formula(self):
        q = self.mkq()
        g = q.consume("c1", "g", backoff_base_s=1.0, backoff_max_s=10.0)
        q.rand = lambda: 0.0   # 下限 d/2
        self.assertEqual([q.backoff_delay(n, g) for n in (1, 2, 3, 4, 5, 6)],
                         [0.5, 1.0, 2.0, 4.0, 5.0, 5.0])
        q.rand = lambda: 0.999999  # 上限 d
        self.assertAlmostEqual(q.backoff_delay(3, g), 4.0, places=4)
        self.assertAlmostEqual(q.backoff_delay(10, g), 10.0, places=4)
        g.backoff_base_s = 0
        self.assertEqual(q.backoff_delay(3, g), 0.0)

    def test_jitter_spreads(self):
        q = self.mkq()
        g = q.consume("c1", "g", backoff_base_s=1.0)
        ds = {round(q.backoff_delay(3, g), 6) for _ in range(50)}
        self.assertGreater(len(ds), 10)
        self.assertTrue(all(2.0 <= d < 4.0 for d in ds))

    def test_backoff_blocks_redelivery_not_head(self):
        q = self.mkq()
        q.consume("c1", "g", backoff_base_s=10.0)
        q.rand = lambda: 0.0
        q.publish("a", b"1")
        q.publish("b", b"2")
        now = 1000.0
        d = q.deliver("g", now=now)
        self.assertEqual(d.message_id, "a")
        self.assertEqual(q._requeue_or_dead(d.mid, q.groups["g"], now=now),
                         "queued")
        self.assertEqual(q.messages[d.mid].not_before, now + 5.0)
        # a 在退避中：不阻塞 b
        self.assertEqual(q.deliver("g", now=now + 1).message_id, "b")
        self.assertIsNone(q.deliver("g", now=now + 4.9))
        self.assertEqual(q.next_retry_at(now=now + 1), now + 5.0)
        d2 = q.deliver("g", now=now + 5.0)
        self.assertEqual((d2.message_id, d2.pend_count), ("a", 2))

    def test_timeout_path_uses_backoff_then_dead(self):
        q = self.mkq()
        q.consume("c1", "g", ack_wait_s=1, max_deliver=3, backoff_base_s=2.0)
        q.rand = lambda: 0.0
        q.publish("a", b"1")
        t = 0.0
        delays = []
        for _ in range(3):
            while True:
                d = q.deliver("g", now=t)
                if d is not None:
                    break
                t += 0.5
            t += 1.0
            out = q.sweep_timeouts(now=t)
            if out[0][1] == "queued":
                delays.append(q.messages[d.mid].not_before - t)
        self.assertEqual(out, [(d.mid, "dead")])
        self.assertEqual(delays, [1.0, 2.0])  # d/2：2^0*2/2, 2^1*2/2
        self.assertEqual(q.dead_letters()[0]["reason"], DEAD_EXHAUSTED)

    def test_backoff_survives_restart(self):
        q = self.mkq()
        q.consume("c1", "g", backoff_base_s=100.0)
        q.publish("a", b"1")
        d = q.deliver("g")
        q.ack("g", d.mid, "c1", requeue=True)
        nb = q.messages[d.mid].not_before
        q.log.close()
        q2 = self.mkq()
        self.assertEqual(q2.messages[d.mid].not_before, nb)
        q2.consume("c1", "g")
        self.assertIsNone(q2.deliver("g"))


class TestReplyAfterFsync(TmpDir):
    """server 的应答在 fsync 完成后才发出（先落盘再回复）。"""

    def test_publish_reply_waits_for_fsync(self):
        from agent_sock.server import Server
        from agent_sock.client import Client
        gate = threading.Event()
        orig = durable._fsync_all
        durable._fsync_all = lambda fds: (gate.wait(5), orig(fds))

        async def go():
            sock = os.path.join(self.tmp, "s.sock")
            srv = Server(sock_path=sock, data_dir=self.tmp)
            st = asyncio.ensure_future(srv.serve())
            await asyncio.sleep(0.1)
            gate.set()                       # register 本身也要等 fsync
            c = Client(agent_id="a", sock_path=sock)
            await c.connect()
            gate.clear()
            t = asyncio.ensure_future(c.publish("task.dispatch", "m1", "x"))
            await asyncio.sleep(0.3)
            before = t.done()
            gate.set()
            mid = await asyncio.wait_for(t, 5)
            await c.close()
            st.cancel()
            try:
                await st
            except BaseException:
                pass
            return before, mid
        try:
            before, mid = asyncio.run(go())
        finally:
            durable._fsync_all = orig
        self.assertFalse(before)
        self.assertGreater(mid, 0)


# ------------------------------------------------- 集成：真实 server 子进程

class ServerProc:
    def __init__(self, tmp, fsync=True):
        self.tmp = tmp
        self.sock = os.path.join(tmp, "s.sock")
        self.data = os.path.join(tmp, "data")
        self.fsync = fsync
        self.p = None

    def start(self):
        if os.path.exists(self.sock):
            os.unlink(self.sock)
        args = [sys.executable, "-m", "agent_sock.server",
                "--sock", self.sock, "--data-dir", self.data]
        if not self.fsync:
            args.append("--no-fsync")
        env = dict(os.environ, PYTHONPATH=PKG_ROOT)
        self.p = subprocess.Popen(args, env=env, cwd=PKG_ROOT,
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.PIPE)
        for _ in range(100):
            if os.path.exists(self.sock):
                return
            time.sleep(0.05)
        raise RuntimeError("server did not start: " +
                           self.p.stderr.read().decode())

    def kill9(self):
        self.p.send_signal(signal.SIGKILL)
        self.p.wait(5)

    def stop(self):
        if self.p and self.p.poll() is None:
            self.kill9()


class TestCrashRecoveryIntegration(TmpDir):
    def setUp(self):
        super().setUp()
        self.srv = ServerProc(self.tmp)
        self.srv.start()

    def tearDown(self):
        self.srv.stop()
        super().tearDown()

    async def _client(self, aid):
        from agent_sock.client import Client
        c = Client(agent_id=aid, sock_path=self.srv.sock)
        await c.connect()
        return c

    @staticmethod
    def _sink(c, got, stamp=False):
        async def h(m):
            got.append((time.time(), m) if stamp else m)
        c.on_deliver(h)

    def test_publish_ack_kill9_restart(self):
        N = 50

        async def phase1():
            pub = await self._client("pub")
            await pub.declare("work", "workqueue")
            mids = [await pub.publish("work", f"m{i}", f"<p>{i}</p>")
                    for i in range(N)]
            sub = await self._client("sub")
            got = []
            self._sink(sub, got)
            await sub.consume("work", group="g")
            t0 = time.time()
            while len(got) < N and time.time() - t0 < 5:
                await asyncio.sleep(0.05)
            # ack 前 20 条；应答返回即已落盘
            for m in got[:20]:
                r = await sub.ack("work", "g", m.body["delivery_id"])
                assert r == "acked", r
            return mids, [m.body["message_id"] for m in got]

        mids, delivered = asyncio.run(phase1())
        self.assertEqual(len(set(mids)), N)
        self.assertEqual(len(delivered), N)
        self.srv.kill9()          # 不给 server 任何收尾机会
        self.srv.start()

        async def phase2():
            sub = await self._client("sub2")
            got = []
            self._sink(sub, got)
            await sub.consume("work", group="g")
            t0 = time.time()
            while len(got) < N - 20 and time.time() - t0 < 5:
                await asyncio.sleep(0.05)
            await asyncio.sleep(0.3)  # 确认没有多余投递
            return got

        got = asyncio.run(phase2())
        ids = sorted(m.body["message_id"] for m in got)
        self.assertEqual(ids, sorted(delivered[20:]))   # 未 ack 的都在
        self.assertTrue(all(m.body["redelivered"] == "true" for m in got))

    def test_reject_dlq_and_backoff_end_to_end(self):
        async def go():
            c = await self._client("w")
            await c.declare("jobs", "workqueue")
            got = []
            self._sink(c, got, stamp=True)
            await c.consume("jobs", group="g", backoff_base_s=0.4,
                            backoff_max_s=5)
            await c.publish("jobs", "poison", "<p/>")
            await c.publish("jobs", "flaky", "<p/>")
            t0 = time.time()
            while len(got) < 2 and time.time() - t0 < 5:
                await asyncio.sleep(0.02)
            byid = {m.body["message_id"]: (t, m) for t, m in got}
            r1 = await c.ack("jobs", "g", byid["poison"][1].body["delivery_id"],
                             reject=True)
            t_req = time.time()
            r2 = await c.ack("jobs", "g", byid["flaky"][1].body["delivery_id"],
                             requeue=True)
            while len(got) < 3 and time.time() - t0 < 5:
                await asyncio.sleep(0.02)
            await asyncio.sleep(0.6)
            return r1, r2, t_req, got
        r1, r2, t_req, got = asyncio.run(go())
        self.assertEqual((r1, r2), ("dead", "queued"))
        self.assertEqual(len(got), 3)   # poison 没有重投
        t3, m3 = got[2]
        self.assertEqual(m3.body["message_id"], "flaky")
        self.assertGreaterEqual(t3 - t_req, 0.18)  # 至少 base/2（含调度误差）
        out = subprocess.run(
            [sys.executable, "-m", "agent_sock.cli", "--data-dir",
             self.srv.data, "dlq", "jobs"],
            env=dict(os.environ, PYTHONPATH=PKG_ROOT), cwd=PKG_ROOT,
            capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        dl = json.loads(out.stdout)["dead"]
        self.assertEqual([(d["message_id"], d["reason"]) for d in dl],
                         [("poison", DEAD_REJECTED)])


if __name__ == "__main__":
    unittest.main()
