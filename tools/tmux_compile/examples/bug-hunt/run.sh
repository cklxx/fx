#!/usr/bin/env bash
# e2e for story 3: setup -> compile -> run -> assert. All real, no mocks.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
WORK=/tmp/tc-stories/bug-hunt

bash "$HERE/setup.sh" || { echo "FAIL bug-hunt: setup"; exit 1; }

export TSOCK="bh-$$"
tmux -L "$TSOCK" kill-server 2>/dev/null
tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
sleep 1
export PANE
PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')

python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" \
  --param repo="$WORK/repo" || { echo "FAIL bug-hunt: compile"; tmux -L "$TSOCK" kill-server 2>/dev/null; exit 1; }

out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/product.sh" 2>"$WORK/err.log"); rc=$?
tmux -L "$TSOCK" kill-server 2>/dev/null

[ "$rc" -eq 0 ] || { echo "FAIL bug-hunt: product rc=$rc"; cat "$WORK/err.log"; exit 1; }
echo "$out" | tail -1 | grep -q "COMPILE-OK" || { echo "FAIL bug-hunt: no COMPILE-OK: $out"; exit 1; }
# the app must actually be fixed
grep -q "STATUS_OK" "$WORK/repo/app.sh" || { echo "FAIL bug-hunt: app.sh not fixed"; exit 1; }
# bisect must have found the true culprit (commit 8)
expected=$(cat "$WORK/expected-culprit.txt")
found=$(cat /tmp/bh-culprit.txt)
[ "$expected" = "$found" ] || { echo "FAIL bug-hunt: culprit $found != expected $expected"; exit 1; }
echo "PASS bug-hunt: culprit=$found fixed, $(echo "$out" | tail -1)"
