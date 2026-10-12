"""errors 测试：错误码表、分类器。"""
import unittest

from agent_sock import errors


class TestCodes(unittest.TestCase):
    def test_all_codes_known(self):
        for code in ["ASOCK-1001", "ASOCK-2001", "AEVT-4001", "AEVT-4003",
                     "AEVT-4005", "ATMUX-1001", "APIPE-1001"]:
            self.assertIn(code, errors.KNOWN_CODES)

    def test_unknown_code_rejected(self):
        with self.assertRaises(ValueError):
            errors.make("NOPE-0000", "x")

    def test_packet_roundtrip(self):
        p = errors.make("AEVT-4001", task_id="t1",
                        context={"retry_after_s": 1})
        self.assertTrue(p.retryable)
        d = p.to_dict()
        p2 = errors.ErrorPacket.from_dict(d)
        self.assertEqual(p2.code, "AEVT-4001")
        self.assertEqual(p2.task_id, "t1")

    def test_caused_by_single_layer(self):
        inner = errors.make("ATMUX-1001", "no tmux")
        outer = errors.make("ASOCK-2003", "heartbeat timeout",
                            caused_by={"code": inner.code,
                                       "message": inner.message})
        self.assertEqual(outer.caused_by["code"], "ATMUX-1001")


class TestClassifier(unittest.TestCase):
    def test_retryable(self):
        c = errors.Classifier()
        p = errors.make("AEVT-4001", task_id="t1")
        self.assertEqual(c.classify(p), errors.RETRYABLE)

    def test_retry_exhausted(self):
        c = errors.Classifier()
        for _ in range(3):
            p = errors.make("AEVT-4001", task_id="t1")
            self.assertEqual(c.classify(p), errors.RETRYABLE)
        p = errors.make("AEVT-4001", task_id="t1")
        self.assertEqual(c.classify(p), errors.NEEDS_HUMAN)

    def test_fatal(self):
        c = errors.Classifier()
        p = errors.make("AEVT-3001", task_id="t1")
        self.assertEqual(c.classify(p), errors.FATAL)

    def test_non_retryable(self):
        c = errors.Classifier()
        p = errors.make("AEVT-4006", task_id="t1")
        self.assertEqual(c.classify(p), errors.NEEDS_HUMAN)


if __name__ == "__main__":
    unittest.main()
