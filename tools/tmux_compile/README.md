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
- `examples/` — three end-to-end stories on real git repos: bug-hunt, pr-review, parallel-dev
- `docs/` — analysis, acceptance criteria, user guide (`TMUX_COMPILE_GUIDE.md`)
- `demo.sh` — two-minute demo

## Quick start

```bash
cd tools/tmux_compile
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"
python3 -m tmux_compile examples/bug-hunt/dsl.yaml -o /tmp/flow.sh
bash tests/test_tmux_compile.sh   # 35/35 expected
bash examples/run_all.sh          # 3 stories expected
```

See `docs/TMUX_COMPILE_GUIDE.md` for the YAML reference, product contract, and honest limitations.
