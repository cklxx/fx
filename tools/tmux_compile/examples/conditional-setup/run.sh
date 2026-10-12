#!/usr/bin/env bash
# e2e for T2: pipeline-server + redis-cache get monitors, search-api is skipped.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
WORK=/tmp/tc-stories/conditional-setup

bash "$HERE/setup.sh" > /dev/null || { echo "FAIL conditional-setup: setup"; exit 1; }

export TSOCK="cs-$$"
tmux -L "$TSOCK" kill-server 2>/dev/null
tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
sleep 1
export PANE
PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')

python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" --param work="$WORK" \
  || { echo "FAIL conditional-setup: compile"; tmux -L "$TSOCK" kill-server 2>/dev/null; exit 1; }

out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/product.sh" 2>"$WORK/err.log"); rc=$?
tmux -L "$TSOCK" kill-server 2>/dev/null

[ "$rc" -eq 0 ] || { echo "FAIL conditional-setup: rc=$rc"; cat "$WORK/err.log"; exit 1; }
echo "$out" | tail -1 | grep -q "COMPILE-OK" || { echo "FAIL conditional-setup: no COMPILE-OK"; exit 1; }
# side effects via attached.log (pane output is not in $out)
grep -qx "pipeline-server" "$WORK/attached.log" || { echo "FAIL: pipeline-server not monitored"; exit 1; }
grep -qx "redis-cache" "$WORK/attached.log" || { echo "FAIL: redis-cache not monitored"; exit 1; }
grep -qx "search-api" "$WORK/attached.log" && { echo "FAIL: search-api must NOT be monitored"; exit 1; }
[ "$(wc -l < "$WORK/attached.log")" -eq 2 ] || { echo "FAIL: expected exactly 2 monitors"; exit 1; }
echo "PASS conditional-setup: 2 attached, 1 skipped, $(echo "$out" | tail -1)"
