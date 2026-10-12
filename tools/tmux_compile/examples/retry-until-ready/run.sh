#!/usr/bin/env bash
# e2e for D7: lag drains in ~5 attempts -> CUTOVER_DONE.
# Also covers the panic path via a variant DSL run (flag pre-created).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
WORK=/tmp/tc-stories/retry-until-ready

run_product() {
  export TSOCK="rr-$$-$1"
  tmux -L "$TSOCK" kill-server 2>/dev/null
  tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
  sleep 1
  export PANE
  PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/product.sh" 2>"$WORK/err.log"); rc=$?
  tmux -L "$TSOCK" kill-server 2>/dev/null
}

# path 1: normal drain
bash "$HERE/setup.sh" > /dev/null || { echo "FAIL retry-until-ready: setup"; exit 1; }
python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" --param work="$WORK" \
  || { echo "FAIL retry-until-ready: compile"; exit 1; }
run_product normal
[ "$rc" -eq 0 ] || { echo "FAIL retry-until-ready: rc=$rc"; cat "$WORK/err.log"; exit 1; }
grep -q "CUTOVER_DONE" "$WORK/cutover.log" || { echo "FAIL retry-until-ready: no cutover.log"; exit 1; }
echo "PASS retry-until-ready(normal): lag drained, $(echo "$out" | tail -1)"

# path 2: panic flag -> honest abort
bash "$HERE/setup.sh" > /dev/null
python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" --param work="$WORK" \
  || { echo "FAIL retry-until-ready(panic): compile"; exit 1; }
# migrate.sh removes the flag at start; re-create it mid-run via background touch
( sleep 2; touch "$WORK/panic.flag" ) &
run_product panic
[ "$rc" -ne 0 ] || { echo "FAIL retry-until-ready(panic): expected failure"; exit 1; }
grep -q "operator-panic" "$WORK/err.log" || { echo "FAIL retry-until-ready(panic): wrong reason"; cat "$WORK/err.log"; exit 1; }
echo "PASS retry-until-ready(panic): aborted on panic flag"
