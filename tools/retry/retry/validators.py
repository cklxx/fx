"""Post-execution validators for tools/retry.

A validator checks one aspect of an execution result and reports
pass/fail with a human-readable reason. Three built-ins:

  exit_code    the process exit code is in the expected set
  pattern      a regex matches (or must not match) stdout/stderr
  file_exists  a path exists after execution

Each validator carries ``severity`` (``error`` or ``warn``) and
``retryable`` (bool). Only severity=error failures count toward the
overall failure verdict. A non-retryable error failure stops the retry
loop immediately (fail fast); a retryable one is attempted again.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


class ConfigError(ValueError):
    """A validation rule is malformed. Never retried."""


@dataclass
class CheckResult:
    name: str
    passed: bool
    reason: str
    severity: str = "error"      # "error" | "warn"
    retryable: bool = True


@dataclass
class ExecResult:
    """What one command execution produced (filled in by the engine)."""
    exit_code: int
    stdout: str
    stderr: str
    timed_out: bool = False


def _req(spec: Dict[str, Any], key: str, vname: str) -> Any:
    if key not in spec:
        raise ConfigError(f"validator '{vname}': missing required key '{key}'")
    return spec[key]


def _severity_retryable(spec: Dict[str, Any], vname: str) -> tuple[str, bool]:
    severity = spec.get("severity", "error")
    if severity not in ("error", "warn"):
        raise ConfigError(
            f"validator '{vname}': severity must be 'error' or 'warn', "
            f"got {severity!r}"
        )
    retryable = spec.get("retryable", True)
    if not isinstance(retryable, bool):
        raise ConfigError(
            f"validator '{vname}': retryable must be a bool, got {retryable!r}"
        )
    return severity, retryable


def _check_exit_code(name: str, spec: Dict[str, Any], res: ExecResult) -> CheckResult:
    expect = _req(spec, "expect", name)
    codes = [expect] if isinstance(expect, int) else list(expect)
    if not codes or not all(isinstance(c, int) for c in codes):
        raise ConfigError(
            f"validator '{name}': expect must be an int or list of ints, "
            f"got {expect!r}"
        )
    severity, retryable = _severity_retryable(spec, name)
    ok = res.exit_code in codes
    return CheckResult(
        name=name,
        passed=ok,
        reason="" if ok else f"exit code {res.exit_code} not in {codes}",
        severity=severity,
        retryable=retryable,
    )


def _check_pattern(name: str, spec: Dict[str, Any], res: ExecResult) -> CheckResult:
    pattern = _req(spec, "pattern", name)
    stream = spec.get("stream", "stdout")
    if stream not in ("stdout", "stderr", "either"):
        raise ConfigError(
            f"validator '{name}': stream must be stdout|stderr|either, "
            f"got {stream!r}"
        )
    must_match = spec.get("must_match", True)
    if not isinstance(must_match, bool):
        raise ConfigError(
            f"validator '{name}': must_match must be a bool, got {must_match!r}"
        )
    try:
        rx = re.compile(pattern)
    except re.error as e:
        raise ConfigError(f"validator '{name}': bad regex {pattern!r}: {e}")
    haystacks = {
        "stdout": [res.stdout],
        "stderr": [res.stderr],
        "either": [res.stdout, res.stderr],
    }[stream]
    found = any(rx.search(h) for h in haystacks)
    ok = found == must_match
    severity, retryable = _severity_retryable(spec, name)
    verb = "match" if must_match else "not match"
    return CheckResult(
        name=name,
        passed=ok,
        reason="" if ok else f"pattern {pattern!r} did not {verb} {stream}",
        severity=severity,
        retryable=retryable,
    )


def _check_file_exists(name: str, spec: Dict[str, Any], res: ExecResult) -> CheckResult:
    path = _req(spec, "path", name)
    if not isinstance(path, str) or not path:
        raise ConfigError(
            f"validator '{name}': path must be a non-empty string, got {path!r}"
        )
    severity, retryable = _severity_retryable(spec, name)
    ok = os.path.exists(path)
    return CheckResult(
        name=name,
        passed=ok,
        reason="" if ok else f"path does not exist: {path}",
        severity=severity,
        retryable=retryable,
    )


_VALIDATORS = {
    "exit_code": _check_exit_code,
    "pattern": _check_pattern,
    "file_exists": _check_file_exists,
}


def make_validator(spec: Dict[str, Any], index: int):
    """Compile one validator spec into (name, check_fn). Raises ConfigError."""
    if not isinstance(spec, dict):
        raise ConfigError(f"validator #{index}: must be a mapping, got {spec!r}")
    vtype = spec.get("type")
    if vtype not in _VALIDATORS:
        raise ConfigError(
            f"validator #{index}: unknown type {vtype!r}; "
            f"known types: {sorted(_VALIDATORS)}"
        )
    name = spec.get("name", f"{vtype}#{index}")
    fn = _VALIDATORS[vtype]
    return name, lambda res: fn(name, spec, res)


def run_validators(specs: List[Dict[str, Any]], res: ExecResult) -> List[CheckResult]:
    """Run all validators against one execution result."""
    out = []
    for i, spec in enumerate(specs):
        name, fn = make_validator(spec, i)
        out.append(fn(res))
    return out
