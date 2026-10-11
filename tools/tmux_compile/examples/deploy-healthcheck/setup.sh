#!/usr/bin/env bash
# Fake blue-green deploy target: a "service" whose health flips after deploy.
# No real systemctl/nginx; health.sh + deploy.sh simulate the D1 case.
set -euo pipefail

WORK=/tmp/tc-stories/deploy-healthcheck
rm -rf "$WORK"
mkdir -p "$WORK"/{blue,green}
cd "$WORK"

# health.sh: prints HEALTHY iff the flag file for the asked color exists
cat > health.sh <<'EOF'
#!/usr/bin/env bash
# usage: health.sh <color>
color="${1:?color}"
if [ -f "/tmp/tc-stories/deploy-healthcheck/$color.healthy" ]; then
  echo "HEALTHY $color"
else
  echo "STARTING $color"
fi
EOF
chmod +x health.sh

# deploy.sh: simulate rolling out <color>: takes ~3s, then marks healthy.
# mode=broken never marks healthy (for the failure path).
cat > deploy.sh <<'EOF'
#!/usr/bin/env bash
# usage: deploy.sh <color> [broken]
color="${1:?color}"
mode="${2:-ok}"
rm -f "/tmp/tc-stories/deploy-healthcheck/$color.healthy"
sleep 3
if [ "$mode" = "ok" ]; then
  touch "/tmp/tc-stories/deploy-healthcheck/$color.healthy"
  echo "DEPLOYED $color"
else
  echo "DEPLOYED_BUT_BROKEN $color"
fi
EOF
chmod +x deploy.sh

# current.txt: which color currently serves traffic (blue at start)
echo "blue" > current.txt
touch blue.healthy

echo "setup ready: $WORK (serving blue)"
