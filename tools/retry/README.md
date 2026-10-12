# retry

Post-execution validation + retry for tool calls. Prototype for the fx
heterogeneous-decomposition project (agent-bench idea #4).

Problem: `benchmarks/agent-bench/HETEROGENEOUS.md` §2 found that fx has
no recovery mechanism. A small model that writes wrong content, writes
to the wrong path, or passes an illegal argument hard-fails with no
retry. This tool is the missing layer: run a command, check the result
against declared expectations, retry transient failures.

## Layout

- `retry/` — the package (`python3 -m retry spec.yaml`)
  - `engine.py` — run/validate/retry loop, backoff, attempt records
  - `validators.py` — `exit_code`, `pattern`, `file_exists` checks
  - `__main__.py` — CLI
- `tests/test_retry.py` — 17 automated tests, stdlib only
- `examples/` — `spec.yaml` + `flaky_report.sh` demo
- `DESIGN.md` — design rationale and boundaries

## Quick start

```bash
cd tools/retry
python3 -m unittest discover -s tests        # 17/17 expected
rm -f /tmp/retry-demo-count
python3 -m retry examples/spec.yaml          # demo: fails twice, succeeds on attempt 3
python3 -m retry myjob.yaml --json           # machine-readable result
```

## Spec format

```yaml
command: "make build"        # shell string; or argv: [make, build]
cwd: /path/to/workdir        # optional
timeout_s: 60                # optional, per attempt
env: {FOO: bar}              # optional
retry:
  max_attempts: 3
  backoff: exponential       # none | fixed | exponential
  base_delay_s: 1.0
  max_delay_s: 60.0
  jitter: true
validators:
  - type: exit_code
    expect: 0                # int or list of ints
  - type: pattern
    pattern: "BUILD OK"
    stream: stdout           # stdout | stderr | either
    must_match: true         # false = negative pattern
  - type: file_exists
    path: ./report.md
    retryable: false         # permanent failure: fail fast, no retry
```

Per-validator options: `name`, `severity` (`error` default, `warn` never
fails the run), `retryable` (`true` default).

Exit codes: 0 ok, 1 validation failed / retries exhausted, 2 config error.
