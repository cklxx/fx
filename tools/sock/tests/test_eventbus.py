"""eventbus 测试：通配匹配、CloudEvents 信封。"""
import unittest

from agent_sock.eventbus import _match, cloudevent


class TestMatch(unittest.TestCase):
    def test_exact(self):
        self.assertTrue(_match("task.queued", "task.queued"))
        self.assertFalse(_match("task.queued", "task.failed"))

    def test_star(self):
        self.assertTrue(_match("task.*", "task.queued"))
        self.assertTrue(_match("task.*", "task.failed"))
        self.assertFalse(_match("task.*", "task"))
        self.assertFalse(_match("task.*", "agent.started"))

    def test_gt(self):
        self.assertTrue(_match(">", "anything.at.all"))
        self.assertTrue(_match("task.>", "task.a.b.c"))

    def test_mixed(self):
        self.assertTrue(_match("*.failed", "task.failed"))
        self.assertFalse(_match("*.failed", "task.queued"))


class TestCloudEvent(unittest.TestCase):
    def test_envelope(self):
        ce = cloudevent("task.queued", {"task_id": "t1"})
        self.assertEqual(ce["specversion"], "1.0")
        self.assertEqual(ce["type"], "task.queued")
        self.assertEqual(ce["data"]["task_id"], "t1")
        self.assertIn("id", ce)
        self.assertIn("time", ce)


if __name__ == "__main__":
    unittest.main()
