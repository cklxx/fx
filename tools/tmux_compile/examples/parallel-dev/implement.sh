#!/usr/bin/env bash
# Deterministic stand-in for `agent implement --spec ...`.
# Drops files into the given worktree and commits on its branch.
# conflict=1: fe and be both append to README.md -> real merge conflict.
set -euo pipefail
mod="${1:?usage: implement.sh <fe|be|it> <worktree> [conflict]}"
wt="${2:?worktree required}"
conflict="${3:-0}"
case "$mod" in
  fe)
    mkdir -p "$wt/frontend"
    echo "// frontend app" > "$wt/frontend/app.js"
    [ "$conflict" = 1 ] && echo "frontend was here" >> "$wt/README.md" || true
    git -C "$wt" add -A && git -C "$wt" commit -qm "fe: app"
    ;;
  be)
    mkdir -p "$wt/backend"
    echo "# backend api" > "$wt/backend/api.py"
    [ "$conflict" = 1 ] && echo "backend was here" >> "$wt/README.md" || true
    git -C "$wt" add -A && git -C "$wt" commit -qm "be: api"
    ;;
  it)
    mkdir -p "$wt/tests"
    echo "# integration tests" > "$wt/tests/test_it.py"
    git -C "$wt" add -A && git -C "$wt" commit -qm "it: tests"
    ;;
  *)
    echo "unknown module: $mod" >&2; exit 2;;
esac
echo "IMPLEMENT_DONE $mod"
