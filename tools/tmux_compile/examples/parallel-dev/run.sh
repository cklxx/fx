#!/usr/bin/env bash
# e2e for story 2: clean run (merge ok) + conflict run (honest stop).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
WORK=/tmp/tc-stories/parallel-dev

_run_once() { # $1 = conflict flag, $2 = expect: ok|conflict
  local conflict="$1" expect="$2"
  bash "$HERE/setup.sh" >/dev/null || { echo "FAIL parallel-dev: setup"; return 1; }
  export TSOCK="pd-$$-$conflict"
  tmux -L "$TSOCK" kill-server 2>/dev/null
  tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
  sleep 1
  local PANE
  PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')
  python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" \
    --param feature=feat1 --param repo="$WORK/repo" --param helpers="$HERE" \
    --param conflict="$conflict" \
    || { echo "FAIL parallel-dev: compile"; tmux -L "$TSOCK" kill-server 2>/dev/null; return 1; }
  local out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/product.sh" 2>"$WORK/err-$conflict.log"); rc=$?
  tmux -L "$TSOCK" kill-server 2>/dev/null
  if [ "$expect" = ok ]; then
    [ "$rc" -eq 0 ] || { echo "FAIL parallel-dev(clean): rc=$rc"; cat "$WORK/err-$conflict.log"; return 1; }
    echo "$out" | tail -1 | grep -q "COMPILE-OK" || { echo "FAIL parallel-dev(clean): no OK"; return 1; }
    git -C "$WORK/repo" checkout -q feat1
    ( cd "$WORK/repo" && ./run-tests.sh ) | grep -q TESTS_PASS || { echo "FAIL parallel-dev(clean): tests"; return 1; }
    echo "PASS parallel-dev(clean): merged, TESTS_PASS, $(echo "$out" | tail -1)"
  else
    [ "$rc" -eq 13 ] || { echo "FAIL parallel-dev(conflict): rc=$rc want 13"; cat "$WORK/err-$conflict.log"; return 1; }
    grep -q "merge-conflict-needs-human" "$WORK/err-$conflict.log" \
      || { echo "FAIL parallel-dev(conflict): reason missing"; return 1; }
    # repo must be left clean (merge aborted), no auto-resolution
    git -C "$WORK/repo" status --short | grep -q "^UU" \
      && { echo "FAIL parallel-dev(conflict): conflict markers left"; return 1; }
    echo "PASS parallel-dev(conflict): honest stop rc=13, repo clean"
  fi
}

_run_once 0 ok && _run_once 1 conflict
