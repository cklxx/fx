"""Retry engine: run a command, validate, retry on failure.

Failure model (three classes, from benchmarks/agent-bench/HETEROGENEOUS.md):

  transient   the command can succeed on retry (flaky network, missing
              content the agent writes on the next attempt). Retried.
  permanent   the failure cannot be fixed by repeating the same command
              (wrong path baked into the command, illegal argument).
              Marked non-retryable, fails fast.
  config      the validation rule itself is malformed. Raises ConfigError
              before any execution; never retried.

Only transient failures are retried. The engine does not guess which
class a failure is; the spec author declares it with ``retryable``.
"""

from __future__ import annotations

import random
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from .validators import ConfigError, CheckResult, ExecResult, run_validators


@dataclass
class Attempt:
    n: int                       # 1-based
    exit_code: int
    timed_out: bool
    stdout: str
    stderr: str
    checks: List[CheckResult] = field(default_factory=list)
    failed: bool = False         # any severity=error check failed
    fail_fast: bool = False      # a non-retryable error check failed
    delay_before_next_s: float = 0.0


@dataclass
class RunResult:
    ok: bool
    attempts: List[Attempt] = field(default_factory=list)
    final_reason: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "ok": self.ok,
            "attempts": self.attempts,
            "final_reason": self.final_reason,
        }


@dataclass
class RetryPolicy:
    max_attempts: int = 3
    backoff: str = "exponential"   # none | fixed | exponential
    base_delay_s: float = 1.0
    max_delay_s: float = 60.0
    jitter: bool = True
    timeout_s: Optional[float] = 60.0
    stdout_limit: int = 4096       # stored chars per stream per attempt

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "RetryPolicy":
        d = dict(d or {})
        backoff = d.get("backoff", "exponential")
        if backoff not in ("none", "fixed", "exponential"):
            raise ConfigError(
                f"retry.backoff must be none|fixed|exponential, got {backoff!r}"
            )
        max_attempts = d.get("max_attempts", 3)
        if not isinstance(max_attempts, int) or max_attempts < 1:
            raise ConfigError(
                f"retry.max_attempts must be a positive int, got {max_attempts!r}"
            )
        return cls(
            max_attempts=max_attempts,
            backoff=backoff,
            base_delay_s=float(d.get("base_delay_s", 1.0)),
            max_delay_s=float(d.get("max_delay_s", 60.0)),
            jitter=bool(d.get("jitter", True)),
            timeout_s=d.get("timeout_s", 60.0),
            stdout_limit=int(d.get("stdout_limit", 4096)),
        )

    def delay_for(self, failed_attempt_n: int) -> float:
        """Delay after failed attempt n (1-based) before attempt n+1."""
        if self.backoff == "none":
            return 0.0
        if self.backoff == "fixed":
            d = self.base_delay_s
        else:
            d = self.base_delay_s * (2.0 ** (failed_attempt_n - 1))
        d = min(d, self.max_delay_s)
        if self.jitter:
            d = random.uniform(0, d)
        return d


def _truncate(s: str, limit: int) -> str:
    if len(s) <= limit:
        return s
    return s[:limit] + f"\n...[truncated {len(s) - limit} chars]"


def run_with_retry(
    command: Any,
    validators: List[Dict[str, Any]],
    policy: Optional[RetryPolicy] = None,
    *,
    shell: Optional[bool] = None,
    cwd: Optional[str] = None,
    env: Optional[Dict[str, str]] = None,
    sleep: Callable[[float], None] = time.sleep,
) -> RunResult:
    """Run command, validate, retry transient failures.

    command: argv list, or a shell string when shell=True.
    validators: list of validator specs (see validators.py).
    Raises ConfigError on malformed specs (never retried).
    """
    policy = policy or RetryPolicy()
    if isinstance(command, str):
        use_shell = True if shell is None else shell
    elif isinstance(command, (list, tuple)):
        if shell:
            raise ConfigError("shell=true requires a string command, not argv")
        use_shell = False
    else:
        raise ConfigError(
            f"command must be a string or argv list, got {type(command).__name__}"
        )
    # Compile validators up front: a config error must surface before
    # the first execution, not after N wasted attempts.
    compiled = []
    for i, spec in enumerate(validators):
        from .validators import make_validator
        name, fn = make_validator(spec, i)
        compiled.append((name, fn))

    result = RunResult(ok=False)
    for n in range(1, policy.max_attempts + 1):
        try:
            proc = subprocess.run(
                command,
                shell=use_shell,
                cwd=cwd,
                env=env,
                capture_output=True,
                text=True,
                timeout=policy.timeout_s,
            )
            timed_out = False
            code, out, err = proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired as e:
            timed_out = True
            code = -1
            out = (e.stdout or "") if isinstance(e.stdout, str) else ""
            err = (e.stderr or "") if isinstance(e.stderr, str) else ""
        except (OSError, ValueError) as e:
            # Cannot even spawn: treat as one failed attempt, still
            # retryable (transient environment issue), but record why.
            timed_out = False
            code = -1
            out, err = "", f"spawn failed: {e}"

        exec_res = ExecResult(
            exit_code=code, stdout=out, stderr=err, timed_out=timed_out
        )
        checks = [fn(exec_res) for _, fn in compiled]
        errors = [c for c in checks if not c.passed and c.severity == "error"]
        attempt = Attempt(
            n=n,
            exit_code=code,
            timed_out=timed_out,
            stdout=_truncate(out, policy.stdout_limit),
            stderr=_truncate(err, policy.stdout_limit),
            checks=checks,
            failed=bool(errors),
            fail_fast=any(not c.retryable for c in errors),
        )
        result.attempts.append(attempt)

        if not attempt.failed:
            result.ok = True
            result.final_reason = f"succeeded on attempt {n}"
            return result
        if attempt.fail_fast:
            result.final_reason = (
                f"attempt {n}: non-retryable failure: "
                + "; ".join(c.reason for c in errors if not c.retryable)
            )
            return result
        if n == policy.max_attempts:
            result.final_reason = (
                f"attempt {n}: retries exhausted: "
                + "; ".join(c.reason for c in errors)
            )
            return result
        delay = policy.delay_for(n)
        attempt.delay_before_next_s = delay
        sleep(delay)
    return result  # unreachable; kept for type checkers
