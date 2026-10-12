#!/usr/bin/env bash
# Deterministic stand-in for `agent fix --input review-final.md`.
# Removes the planted secret and commits. Must run on the pr-123 branch.
set -euo pipefail
sed -i '/CRITICAL: hardcoded secret/d' src/config.py
git add -A && git commit -qm "fix: remove hardcoded secret"
echo "FIX_COMMITTED $(git rev-parse --short HEAD)"
