"""§11 任务层单元测试（假时钟，不起 server）。"""
import os
import shutil
import tempfile
import unittest

from agent_sock import errors
from agent_sock.tasks import TaskList, PENDING, CLAIMED, COMPLETED, FAILED, CANCELLED
from agent_sock.worktree import check_gate, MergeRejected


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class TestTaskList(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.clock = Clock()
        self.tl = TaskList(self.tmp, now=self.clock)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def reopen(self):
        return TaskList(self.tmp, now=self.clock)

    def code(self, ctx):
        return ctx.exception.code

    def test_deps_block_and_unblock(self):
        self.tl.create([{"task_id": "a"}, {"task_id": "b"},
                        {"task_id": "c", "deps": ["a", "b"]}])
        self.assertFalse(self.tl.claimable(self.tl.get("c")))
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.claim("w", "c")
        self.assertEqual(self.code(ctx), "AEVT-4104")
        a = self.tl.claim("w", "a")
        _, unb = self.tl.complete("a", a.token)
        self.assertEqual(unb, [])  # b 还没完成
        b = self.tl.claim("w", "b")
        _, unb = self.tl.complete("b", b.token)
        self.assertEqual([t.task_id for t in unb], ["c"])
        self.assertEqual(self.tl.claim("w").task_id, "c")

    def test_claim_any_fifo_and_none(self):
        self.tl.create([{"task_id": "x"}, {"task_id": "y"}])
        self.assertEqual(self.tl.claim("w").task_id, "x")
        self.assertEqual(self.tl.claim("w").task_id, "y")
        self.assertIsNone(self.tl.claim("w"))

    def test_cycle_rejected_and_atomic(self):
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.create([{"task_id": "a", "deps": ["c"]},
                            {"task_id": "b", "deps": ["a"]},
                            {"task_id": "c", "deps": ["b"]}])
        self.assertEqual(self.code(ctx), "AEVT-4103")
        self.assertIn("cycle", ctx.exception.message)
        self.assertEqual(self.tl.list(), [])  # 全部不写入
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.create([{"task_id": "s", "deps": ["s"]}])
        self.assertEqual(self.code(ctx), "AEVT-4103")
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.create([{"task_id": "u", "deps": ["nope"]}])
        self.assertEqual(self.code(ctx), "AEVT-4103")

    def test_idempotency_and_duplicate(self):
        (t1, c1), = self.tl.create([{"task_id": "a", "idem_key": "k"}])
        (t2, c2), = self.tl.create([{"task_id": "other", "idem_key": "k"}])
        self.assertTrue(c1)
        self.assertFalse(c2)
        self.assertIs(t1, t2)
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.create([{"task_id": "a"}])
        self.assertEqual(self.code(ctx), "AEVT-4107")

    def test_lease_expiry_and_fencing(self):
        """核心：A 认领后卡住超过租约，B 认领（token+1），A 回来 complete 被拒，B 成功。"""
        self.tl.create([{"task_id": "t"}])
        a = self.tl.claim("A", "t", lease_s=10)
        tok_a = a.token
        self.clock.t += 11
        b = self.tl.claim("B", "t", lease_s=10)
        self.assertEqual(b.token, tok_a + 1)
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.complete("t", tok_a, "from A")
        self.assertEqual(self.code(ctx), "AEVT-4101")
        for op in (lambda: self.tl.renew("t", tok_a),
                   lambda: self.tl.fail("t", tok_a)):
            with self.assertRaises(errors.ErrorPacket) as ctx:
                op()
            self.assertEqual(self.code(ctx), "AEVT-4101")
        self.tl.complete("t", tok_a + 1, "from B")
        t = self.tl.get("t")
        self.assertEqual((t.state, t.result, t.completed_token),
                         (COMPLETED, "from B", tok_a + 1))

    def test_expired_holder_rejected_even_before_reclaim(self):
        self.tl.create([{"task_id": "t"}])
        a = self.tl.claim("A", "t", lease_s=5)
        self.clock.t += 6
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.complete("t", a.token)
        self.assertEqual(self.code(ctx), "AEVT-4101")
        self.assertEqual(self.tl.get("t").state, PENDING)

    def test_renew_extends_lease(self):
        self.tl.create([{"task_id": "t"}])
        a = self.tl.claim("A", "t", lease_s=10)
        for _ in range(5):
            self.clock.t += 8
            self.tl.renew("t", a.token, lease_s=10)
        self.assertEqual(self.tl.get("t").state, CLAIMED)
        self.tl.complete("t", a.token)

    def test_max_attempts_then_failed_hook(self):
        hit = []
        self.tl.on_exhausted = hit.append
        self.tl.create([{"task_id": "t", "max_attempts": 2}])
        for _ in range(2):
            self.tl.claim("A", "t", lease_s=1)
            self.clock.t += 2
            self.tl.sweep()
        t = self.tl.get("t")
        self.assertEqual((t.state, t.attempts), (FAILED, 2))
        self.assertEqual([x.task_id for x in hit], ["t"])

    def test_fail_retry(self):
        self.tl.create([{"task_id": "t", "max_attempts": 2}])
        a = self.tl.claim("A", "t")
        self.tl.fail("t", a.token, "boom", retry=True)
        self.assertEqual(self.tl.get("t").state, PENDING)
        b = self.tl.claim("A", "t")
        self.tl.fail("t", b.token, "boom", retry=True)
        self.assertEqual(self.tl.get("t").state, FAILED)

    def test_cancel_invalidates_holder(self):
        self.tl.create([{"task_id": "t"}])
        a = self.tl.claim("A", "t")
        self.tl.cancel("t")
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.complete("t", a.token)
        self.assertEqual(self.code(ctx), "AEVT-4105")
        self.assertEqual(self.tl.get("t").state, CANCELLED)

    def test_recovery_restores_everything(self):
        self.tl.create([{"task_id": "a"}, {"task_id": "b", "deps": ["a"]},
                        {"task_id": "c", "idem_key": "kc"}])
        tok1 = self.tl.claim("A", "a", lease_s=5).token
        self.clock.t += 6
        tok2 = self.tl.claim("B", "a", lease_s=100).token
        tok_c = self.tl.claim("A", "c", lease_s=5).token
        self.assertEqual(tok2, tok1 + 1)
        tl2 = self.reopen()
        self.assertEqual(tl2.get("a").token, tok2)
        self.assertEqual(tl2.get("a").state, CLAIMED)
        self.assertEqual(tl2.get("a").holder, "B")
        self.assertEqual(tl2.get("b").deps, ["a"])
        self.assertEqual(tl2.idem["kc"], "c")
        # 旧 token 重启后照样被拒
        with self.assertRaises(errors.ErrorPacket) as ctx:
            tl2.complete("a", tok1)
        self.assertEqual(self.code(ctx), "AEVT-4101")
        # c 的租约在停机期间过期：重启后按过期处理，新 token 更大
        self.clock.t += 10
        c2 = tl2.claim("Z", "c")
        self.assertEqual(c2.token, tok_c + 1)
        tl2.complete("a", tok2)
        tl3 = self.reopen()
        self.assertTrue(tl3.claimable(tl3.get("b")))
        self.assertEqual(tl3.get("c").token, tok_c + 1)

    def test_truncated_last_line_tolerated(self):
        self.tl.create([{"task_id": "a"}])
        with open(os.path.join(self.tmp, "log.jsonl"), "a") as f:
            f.write('{"rec": "task.cla')
        self.assertEqual(self.reopen().get("a").state, PENDING)

    def test_workdir_per_claim(self):
        self.tl.create([{"task_id": "t"}])
        a = self.tl.claim("A", "t", lease_s=1, workroot="/w")
        self.assertEqual(a.workdir, "/w/t-t1")  # 注意：claim 返回同一对象
        self.clock.t += 2
        b = self.tl.claim("B", "t", workroot="/w")
        self.assertEqual(b.workdir, "/w/t-t2")

    def test_bad_lease(self):
        self.tl.create([{"task_id": "t"}])
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.tl.claim("A", "t", lease_s=0)
        self.assertEqual(self.code(ctx), "AEVT-4007")


class TestDepFailed(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.clock = Clock()
        self.tl = TaskList(self.tmp, now=self.clock)
        self.hits = []
        self.tl.on_dep_failed = lambda t, d: self.hits.append((t.task_id, d))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def states(self, tl=None):
        tl = tl or self.tl
        return {t.task_id: (t.state, t.error) for t in tl.list()}

    def test_chain_fail(self):
        self.tl.create([{"task_id": "A"}, {"task_id": "B", "deps": ["A"]},
                        {"task_id": "C", "deps": ["B"]}])
        a = self.tl.claim("w", "A")
        self.tl.fail("A", a.token, "boom")
        st = self.states()
        self.assertEqual(st["B"], (FAILED, "dep_failed:A"))
        self.assertEqual(st["C"], (FAILED, "dep_failed:B"))
        self.assertEqual(self.hits, [("B", "A"), ("C", "B")])
        self.assertEqual(self.states(TaskList(self.tmp, now=self.clock)), st)

    def test_diamond_cancel(self):
        self.tl.create([{"task_id": "A"}, {"task_id": "B", "deps": ["A"]},
                        {"task_id": "C", "deps": ["A"]},
                        {"task_id": "D", "deps": ["B", "C"]},
                        {"task_id": "E"}])
        self.tl.cancel("A")
        st = self.states()
        self.assertEqual(st["A"][0], CANCELLED)
        self.assertEqual(st["B"], (FAILED, "dep_failed:A"))
        self.assertEqual(st["C"], (FAILED, "dep_failed:A"))
        self.assertEqual(st["D"], (FAILED, "dep_failed:B"))  # 只记一次
        self.assertEqual(st["E"][0], PENDING)
        self.assertEqual(len(self.hits), 3)
        with open(os.path.join(self.tmp, "log.jsonl")) as f:
            recs = [l for l in f if '"dep_failed"' in l]
        self.assertEqual(len(recs), 3)  # 每个变化的任务一条记录
        self.assertEqual(self.states(TaskList(self.tmp, now=self.clock)), st)

    def test_exhaust_trigger(self):
        self.tl.create([{"task_id": "A", "max_attempts": 1},
                        {"task_id": "B", "deps": ["A"]}])
        self.tl.claim("w", "A", lease_s=1)
        self.clock.t += 2
        self.tl.sweep()
        self.assertEqual(self.states()["B"], (FAILED, "dep_failed:A"))
        self.assertEqual(self.states(TaskList(self.tmp, now=self.clock)),
                         self.states())

    def _log(self):
        with open(os.path.join(self.tmp, "log.jsonl")) as f:
            return f.readlines()

    def test_recovery_completes_interrupted_cascade(self):
        self.tl.create([{"task_id": "A"}, {"task_id": "B", "deps": ["A"]},
                        {"task_id": "C", "deps": ["B"]}])
        a = self.tl.claim("w", "A")
        self.tl.fail("A", a.token, "boom")
        lines = self._log()
        self.assertIn('"dep": "B"', lines[-1])  # C 的记录在最后
        with open(os.path.join(self.tmp, "log.jsonl"), "w") as f:
            f.writelines(lines[:-1])  # 模拟崩溃：丢掉 C 的记录
        tl2 = TaskList(self.tmp, now=self.clock)
        self.assertEqual((tl2.get("C").state, tl2.get("C").error),
                         (FAILED, "dep_failed:B"))
        self.assertEqual(self._log(), lines)  # 记录已补写，内容一致

    def test_recovery_idempotent(self):
        self.tl.create([{"task_id": "A"}, {"task_id": "B", "deps": ["A"]},
                        {"task_id": "C", "deps": ["A", "B"]}])
        self.tl.cancel("A")
        n = len(self._log())
        TaskList(self.tmp, now=self.clock)
        TaskList(self.tmp, now=self.clock)
        self.assertEqual(len(self._log()), n)

    def test_retry_fail_does_not_cascade(self):
        self.tl.create([{"task_id": "A", "max_attempts": 2},
                        {"task_id": "B", "deps": ["A"]}])
        a = self.tl.claim("w", "A")
        self.tl.fail("A", a.token, "x", retry=True)
        self.assertEqual(self.states()["B"][0], PENDING)

    def test_partial_completed_dep_still_cascades(self):
        self.tl.create([{"task_id": "A"}, {"task_id": "X"},
                        {"task_id": "B", "deps": ["A", "X"]}])
        a = self.tl.claim("w", "A")
        self.tl.complete("A", a.token)
        self.tl.cancel("X")
        self.assertEqual(self.states()["B"], (FAILED, "dep_failed:X"))


class TestGate(unittest.TestCase):
    def test_gate(self):
        check_gate({"task_id": "t", "state": "completed",
                    "completed_token": 2}, 2)
        with self.assertRaises(MergeRejected):
            check_gate({"task_id": "t", "state": "completed",
                        "completed_token": 2}, 1)
        with self.assertRaises(MergeRejected):
            check_gate({"task_id": "t", "state": "claimed",
                        "completed_token": 0}, 1)


if __name__ == "__main__":
    unittest.main()
