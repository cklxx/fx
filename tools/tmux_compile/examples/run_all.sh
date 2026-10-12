#!/usr/bin/env bash
# Run all tmux_compile stories. Exit nonzero on any failure.
# (The asock driver integration test lives in agent-sock, it needs agent_sock.)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
for t in bug-hunt pr-review parallel-dev deploy-healthcheck retry-until-ready conditional-setup; do
  if bash "$HERE/$t/run.sh"; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "========================================"
echo "stories PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
