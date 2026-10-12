"""tmux 测试：无 tmux 时跳过，有 tmux 时跑真实命令。"""
import shutil
import unittest

from agent_sock import errors
from agent_sock.tmux_tool import TmuxTool

HAS_TMUX = shutil.which("tmux") is not None


@unittest.skipUnless(HAS_TMUX, "tmux not installed")
class TestTmux(unittest.TestCase):
    def setUp(self):
        self.tool = TmuxTool(sock="/tmp/asock-test-tmux.sock")

    def test_spawn_and_alive(self):
        self.tool.spawn_agent("test1", "sleep 30")
        try:
            self.assertTrue(self.tool.agent_alive("test1"))
        finally:
            self.tool.terminate("test1")

    def test_terminate_audit(self):
        self.tool.spawn_agent("test2", "sleep 30")
        audit = self.tool.terminate("test2", graceful_timeout=2)
        self.assertIn("steps", audit)
        self.assertFalse(self.tool.agent_alive("test2"))

    def test_snapshot_restore(self):
        self.tool.spawn_agent("test3", "sleep 30")
        try:
            snap = self.tool.snapshot("test3")
            self.assertIn("windows", snap)
        finally:
            self.tool.terminate("test3")


class TestTmuxMissing(unittest.TestCase):
    @unittest.skipIf(HAS_TMUX, "tmux installed")
    def test_error_code(self):
        t = TmuxTool()
        with self.assertRaises(errors.ErrorPacket) as ctx:
            t.spawn_agent("x", "echo hi")
        self.assertEqual(ctx.exception.code, "ATMUX-1001")


if __name__ == "__main__":
    unittest.main()
