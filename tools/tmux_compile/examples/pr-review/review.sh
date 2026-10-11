#!/usr/bin/env bash
# Deterministic stand-in for `agent review --focus X --output findings`.
# Real reviewers are LLMs; the orchestration (parallel panes, artifact
# waiting, aggregation) is what this story exercises.
set -uo pipefail
focus="${1:?usage: review.sh <security|api|tests>}"
case "$focus" in
  security)
    echo "# security findings"
    if grep -rn "CRITICAL" src/ 2>/dev/null; then
      echo "verdict: CHANGES_REQUESTED"
    else
      echo "verdict: APPROVED"
    fi
    ;;
  api)
    echo "# api findings"
    grep -rh "^def " src/*.py 2>/dev/null | sed 's/^/API: /' || true
    echo "verdict: APPROVED"
    ;;
  tests)
    echo "# test findings"
    ls src/test*.py 2>/dev/null || echo "NOTE: no test files in src/"
    echo "verdict: APPROVED"
    ;;
  *)
    echo "unknown focus: $focus" >&2; exit 2;;
esac
echo "REVIEW_DONE $focus"
