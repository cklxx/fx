"""pipeline 测试：DSL 编译、CELL 检查、环检测、checkpoint。"""
import unittest

from agent_sock import errors
from agent_sock.pipeline import Pipeline, cel_check, cel_to_bash


def spec(**kw):
    base = {
        "name": "t",
        "vars": {"host": "prod-1"},
        "steps": [
            {"id": "build", "run": "make build", "timeout_s": 300,
             "retry": {"times": 2, "backoff_s": 5}},
            {"id": "health", "run": "curl http://{{host}}/health",
             "checkpoint": True, "needs": ["build"]},
        ],
    }
    base.update(kw)
    return base


class TestCel(unittest.TestCase):
    def test_known_vars(self):
        cel_check("steps.build.failed", {"steps"})

    def test_unknown_var(self):
        with self.assertRaises(errors.ErrorPacket):
            cel_check("steps.nope.failed", {"steps"})

    def test_illegal_chars(self):
        with self.assertRaises(errors.ErrorPacket):
            cel_check("steps.build.failed; rm -rf /", {"steps"})

    def test_to_bash(self):
        b = cel_to_bash("steps.build.failed")
        self.assertIn("ASOCK_STATE", b)
        self.assertIn("build.failed", b)


class TestCompile(unittest.TestCase):
    def test_bash_output(self):
        p = Pipeline(spec())
        out = p.compile_bash()
        self.assertIn("#!/bin/bash", out)
        self.assertIn("make build", out)
        self.assertIn("curl http://prod-1/health", out)  # 变量展开
        self.assertIn("timeout -k", out)  # 两段杀

    def test_undefined_var(self):
        s = spec()
        s["steps"][0]["run"] = "echo {{nope}}"
        with self.assertRaises(errors.ErrorPacket):
            Pipeline(s)

    def test_cycle(self):
        s = spec()
        s["steps"][0]["needs"] = ["health"]
        with self.assertRaises(errors.ErrorPacket) as ctx:
            Pipeline(s)
        self.assertIn("cycle", str(ctx.exception).lower())

    def test_effect_llm_requires_checkpoint(self):
        s = spec()
        s["steps"].append({"id": "think", "run": "echo hi",
                           "effect": "llm"})
        with self.assertRaises(errors.ErrorPacket):
            Pipeline(s)

    def test_when_condition(self):
        s = spec()
        s["steps"].append({"id": "rollback", "run": "./rollback.sh",
                           "when": "steps.build.failed",
                           "needs": ["build"]})
        out = Pipeline(s).compile_bash()
        self.assertIn("rollback", out)

    def test_golden_deterministic(self):
        """编译是确定性的：两次输出一致。"""
        self.assertEqual(Pipeline(spec()).compile_bash(),
                         Pipeline(spec()).compile_bash())


if __name__ == "__main__":
    unittest.main()
