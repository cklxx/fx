#!/bin/bash
# demo-fx-integration.sh: end-to-end demo of fx workers via agent-sock.
#
# 1. starts asock-server (Zig)
# 2. starts sim-server (Zig) with scripted LLM responses
# 3. starts 2 fx-worker.sh in background
# 4. publishes 3 tasks via asock-cli
# 5. verifies: files created, tasks distributed, all acked
#
# All output goes to stdout with [demo] prefix; per-component logs in $DEMO_DIR/logs/.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIG_OUT="$SCRIPT_DIR/zig-out/bin"
FXROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FX_TOOLS="${FX_TOOLS:-$FXROOT/benchmarks/agent-bench/.tools}"
DEMO_DIR="${DEMO_DIR:-/tmp/fx-integration-demo}"

log() { echo "[demo] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ---------- setup ----------
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"/{logs,work,fxhome1,fxhome2}
cd "$DEMO_DIR" || die "cannot cd $DEMO_DIR"

export ASOCK_PATH="$DEMO_DIR/.agent-sock/agent.sock"
export ASOCK_CLI="$ZIG_OUT/asock-cli"
export FX_BIN="$FX_TOOLS/fx"
SIM_BIN="$FX_TOOLS/sim-server"

[ -x "$ASOCK_CLI" ] || die "asock-cli not found at $ASOCK_CLI (run zig build)"
[ -x "$FX_BIN" ] || die "fx not found at $FX_BIN"
[ -x "$SIM_BIN" ] || die "sim-server not found at $SIM_BIN"

# ---------- 1. asock-server ----------
log "starting asock-server..."
"$ZIG_OUT/asock-server" > logs/asock-server.log 2>&1 &
ASOCK_PID=$!
sleep 1
kill -0 $ASOCK_PID 2>/dev/null || die "asock-server died; see logs/asock-server.log"
log "asock-server pid=$ASOCK_PID"

# ---------- 2. sim-server ----------
log "starting sim-server..."
"$SIM_BIN" --profile flash --port 0 --script /tmp/fx-demo/scripts/combined.json > logs/sim-server.log 2>&1 &
SIM_PID=$!
sleep 1
# sim-server prints {"host":...,"port":N} on first stdout line
SIM_PORT="$(head -1 logs/sim-server.log | python3 -c "import json,sys; print(json.load(sys.stdin)['port'])" 2>/dev/null)"
[ -n "$SIM_PORT" ] || die "sim-server did not report port; see logs/sim-server.log"
log "sim-server pid=$SIM_PID port=$SIM_PORT"

# ---------- 3. fx homes (sim provider) ----------
make_fxhome() {
    local home="$1"
    mkdir -p "$home/.fx"
    chmod 700 "$home" "$home/.fx"
    cat > "$home/.fx/settings.json" <<EOF
{
  "providers": {
    "sim": {
      "protocol": "openai-chat-completions",
      "base_url": "http://127.0.0.1:$SIM_PORT/v1",
      "auth": {"type": "none"},
      "model_metadata": {
        "sim-model": {"context_window": 32768, "max_output_tokens": 2048, "supports_tool_use": true}
      }
    }
  },
  "provider": "sim",
  "models": {"sim": "sim-model"},
  "permission_mode": "auto",
  "permission": {"bash": "allow", "edit": "allow", "read": "allow"}
}
EOF
    chmod 600 "$home/.fx/settings.json"
}
make_fxhome "$DEMO_DIR/fxhome1"
make_fxhome "$DEMO_DIR/fxhome2"
log "fx homes ready"

# ---------- 4. declare queue ----------
"$ASOCK_CLI" declare task.dispatch 2>&1 | log
log "queue declared"

# ---------- 5. start workers ----------
log "starting 2 workers..."
ASOCK_CLI="$ASOCK_CLI" FX_BIN="$FX_BIN" WORKER_ID="worker-1" QUEUE="task.dispatch" GROUP="workers" \
    FX_HOME="$DEMO_DIR/fxhome1" MAX_TASKS=0 \
    bash "$SCRIPT_DIR/fx-worker.sh" > logs/worker-1.log 2>&1 &
W1_PID=$!
ASOCK_CLI="$ASOCK_CLI" FX_BIN="$FX_BIN" WORKER_ID="worker-2" QUEUE="task.dispatch" GROUP="workers" \
    FX_HOME="$DEMO_DIR/fxhome2" MAX_TASKS=0 \
    bash "$SCRIPT_DIR/fx-worker.sh" > logs/worker-2.log 2>&1 &
W2_PID=$!
sleep 1
log "workers started: $W1_PID $W2_PID"

# ---------- 6. publish 3 tasks ----------
log "publishing 3 tasks..."
for i in 1 2 3; do
    payload="$(python3 -c "
import json
print(json.dumps({'task_id': 'demo-task-$i', 'prompt': 'Create the demo files as instructed.', 'workdir': '$DEMO_DIR/work'}))
")"
    "$ASOCK_CLI" publish task.dispatch "demo-task-$i" "$payload" 2>&1 | log
done

# ---------- 7. wait for completion ----------
log "waiting for tasks to complete (max 90s)..."
deadline=$((SECONDS + 90))
while [ $SECONDS -lt $deadline ]; do
    done_count=0
    for i in 1 2 3; do
        [ -f "$DEMO_DIR/work/demo$i.txt" ] && done_count=$((done_count + 1))
    done
    if [ "$done_count" -eq 3 ]; then break; fi
    sleep 2
done

# ---------- 8. verify ----------
log "=== verification ==="
ok=1
for i in 1 2 3; do
    f="$DEMO_DIR/work/demo$i.txt"
    if [ -f "$f" ]; then
        log "OK demo$i.txt exists: $(cat "$f" | head -1)"
    else
        log "FAIL demo$i.txt missing"
        ok=0
    fi
done

log "--- worker task distribution ---"
grep -h "executing task_id" logs/worker-1.log logs/worker-2.log 2>/dev/null | log
log "worker-1 tasks: $(grep -c "executing task_id" logs/worker-1.log 2>/dev/null)"
log "worker-2 tasks: $(grep -c "executing task_id" logs/worker-2.log 2>/dev/null)"
log "total acks: $(grep -h -c "acked dlv-" logs/worker-1.log logs/worker-2.log 2>/dev/null | awk '{s+=$1} END {print s}')"

# ---------- cleanup ----------
log "stopping workers and servers..."
kill $W1_PID $W2_PID 2>/dev/null
kill $ASOCK_PID $SIM_PID 2>/dev/null
sleep 1

if [ $ok -eq 1 ]; then
    log "DEMO OK: all 3 tasks executed via agent-sock"
    exit 0
else
    log "DEMO FAIL: see logs in $DEMO_DIR/logs/"
    exit 1
fi
