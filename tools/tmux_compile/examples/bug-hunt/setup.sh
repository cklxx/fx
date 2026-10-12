#!/usr/bin/env bash
# Build a real git repo with a real planted bug for the bug-hunt story.
# 20 commits; the bug lands in commit 8 (HEAD~12). No mocks: repro, bisect,
# fix and verify are all real shell/git operations.
set -euo pipefail

WORK=/tmp/tc-stories/bug-hunt
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"
git init -qb main repo
cd repo
git config user.email "test@example.com"
git config user.name "tc-test"
git config commit.gpgsign false

cat > app.sh <<'EOF'
#!/usr/bin/env bash
# service entry: prints status
echo "STATUS_OK"
EOF
chmod +x app.sh

cat > test.sh <<'EOF'
#!/usr/bin/env bash
# test: fails if app reports a bug
out="$(./app.sh)"
case "$out" in
  *BUG*) echo "TEST_FAIL: $out"; exit 1;;
esac
echo "TEST_PASS"
EOF
chmod +x test.sh

cat > repro.sh <<'EOF'
#!/usr/bin/env bash
# reproducer: prints BUG_REPRODUCED iff the bug is present
out="$(./app.sh)"
case "$out" in
  *BUG*) echo "BUG_REPRODUCED: $out"; exit 0;;
esac
echo "NO_BUG: $out"
EOF
chmod +x repro.sh

git add -A && git commit -qm "init: service v1"

for i in 2 3 4 5 6 7; do
  echo "# change $i" >> changes.log
  git add -A && git commit -qm "chore: change $i"
done

# commit 8: THE BUG (HEAD~12)
cat > app.sh <<'EOF'
#!/usr/bin/env bash
# service entry: prints status
echo "STATUS_BUG badness=high"
EOF
chmod +x app.sh
git add -A && git commit -qm "feat: new status format"

for i in 9 10 11 12 13 14 15 16 17 18 19 20; do
  echo "# change $i" >> changes.log
  git add -A && git commit -qm "chore: change $i"
done

BUG_SHA=$(git log --format=%H -1 -- app.sh)
BUG_MSG=$(git log --format=%s -1 "$BUG_SHA")
echo "repo ready: $(git rev-list --count HEAD) commits, bug=$BUG_SHA ($BUG_MSG)"
echo "$BUG_SHA" > "$WORK/expected-culprit.txt"
