#!/usr/bin/env bash
# Fake gh-ost style migration: a "replication lag" that drains over time.
# lag.sh prints LAG=<n>, decrementing a counter file each call; LAG_OK at 0.
# panic flag file aborts the migration (operator kill-switch).
set -euo pipefail

WORK=/tmp/tc-stories/retry-until-ready
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

cat > lag.sh <<'EOF'
#!/usr/bin/env bash
# each call drains the lag by 2; prints LAG_OK when drained
f="/tmp/tc-stories/retry-until-ready/lag.counter"
n=$(cat "$f" 2>/dev/null || echo 10)
n=$(( n - 2 ))
[ "$n" -lt 0 ] && n=0
echo "$n" > "$f"
if [ "$n" -eq 0 ]; then echo "LAG_OK"; else echo "LAG=$n"; fi
EOF
chmod +x lag.sh

cat > migrate.sh <<'EOF'
#!/usr/bin/env bash
# starts the "migration": resets lag counter
echo 10 > /tmp/tc-stories/retry-until-ready/lag.counter
rm -f /tmp/tc-stories/retry-until-ready/panic.flag
echo "MIGRATION_STARTED"
EOF
chmod +x migrate.sh

echo "setup ready: $WORK"
