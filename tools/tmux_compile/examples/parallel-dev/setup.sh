#!/usr/bin/env bash
# Real git repo for the parallel-dev story. implement.sh is a deterministic
# stand-in for `agent implement`; worktrees, parallel panes, merge and
# conflict detection are all real.
set -euo pipefail

WORK=/tmp/tc-stories/parallel-dev
rm -rf "$WORK" /tmp/dev-fe /tmp/dev-be /tmp/dev-it
mkdir -p "$WORK"
cd "$WORK"
git init -qb main repo
cd repo
git config user.email "test@example.com"
git config user.name "tc-test"
git config commit.gpgsign false

cat > README.md <<'EOF'
# demo service
line2
EOF
cat > run-tests.sh <<'EOF'
#!/usr/bin/env bash
set -u
test -f frontend/app.js || { echo "MISSING frontend"; exit 1; }
test -f backend/api.py || { echo "MISSING backend"; exit 1; }
test -f tests/test_it.py || { echo "MISSING tests"; exit 1; }
echo "TESTS_PASS"
EOF
chmod +x run-tests.sh
git add -A && git commit -qm "init: base"
echo "repo ready"
