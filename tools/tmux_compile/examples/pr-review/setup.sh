#!/usr/bin/env bash
# Real git repo + PR branch with a planted hardcoded secret.
# review.sh / fix.sh are deterministic stand-ins for `agent review` /
# `agent fix` (the orchestration under test is real: worktrees, parallel
# panes, artifact files, conditional fix).
set -euo pipefail

WORK=/tmp/tc-stories/pr-review
rm -rf "$WORK" /tmp/rev-sec /tmp/rev-api /tmp/rev-test /tmp/findings-*.md /tmp/review-final.md
mkdir -p "$WORK"
cd "$WORK"
git init -qb main repo
cd repo
git config user.email "test@example.com"
git config user.name "tc-test"
git config commit.gpgsign false

mkdir -p src
cat > src/app.py <<'EOF'
def hello():
    return "hello"
EOF
cat > src/config.py <<'EOF'
API_KEY = "env:API_KEY"  # read from env, good practice
EOF
git add -A && git commit -qm "init: service"

git checkout -qb pr-123
cat > src/app.py <<'EOF'
def hello():
    return "hello v2"

def new_feature():
    return 42
EOF
cat > src/config.py <<'EOF'
API_KEY = "env:API_KEY"
SECRET_TOKEN = "CRITICAL: hardcoded secret sk-live-abc123"
EOF
git add -A && git commit -qm "feat: v2"
git checkout -q main
echo "repo ready: pr-123 has $(git rev-list --count pr-123) commits"
