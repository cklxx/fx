#!/bin/bash
# fx-worker.sh: consume tasks from agent-sock queue, execute via `fx ask`, ack.
#
# env:
#   ASOCK_PATH   unix socket path (default .agent-sock/agent.sock)
#   ASOCK_CLI    path to asock-cli binary
#   FX_BIN       path to fx binary
#   FX_HOME      isolated HOME for fx (settings with sim provider)
#   WORKER_ID    worker identity for logs
#   QUEUE        queue name (default task.dispatch)
#   GROUP        consumer group (default workers)
#   MAX_TASKS    stop after N tasks (0 = infinite)

set -u
ASOCK_CLI="${ASOCK_CLI:?set ASOCK_CLI}"
FX_BIN="${FX_BIN:?set FX_BIN}"
FX_HOME="${FX_HOME:?set FX_HOME}"
WORKER_ID="${WORKER_ID:-worker-$$}"
QUEUE="${QUEUE:-task.dispatch}"
GROUP="${GROUP:-workers}"
MAX_TASKS="${MAX_TASKS:-0}"

log() { echo "[${WORKER_ID}] $*" >&2; }

# payload format: JSON {"prompt": "...", "workdir": "...", "task_id": "..."}
# we extract fields with python3 (available on the box)

count=0
while true; do
    if [ "$MAX_TASKS" -gt 0 ] && [ "$count" -ge "$MAX_TASKS" ]; then
        log "reached MAX_TASKS=$MAX_TASKS, exiting"
        break
    fi

    # blocking consume (30s poll window per call; loop forever)
    out="$("$ASOCK_CLI" consume "$QUEUE" "$GROUP" --timeout-s 30 2>/dev/null)"
    rc=$?
    if [ $rc -eq 2 ]; then
        continue  # timeout, no task yet
    fi
    if [ $rc -ne 0 ] || [ -z "$out" ]; then
        log "consume failed rc=$rc, retrying in 1s"
        sleep 1
        continue
    fi

    dlv_id="${out%%$'\t'*}"
    payload="${out#*$'\t'}"
    log "got delivery_id=$dlv_id"

    # parse payload JSON
    task_info="$(printf '%s' "$payload" | python3 -c "
import json,sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('task_id','unknown'))
    print(d.get('prompt',''))
    print(d.get('workdir',''))
except Exception as e:
    print('parse-error'); print(''); print('')
")"
    task_id="$(printf '%s' "$task_info" | sed -n '1p')"
    prompt="$(printf '%s' "$task_info" | sed -n '2p')"
    workdir="$(printf '%s' "$task_info" | sed -n '3p')"

    if [ "$task_id" = "parse-error" ] || [ -z "$prompt" ]; then
        log "bad payload, acking to drop: $dlv_id"
        "$ASOCK_CLI" ack "$QUEUE" "$GROUP" "$dlv_id" >/dev/null 2>&1
        continue
    fi
    if [ -z "$workdir" ]; then workdir="$PWD"; fi
    mkdir -p "$workdir"

    log "executing task_id=$task_id in $workdir"
    # run fx ask from the workdir so relative tool paths land correctly.
    # --json gives structured output.
    # FX_PROVIDER/FX_MODEL force the sim provider (settings.json has it as default too).
    if (cd "$workdir" && HOME="$FX_HOME" FX_PROVIDER="sim" FX_MODEL="sim-model" NO_COLOR=1 \
        "$FX_BIN" ask --auto --json --no-save --timeout 120 "$prompt" \
        > "$workdir/.fx-out-$task_id.json" 2>"$workdir/.fx-err-$task_id.log"); then
        log "task_id=$task_id OK"
    else
        log "task_id=$task_id fx exit=$? (acking anyway; task done-attempted)"
    fi

    "$ASOCK_CLI" ack "$QUEUE" "$GROUP" "$dlv_id" >/dev/null 2>&1
    log "acked $dlv_id"
    count=$((count + 1))
done
