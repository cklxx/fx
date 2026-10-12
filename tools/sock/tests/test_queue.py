"""queue 测试：对标 TLA+ WorkQueue.tla 的性质。

P1 无孤儿 in-flight / P2 幂等 / P3 死信有界 / P4 无幻影 /
P7 已取消永不投递 / requeue_or_dead 单原语 / tombstone 不占队头。
DESIGN.md §7 test_queue.py 用例全覆盖。
"""
import shutil
import tempfile
import unittest

from agent_sock import errors
from agent_sock.queue import Queue, QueueDeclare


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.q = Queue(QueueDeclare(name="t", semantics="workqueue"),
                       self.tmp)
        self.q.consume("c1", "g", ack_wait_s=30, max_deliver=3)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def pub(self, mid_suffix, payload=b"x"):
        mid, _ = self.q.publish(f"msg-{mid_suffix}", payload)
        return mid


class TestDeliverFifo(Base):
    def test_fifo_order(self):
        m1, m2, m3 = self.pub(1), self.pub(2), self.pub(3)
        d1 = self.q.deliver("g")
        d2 = self.q.deliver("g")
        self.assertEqual((d1.mid, d2.mid), (m1, m2))

    def test_competing_consumers_exactly_one(self):
        """竞争消费：同一消息恰一人拿到。"""
        self.q.consume("c2", "g")
        mid = self.pub(1)
        d1 = self.q.deliver("g")
        # deliver 在 pending 最少的成员间选择；c1/c2 均为 0 pending，
        # 谁拿到取决于集合序（未定义），但恰好一人拿到且 d2 为空。
        d2 = self.q.deliver("g")
        self.assertIsNone(d2)  # 只有一条消息，已被持有
        self.assertIn(d1.pend_consumer, ("c1", "c2"))

    def test_idempotent_publish(self):
        m1, _ = self.q.publish("dup", b"x")
        m2, _ = self.q.publish("dup", b"x")
        self.assertEqual(m1, m2)


class TestTombstone(Base):
    def test_cancelled_never_delivered(self):
        """P7：已取消永不投递。"""
        self.pub(1)
        self.assertTrue(self.q.cancel("msg-1"))
        self.assertIsNone(self.q.deliver("g"))

    def test_tombstone_not_head_blocking(self):
        """tombstone 不占队头：队头取消后，后续任务仍可投递。"""
        self.pub(1)
        m2 = self.pub(2)
        self.q.cancel("msg-1")
        d = self.q.deliver("g")
        self.assertIsNotNone(d)
        self.assertEqual(d.mid, m2)  # 跳过已取消的队头，取最小未取消

    def test_cancel_pending_is_noop(self):
        m1 = self.pub(1)
        d = self.q.deliver("g")
        self.assertFalse(self.q.cancel("msg-1"))  # pending 不可取消

    def test_tombstone_persists_after_requeue(self):
        """tombstone 持久：重入后仍被过滤（P7 关键）。"""
        self.pub(1)
        self.pub(2)
        self.q.cancel("msg-1")
        d = self.q.deliver("g")
        self.assertEqual(d.message_id, "msg-2")
        d.deliver_at = 0  # 强制超时回池
        self.q.sweep_timeouts()
        d2 = self.q.deliver("g")
        self.assertEqual(d2.message_id, "msg-2")  # msg-1 仍被过滤


class TestRequeueOrDead(Base):
    def test_timeout_requeue(self):
        m1 = self.pub(1)
        d = self.q.deliver("g")
        d.deliver_at = 0  # 强制超时
        out = self.q.sweep_timeouts()
        self.assertEqual(out, [(m1, "queued")])
        # 重投后可再次投递，pend_count 累加
        d2 = self.q.deliver("g")
        self.assertEqual(d2.pend_count, 2)

    def test_max_deliver_dead(self):
        """P3：打满 max_deliver 进死信。"""
        m1 = self.pub(1)
        for _ in range(3):
            d = self.q.deliver("g")
            d.deliver_at = 0
            self.q.sweep_timeouts()
        m = self.q.messages[m1]
        self.assertEqual(m.state, "dead")

    def test_ack_requeue_flag(self):
        """S3：ack+requeue = 提前 Timeout。"""
        m1 = self.pub(1)
        d = self.q.deliver("g")
        r = self.q.ack("g", d.mid, d.pend_consumer, requeue=True)
        self.assertEqual(r, "queued")
        d2 = self.q.deliver("g")
        self.assertEqual(d2.mid, m1)

    def test_ack_normal(self):
        m1 = self.pub(1)
        d = self.q.deliver("g")
        r = self.q.ack("g", d.mid, d.pend_consumer)
        self.assertEqual(r, "acked")
        self.assertIsNone(self.q.deliver("g"))


class TestBackpressure(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.q = Queue(QueueDeclare(name="t", semantics="workqueue",
                                    max_depth=2, overflow="block"), self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_block(self):
        self.q.publish("a", b"x")
        self.q.publish("b", b"x")
        with self.assertRaises(errors.ErrorPacket) as ctx:
            self.q.publish("c", b"x")
        self.assertEqual(ctx.exception.code, "AEVT-4001")

    def test_drop_oldest(self):
        q = Queue(QueueDeclare(name="t2", semantics="workqueue",
                               max_depth=2, overflow="drop_oldest"),
                  tempfile.mkdtemp())
        q.publish("a", b"x")
        q.publish("b", b"x")
        q.publish("c", b"x")
        self.assertEqual(q.depth(), 2)


class TestEmptyGroup(unittest.TestCase):
    def test_publish_to_empty_group_queues(self):
        """R-02：空组 publish 正常入队 + 告警，不阻塞。"""
        tmp = tempfile.mkdtemp()
        try:
            q = Queue(QueueDeclare(name="t", semantics="workqueue"), tmp)
            mid, alert = q.publish("m1", b"x")
            self.assertEqual(alert, "AEVT-4005")
            self.assertEqual(q.depth(), 1)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestUnconsume(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.q = Queue(QueueDeclare(name="t", semantics="workqueue"), self.tmp)
        self.q.consume("c1", "g", ack_wait_s=30, max_deliver=3)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_unconsume_recycles_inflight(self):
        """Leave：in-flight 经 requeue_or_dead 回池。"""
        self.q.publish("m1", b"x")
        d = self.q.deliver("g")
        self.q.unconsume("c1", "g")
        m = self.q.messages[d.mid]
        self.assertEqual(m.state, "queued")  # 回池，未打满

    def test_unconsume_idempotent(self):
        self.q.unconsume("nobody", "g")  # 不抛异常


class TestTopic(unittest.TestCase):
    def test_topic_no_group(self):
        tmp = tempfile.mkdtemp()
        try:
            q = Queue(QueueDeclare(name="ev", semantics="topic"), tmp)
            with self.assertRaises(errors.ErrorPacket):
                q.consume("w", "somegroup")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
