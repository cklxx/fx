#!/usr/bin/env bash
# e2e for story 1: setup -> compile -> run -> assert.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
WORK=/tmp/tc-stories/pr-review

bash "$HERE/setup.sh" || { echo "FAIL pr-review: setup"; exit 1; }

export TSOCK="pr-$$"
tmux -L "$TSOCK" kill-server 2>/dev/null
tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
sleep 1
export PANE
PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')

python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" \
  --param branch=pr-123 --param repo="$WORK/repo" --param helpers="$HERE" \
  || { echo "FAIL pr-review: compile"; tmux -L "$TSOCK" kill-server 2>/dev/null; exit 1; }

out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/product.sh" 2>"$WORK/err.log"); rc=$?
tmux -L "$TSOCK" kill-server 2>/dev/null

[ "$rc" -eq 0 ] || { echo "FAIL pr-review: product rc=$rc"; cat "$WORK/err.log"; exit 1; }
echo "$out" | tail -1 | grep -q "COMPILE-OK" || { echo "FAIL pr-review: no COMPILE-OK: $out"; exit 1; }
# the fix must have really landed on pr-123
git -C "$WORK/repo" log --oneline pr-123 | head -1 | grep -q "fix: remove hardcoded secret" \
  || { echo "FAIL pr-review: fix commit missing"; exit 1; }
git -C "$WORK/repo" checkout -q pr-123
grep -rq "CRITICAL: hardcoded secret" "$WORK/repo/src/" \
  && { echo "FAIL pr-review: secret still present"; exit 1; }
# all three findings artifacts must exist (parallel legs really ran)
for f in sec api test; do
  [ -s "/tmp/findings-$f.md" ] || { echo "FAIL pr-review: findings-$f.md missing"; exit 1; }
done
echo "PASS pr-review: 3 reviewers ran, CRITICAL fixed, $(echo "$out" | tail -1)"
