"""CLI: python3 -m retry <spec.yaml> [--json] [--max-attempts N].

Spec format (YAML):

  command: "make build"            # shell string, or argv: [make, build]
  cwd: /path/to/workdir            # optional
  timeout_s: 60                    # optional, per attempt
  retry:
    max_attempts: 3
    backoff: exponential            # none | fixed | exponential
    base_delay_s: 1.0
    max_delay_s: 60.0
    jitter: true
  validators:
    - type: exit_code
      expect: 0
    - type: pattern
      pattern: "BUILD OK"
      stream: stdout                # stdout | stderr | either
      must_match: true
    - type: file_exists
      path: ./report.md
      retryable: false              # wrong-path class: fail fast, no retry

Exit codes: 0 ok, 1 validation/retry failure, 2 config error.
"""

from __future__ import annotations

import argparse
import json
import sys

import yaml

from . import __version__
from .engine import RetryPolicy, run_with_retry
from .validators import ConfigError


def load_spec(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        spec = yaml.safe_load(f)
    if not isinstance(spec, dict):
        raise ConfigError(f"{path}: spec must be a YAML mapping")
    return spec


def summarize(result) -> str:
    lines = []
    for a in result.attempts:
        status = "ok" if not a.failed else ("fail-fast" if a.fail_fast else "failed")
        lines.append(f"attempt {a.n}: {status} (exit={a.exit_code})")
        for c in a.checks:
            mark = "ok" if c.passed else "FAIL"
            extra = f" [{c.severity}]" if c.severity != "error" else ""
            lines.append(f"  [{mark}] {c.name}{extra}" + (f": {c.reason}" if c.reason else ""))
        if a.delay_before_next_s:
            lines.append(f"  sleeping {a.delay_before_next_s:.2f}s before retry")
    lines.append("RESULT: " + ("OK" if result.ok else "FAILED") + " - " + result.final_reason)
    return "\n".join(lines)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        prog="retry", description="Run a command with post-execution validation and retry."
    )
    p.add_argument("spec", help="YAML spec file")
    p.add_argument("--json", action="store_true", help="print machine-readable JSON result")
    p.add_argument("--max-attempts", type=int, default=None, help="override retry.max_attempts")
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = p.parse_args(argv)

    try:
        spec = load_spec(args.spec)
    except ConfigError as e:
        print(f"config error: {e}", file=sys.stderr)
        return 2
    except OSError as e:
        print(f"config error: cannot read {args.spec}: {e}", file=sys.stderr)
        return 2

    command = spec.get("command") or spec.get("argv")
    if command is None:
        print("config error: spec needs 'command' or 'argv'", file=sys.stderr)
        return 2
    validators = spec.get("validators", [])
    if not isinstance(validators, list) or not validators:
        print("config error: spec needs a non-empty 'validators' list", file=sys.stderr)
        return 2

    try:
        policy = RetryPolicy.from_dict(spec.get("retry", {}))
        if args.max_attempts is not None:
            policy.max_attempts = args.max_attempts
        if "timeout_s" in spec:
            policy.timeout_s = spec["timeout_s"]
        result = run_with_retry(
            command,
            validators,
            policy,
            shell=spec.get("shell"),
            cwd=spec.get("cwd"),
            env=spec.get("env"),
        )
    except ConfigError as e:
        print(f"config error: {e}", file=sys.stderr)
        return 2

    # timeout_s may live at spec top level
    if args.json:
        d = {
            "ok": result.ok,
            "final_reason": result.final_reason,
            "attempts": [
                {
                    "n": a.n,
                    "exit_code": a.exit_code,
                    "timed_out": a.timed_out,
                    "failed": a.failed,
                    "fail_fast": a.fail_fast,
                    "delay_before_next_s": round(a.delay_before_next_s, 3),
                    "checks": [
                        {
                            "name": c.name,
                            "passed": c.passed,
                            "reason": c.reason,
                            "severity": c.severity,
                            "retryable": c.retryable,
                        }
                        for c in a.checks
                    ],
                    "stdout": a.stdout,
                    "stderr": a.stderr,
                }
                for a in result.attempts
            ],
        }
        print(json.dumps(d, indent=2))
    else:
        print(summarize(result))
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
