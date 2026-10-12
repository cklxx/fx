#!/bin/bash
set -e
D="${1:-/tmp/tc-trace-retry}"
mkdir -p "$D"
# build.sh fails twice (flaky), succeeds on 3rd try
cat > "$D/build.sh" <<'EOF'
#!/bin/bash
N_FILE="/tmp/tc-trace-retry-count"
N=$(cat "$N_FILE" 2>/dev/null || echo 0)
N=$((N+1)); echo "$N" > "$N_FILE"
if [ "$N" -lt 3 ]; then echo "build failed (attempt $N)" >&2; exit 1; fi
echo "build succeeded (attempt $N)"
EOF
chmod +x "$D/build.sh"
rm -f /tmp/tc-trace-retry-count
echo "$D"
