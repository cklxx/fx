#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
WORK=/tmp/tc-stories/trace-branch

D="$(bash "$HERE/setup.sh" "$WORK/workdir")" || { echo "FAIL trace-branch-deploy: setup"; exit 1; }

export TSOCK="tctb-$$"
tmux -L "$TSOCK" kill-server 2>/dev/null
tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
sleep 1
export PANE
PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')

python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" \
  --param workdir="$D" || { echo "FAIL trace-branch-deploy: compile"; tmux -L "$TSOCK" kill-server 2>/dev/null; exit 1; }

TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/product.sh"
rc=$?
tmux -L "$TSOCK" kill-server 2>/dev/null
[ $rc -eq 0 ] && echo "PASS trace-branch-deploy" || { echo "FAIL trace-branch-deploy: rc=$rc"; exit 1; }
