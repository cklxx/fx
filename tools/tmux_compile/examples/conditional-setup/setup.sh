#!/usr/bin/env bash
# Fake service discovery: services.txt simulates `ps` output.
# monitor.sh simulates attaching a log watcher for a running service.
set -euo pipefail

WORK=/tmp/tc-stories/conditional-setup
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# fake `ps` output: pipeline-server and cache are "running", search-api is not
cat > services.txt <<'EOF'
  101 ttys000    0:01.11 /usr/bin/pipeline-server --port 9000
  202 ttys001    0:00.42 /usr/bin/redis-cache --daemonize no
  303 ttys002    0:00.03 /usr/bin/sshd -D
EOF

cat > monitor.sh <<'EOF'
#!/usr/bin/env bash
# usage: monitor.sh <svc> -- attach a fake log watcher; records to attached.log
svc="${1:?svc}"
echo "$svc" >> /tmp/tc-stories/conditional-setup/attached.log
echo "MONITOR_ATTACHED $svc"
EOF
chmod +x monitor.sh
rm -f attached.log

echo "setup ready: $WORK (running: pipeline-server, redis-cache)"
