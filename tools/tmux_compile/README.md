# tmux_compile

Compile deterministic tmux interaction sequences (YAML) into readable, zero-dependency bash products. Part of the fx performance project.

## Project relationship

fx aims to be the fastest coding agent. The performance work has three parts:

- `benchmarks/agent-bench/` — measurement: simulated servers, task harness, E2E stage analysis
- src optimizations — P1 (confirm-round elimination), P2 (prefix caching), P3 (schema slimming)
- `tools/tmux_compile/` — compiled pipelines: the "LLM as compiler" idea from `benchmarks/agent-bench/PARADIGM_IDEAS.md`, idea 1. Deterministic multi-step tmux flows compile once and run without further LLM calls.

## Layout

- `tmux_compile/` — the compiler package (`python3 -m tmux_compile flow.yaml -o flow.sh`)
- `tests/` — acceptance suite (`test_tmux_compile.sh`, 35 tests) and soak test
- `examples/` — six end-to-end stories on real git repos: bug-hunt, pr-review, parallel-dev
- `docs/` — analysis, acceptance criteria, user guide (`TMUX_COMPILE_GUIDE.md`)
- `demo.sh` — two-minute demo

## Quick start

```bash
cd tools/tmux_compile
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"
python3 -m tmux_compile examples/bug-hunt/dsl.yaml -o /tmp/flow.sh
bash tests/test_tmux_compile.sh   # 35/35 expected
bash examples/run_all.sh          # 6 stories expected
```

## Performance

Compiled products eliminate per-step LLM round trips. Measured on 3 stories
(product-only wall time, clean tmux server):

| story | compiled (incl. one-time compile) | est. LLM-driven (pro profile) | speedup |
|-------|----------------------------------|------------------------------|---------|
| bug-hunt | 1.9s | 7.1s | **3.7×** |
| pr-review | 1.5s | 5.7s | **3.9×** |
| parallel-dev | 1.9s | 8.0s | **4.3×** |

LLM estimates are honest lower bounds (see `docs/PERFORMANCE.md` §1.2 for method
and limitations). Rule of thumb: slower model → bigger win (real flash models ~2.6–4.1×,
slow ~8-10×).

## User cases

`docs/USER_CASES.md`: 29 real scenarios from GitHub issues/PRs/README,
each with compilability verdict (13 fully / 12 partially / 4 not compilable).
The three most common out-of-scope lines: unbounded loops, human-in-the-loop
gates, failure rollback.

See `docs/TMUX_COMPILE_GUIDE.md` for the YAML reference, product contract, and honest limitations.
