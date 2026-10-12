#!/usr/bin/env bash
# e2e for D1: blue-green deploy with health gate. Tests both paths:
#   ok     -> green becomes healthy -> traffic flips to green
#   broken -> green never healthy -> retry exhausts -> fail, blue still serves
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
WORK=/tmp/tc-stories/deploy-healthcheck

run_case() {
  local mode="$1" expect="$2"
  bash "$HERE/setup.sh" > /dev/null || { echo "FAIL deploy-healthcheck($mode): setup"; return 1; }

  export TSOCK="dh-$$-$mode"
  tmux -L "$TSOCK" kill-server 2>/dev/null
  tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
  sleep 1
  export PANE
  PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')

  python3 -m tmux_compile "$HERE/dsl.yaml" -o "$WORK/product.sh" \
    --param work="$WORK" --param color=green --param mode="$mode" \
    || { echo "FAIL deploy-healthcheck($mode): compile"; tmux -L "$TSOCK" kill-server 2>/dev/null; return 1; }

  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/product.sh" 2>"$WORK/err.log"); rc=$?
  tmux -L "$TSOCK" kill-server 2>/dev/null

  if [ "$expect" = ok ]; then
    [ "$rc" -eq 0 ] || { echo "FAIL deploy-healthcheck($mode): rc=$rc"; cat "$WORK/err.log"; return 1; }
    echo "$out" | tail -1 | grep -q "COMPILE-OK" || { echo "FAIL deploy-healthcheck($mode): no COMPILE-OK"; return 1; }
    [ "$(cat "$WORK/current.txt")" = green ] || { echo "FAIL deploy-healthcheck($mode): traffic not flipped"; return 1; }
    echo "PASS deploy-healthcheck($mode): flipped to green, $(echo "$out" | tail -1)"
  else
    [ "$rc" -ne 0 ] || { echo "FAIL deploy-healthcheck($mode): expected failure, got rc=0"; return 1; }
    grep -q "COMPILE-FAIL" "$WORK/err.log" || { echo "FAIL deploy-healthcheck($mode): no COMPILE-FAIL"; return 1; }
    [ "$(cat "$WORK/current.txt")" = blue ] || { echo "FAIL deploy-healthcheck($mode): blue should still serve"; return 1; }
    echo "PASS deploy-healthcheck($mode): failed honestly, blue still serving"
  fi
}

run_case ok ok || exit 1
run_case broken fail || exit 1
