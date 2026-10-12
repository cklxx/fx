#!/usr/bin/env python3
"""tests/test_retry.py -- acceptance tests for tools/retry.

Run:  cd tools/retry && python3 -m unittest discover -s tests -v
All automated, stdlib only. Each case uses a temp dir; nothing touches
the repo. CLI cases drive `python3 -m retry` as a subprocess.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from retry import (  # noqa: E402
    ConfigError,
    RetryPolicy,
    run_with_retry,
)


def no_retry_policy(**kw):
    kw.setdefault("backoff", "none")
    kw.setdefault("jitter", False)
    return RetryPolicy.from_dict(kw)


class EngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="retry-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def path(self, name):
        return os.path.join(self.tmp, name)

    # 1. success on the first attempt: no retry happens
    def test_success_first_try(self):
        sleeps = []
        r = run_with_retry(
            ["true"],
            [{"type": "exit_code", "expect": 0}],
            no_retry_policy(max_attempts=3),
            sleep=sleeps.append,
        )
        self.assertTrue(r.ok)
        self.assertEqual(len(r.attempts), 1)
        self.assertEqual(sleeps, [])

    # 2. transient failure then success: exactly one retry
    def test_flaky_succeeds_on_retry(self):
        counter = self.path("count")
        script = self.path("flaky.sh")
        with open(script, "w") as f:
            f.write(
                "#!/bin/sh\n"
                f"n=$(cat {counter} 2>/dev/null || echo 0)\n"
                f"echo $((n+1)) > {counter}\n"
                'if [ "$n" -lt 2 ]; then echo "not ready"; exit 1; fi\n'
                'echo "READY"; exit 0\n'
            )
        os.chmod(script, 0o755)
        sleeps = []
        r = run_with_retry(
            [script],
            [
                {"type": "exit_code", "expect": 0},
                {"type": "pattern", "pattern": "READY", "stream": "stdout"},
            ],
            no_retry_policy(max_attempts=5),
            sleep=sleeps.append,
        )
        self.assertTrue(r.ok)
        self.assertEqual(len(r.attempts), 3)
        self.assertEqual(len(sleeps), 2)  # slept before attempts 2 and 3
        self.assertTrue(r.attempts[0].failed)
        self.assertFalse(r.attempts[2].failed)

    # 3. retries exhausted: all attempts recorded, ok=False
    def test_retries_exhausted(self):
        sleeps = []
        r = run_with_retry(
            ["false"],
            [{"type": "exit_code", "expect": 0, "name": "zero-exit"}],
            no_retry_policy(max_attempts=3),
            sleep=sleeps.append,
        )
        self.assertFalse(r.ok)
        self.assertEqual(len(r.attempts), 3)
        self.assertEqual(len(sleeps), 2)
        self.assertIn("retries exhausted", r.final_reason)
        self.assertEqual(r.attempts[0].checks[0].name, "zero-exit")

    # 4a. config errors: unknown validator type -> ConfigError, nothing runs
    def test_config_error_unknown_validator(self):
        with self.assertRaises(ConfigError):
            run_with_retry(
                ["true"],
                [{"type": "no_such_validator"}],
                no_retry_policy(),
            )

    # 4b. config errors: bad regex -> ConfigError before first execution
    def test_config_error_bad_regex(self):
        ran = []
        with self.assertRaises(ConfigError):
            run_with_retry(
                ["sh", "-c", "echo hi; exit 0"],
                [{"type": "pattern", "pattern": "([unclosed"}],
                no_retry_policy(),
                sleep=ran.append,  # unused; proves no sleep/retry path taken
            )

    # 4c. config errors: missing required key, bad policy values
    def test_config_error_variants(self):
        with self.assertRaises(ConfigError):
            run_with_retry(["true"], [{"type": "exit_code"}], no_retry_policy())
        with self.assertRaises(ConfigError):
            run_with_retry(["true"], ["not-a-dict"], no_retry_policy())
        with self.assertRaises(ConfigError):
            RetryPolicy.from_dict({"max_attempts": 0})
        with self.assertRaises(ConfigError):
            RetryPolicy.from_dict({"backoff": "sometimes"})
        with self.assertRaises(ConfigError):
            run_with_retry(12345, [], no_retry_policy())

    # 5. pattern validator: negative pattern (must_match: false)
    def test_pattern_must_not_match(self):
        r = run_with_retry(
            ["sh", "-c", "echo all good"],
            [{"type": "pattern", "pattern": "ERROR|FATAL", "must_match": False}],
            no_retry_policy(),
        )
        self.assertTrue(r.ok)
        r = run_with_retry(
            ["sh", "-c", "echo FATAL boom"],
            [{"type": "pattern", "pattern": "ERROR|FATAL", "must_match": False}],
            no_retry_policy(max_attempts=2),
        )
        self.assertFalse(r.ok)
        self.assertEqual(len(r.attempts), 2)

    # 6. file_exists validator
    def test_file_exists(self):
        target = self.path("report.md")
        r = run_with_retry(
            ["sh", "-c", f"echo x > {target}"],
            [{"type": "file_exists", "path": target}],
            no_retry_policy(),
        )
        self.assertTrue(r.ok)
        r = run_with_retry(
            ["true"],
            [{"type": "file_exists", "path": self.path("missing.txt")}],
            no_retry_policy(max_attempts=2),
        )
        self.assertFalse(r.ok)
        self.assertEqual(len(r.attempts), 2)

    # 7. non-retryable failure: fail fast, exactly one attempt
    def test_fail_fast_no_retry(self):
        sleeps = []
        r = run_with_retry(
            ["false"],
            [{"type": "exit_code", "expect": 0, "retryable": False}],
            no_retry_policy(max_attempts=5),
            sleep=sleeps.append,
        )
        self.assertFalse(r.ok)
        self.assertEqual(len(r.attempts), 1)
        self.assertTrue(r.attempts[0].fail_fast)
        self.assertEqual(sleeps, [])
        self.assertIn("non-retryable", r.final_reason)

    # 8. exponential backoff delays grow 1,2,4 (jitter off)
    def test_exponential_backoff(self):
        p = RetryPolicy.from_dict(
            {"backoff": "exponential", "base_delay_s": 1.0, "jitter": False,
             "max_delay_s": 100.0}
        )
        self.assertEqual([p.delay_for(n) for n in (1, 2, 3)], [1.0, 2.0, 4.0])
        p2 = RetryPolicy.from_dict(
            {"backoff": "fixed", "base_delay_s": 2.5, "jitter": False}
        )
        self.assertEqual([p2.delay_for(n) for n in (1, 2, 3)], [2.5, 2.5, 2.5])
        p3 = RetryPolicy.from_dict(
            {"backoff": "exponential", "base_delay_s": 100.0,
             "max_delay_s": 3.0, "jitter": False}
        )
        self.assertEqual(p3.delay_for(5), 3.0)  # capped

    # 9. per-attempt timeout counts as failure and is retried
    def test_timeout_retried(self):
        sleeps = []
        r = run_with_retry(
            ["sleep", "5"],
            [{"type": "exit_code", "expect": 0}],
            RetryPolicy.from_dict(
                {"max_attempts": 2, "backoff": "none", "timeout_s": 0.2,
                 "jitter": False}
            ),
            sleep=sleeps.append,
        )
        self.assertFalse(r.ok)
        self.assertEqual(len(r.attempts), 2)
        self.assertTrue(all(a.timed_out for a in r.attempts))

    # 10. warn severity does not fail the run
    def test_warn_does_not_fail(self):
        r = run_with_retry(
            ["sh", "-c", "echo ok"],
            [
                {"type": "exit_code", "expect": 0},
                {"type": "pattern", "pattern": "zzz", "severity": "warn"},
            ],
            no_retry_policy(),
        )
        self.assertTrue(r.ok)
        self.assertFalse(r.attempts[0].checks[1].passed)

    # 11. validator results carry names and reasons on failure
    def test_failure_reasons_recorded(self):
        r = run_with_retry(
            ["sh", "-c", "echo hello"],
            [{"type": "pattern", "pattern": "goodbye", "name": "says-goodbye"}],
            no_retry_policy(max_attempts=1),
        )
        self.assertFalse(r.ok)
        c = r.attempts[0].checks[0]
        self.assertEqual(c.name, "says-goodbye")
        self.assertIn("goodbye", c.reason)


class CLITest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="retry-cli-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, spec_text, extra=()):
        spec = os.path.join(self.tmp, "spec.yaml")
        with open(spec, "w") as f:
            f.write(spec_text)
        env = dict(os.environ, PYTHONPATH=ROOT)
        return subprocess.run(
            [sys.executable, "-m", "retry", spec, *extra],
            capture_output=True, text=True, env=env, cwd=ROOT,
        )

    def test_cli_success(self):
        p = self.run_cli(
            "command: \"echo BUILD OK\"\n"
            "retry:\n  max_attempts: 2\n  backoff: none\n"
            "validators:\n"
            "  - type: exit_code\n    expect: 0\n"
            "  - type: pattern\n    pattern: \"BUILD OK\"\n"
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("RESULT: OK", p.stdout)

    def test_cli_exhausted(self):
        p = self.run_cli(
            "command: \"exit 3\"\n"
            "retry:\n  max_attempts: 2\n  backoff: none\n"
            "validators:\n  - type: exit_code\n    expect: 0\n"
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("RESULT: FAILED", p.stdout)
        self.assertIn("retries exhausted", p.stdout)

    def test_cli_config_error(self):
        p = self.run_cli(
            "command: \"true\"\n"
            "validators:\n  - type: bogus\n"
        )
        self.assertEqual(p.returncode, 2)
        self.assertIn("config error", p.stderr)

    def test_cli_json(self):
        p = self.run_cli(
            "command: [\"true\"]\n"
            "retry:\n  max_attempts: 1\n  backoff: none\n"
            "validators:\n  - type: exit_code\n    expect: 0\n",
            extra=("--json",),
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        d = json.loads(p.stdout)
        self.assertTrue(d["ok"])
        self.assertEqual(len(d["attempts"]), 1)
        self.assertTrue(d["attempts"][0]["checks"][0]["passed"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
