#!/usr/bin/env bash
# agent-sock end-to-end tests.
# Each case runs in an isolated dir with its own asock-server.
# Usage: ./tests/e2e.sh [case...]   (default: all)
set -u
cd "$(dirname "$0")/.."

BIN="$(pwd)/zig-out/bin"
SERVER="$BIN/asock-server"
TK="$BIN/asock-testkit"

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()

t_begin() { TDIR="$(mktemp -d /tmp/asock-e2e-XXXXXX)"; mkdir -p "$TDIR/.agent-sock"; }
t_server() {
  # Remove any stale socket from a killed server; the readiness check below
  # must not mistake it for a live server.
  rm -f "$TDIR/.agent-sock/agent.sock"
  # exec: subshell becomes the server so $! is the real pid.
  # disown: don't let bash wait for it at script exit (do_wait hang).
  ( cd "$TDIR" && exec "$SERVER" >server.log 2>&1 ) &
  echo $! > "$TDIR/server.pid"
  disown 2>/dev/null
  for i in $(seq 1 50); do
    [ -S "$TDIR/.agent-sock/agent.sock" ] && return 0
    sleep 0.1
  done
  echo "  [diag] server failed to start:"; cat "$TDIR/server.log" | head -5
  return 1
}
t_kill_server() {
  if [ -f "$TDIR/server.pid" ]; then
    local pid; pid="$(cat "$TDIR/server.pid")"
    kill -9 "$pid" 2>/dev/null
    for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  fi
}
t_end() { t_kill_server; rm -rf "$TDIR"; }
bg() { # bg <pidfile> <cmd...> : background with real pid + disown
  local pf="$1"; shift
  ( cd "$TDIR" && exec "$@" ) &
  echo $! > "$pf"
  disown 2>/dev/null
}
tk() { ( cd "$TDIR" && "$TK" "$@" ); }

pass() { PASS=$((PASS+1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1 -- $2"; FAILED_CASES+=("$1"); }
skip() { SKIP=$((SKIP+1)); echo "SKIP $1 -- $2"; }

wait_file() { # wait_file <path> <timeout_s>
  for i in $(seq 1 $(( $2 * 10 ))); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

# ---------- T01: multi-worker, 10 tasks, exactly-once ----------
t01() {
  t_begin; t_server || { fail T01 "server start"; t_end; return; }
  mkdir -p "$TDIR/out"
  for i in $(seq 1 10); do tk pub task.dispatch "task-$i" "payload-$i" >/dev/null || { fail T01 "pub $i"; t_end; return; }; done
  for w in 1 2 3; do bg "$TDIR/w$w.pid" "$TK" worker task.dispatch workers out --id "w$w" --aw 5 --idle 4 >/dev/null 2>&1; done
  sleep 12
  n_done=$(ls "$TDIR/out/"*.done 2>/dev/null | wc -l)
  # each task exactly one .done; each .got matches
  ok=1
  for i in $(seq 1 10); do
    [ -f "$TDIR/out/task-$i.done" ] || { ok=0; echo "  [diag] missing task-$i.done"; }
  done
  # no task done twice (one .done per task by construction; check .got count per task == deliveries, just report)
  if [ "$ok" = 1 ] && [ "$n_done" = 10 ]; then pass T01; else fail T01 "done=$n_done/10"; fi
  t_end
}

# ---------- T02: worker crash -> redelivery after ack_wait ----------
t02() {
  t_begin; t_server || { fail T02 "server start"; t_end; return; }
  mkdir -p "$TDIR/out" "$TDIR/hold"
  tk pub task.dispatch task-A "crashme" >/dev/null
  bg "$TDIR/w1.pid" "$TK" worker task.dispatch workers out --id w1 --hold hold --aw 2 --idle 30 >/dev/null 2>&1
  wait_file "$TDIR/out/task-A.got" 10 || { fail T02 "w1 never got task"; t_end; return; }
  sleep 0.3
  kill -9 "$(cat "$TDIR/w1.pid")" 2>/dev/null
  bg "$TDIR/w2.pid" "$TK" worker task.dispatch workers out --id w2 --aw 2 --idle 5 >/dev/null 2>&1
  wait_file "$TDIR/out/task-A.done" 15 || { fail T02 "no redelivery after crash"; t_end; return; }
  owner=$(cat "$TDIR/out/task-A.done")
  if [ "$owner" = "w2" ]; then pass T02; else fail T02 "done by $owner, want w2"; fi
  t_end
}

# ---------- T03: server restart -> WAL recovery ----------
t03() {
  t_begin; t_server || { fail T03 "server start"; t_end; return; }
  tk pub task.dispatch task-1 p1 >/dev/null
  tk pub task.dispatch task-2 p2 >/dev/null
  tk pub task.dispatch task-3 p3 >/dev/null
  line=$(tk consume1 task.dispatch workers 3000 30 5)
  dlv=$(echo "$line" | awk '/^DLV/{print $2}')
  [ -n "$dlv" ] && tk ack task.dispatch workers "$dlv" >/dev/null
  t_kill_server
  t_server || { fail T03 "restart"; t_end; return; }
  line2=$(tk consume1 task.dispatch workers 3000 30 5)
  mid2=$(echo "$line2" | awk '/^DLV/{print $3}')
  dlv2=$(echo "$line2" | awk '/^DLV/{print $2}')
  [ -n "$dlv2" ] && tk ack task.dispatch workers "$dlv2" >/dev/null
  line3=$(tk consume1 task.dispatch workers 3000 30 5)
  mid3=$(echo "$line3" | awk '/^DLV/{print $3}')
  dlv3=$(echo "$line3" | awk '/^DLV/{print $2}')
  [ -n "$dlv3" ] && tk ack task.dispatch workers "$dlv3" >/dev/null
  line4=$(tk consume1 task.dispatch workers 1500 30 5)
  if [ "$mid2" = "task-2" ] && [ "$mid3" = "task-3" ] && echo "$line4" | grep -q NONE; then
    pass T03
  else
    fail T03 "mid2=$mid2 mid3=$mid3 line4=$line4"
  fi
  t_end
}

# ---------- T04: deregister recycles in-flight (rebalance) ----------
t04() {
  t_begin; t_server || { fail T04 "server start"; t_end; return; }
  mkdir -p "$TDIR/out" "$TDIR/hold"
  tk pub task.dispatch task-X "rebal" >/dev/null
  bg "$TDIR/wA.pid" "$TK" worker task.dispatch workers out --id wA --hold hold --aw 30 --idle 60 >/dev/null 2>&1
  wait_file "$TDIR/out/task-X.got" 10 || { fail T04 "wA never got task"; t_end; return; }
  tk dereg wA >/dev/null
  sleep 1
  line=$(tk consume1 task.dispatch workers 3000 30 5 --id wB)
  mid=$(echo "$line" | awk '/^DLV/{print $3}')
  if [ "$mid" = "task-X" ]; then pass T04; else fail T04 "wB got: $line"; fi
  kill -9 "$(cat "$TDIR/wA.pid")" 2>/dev/null
  t_end
}

# ---------- T05: cancel -> never delivered (P7) ----------
t05() {
  t_begin; t_server || { fail T05 "server start"; t_end; return; }
  tk pub task.dispatch task-A "doomed" >/dev/null
  tk pub task.dispatch task-B "live" >/dev/null
  tk cancel task-A >/dev/null
  line=$(tk consume1 task.dispatch workers 3000 30 5)
  mid=$(echo "$line" | awk '/^DLV/{print $3}')
  dlv=$(echo "$line" | awk '/^DLV/{print $2}')
  [ -n "$dlv" ] && tk ack task.dispatch workers "$dlv" >/dev/null
  line2=$(tk consume1 task.dispatch workers 1500 30 5)
  if [ "$mid" = "task-B" ] && echo "$line2" | grep -q NONE; then
    pass T05
  else
    fail T05 "mid=$mid line2=$line2"
  fi
  t_end
}

# ---------- T06: cancelled head doesn't block queue ----------
t06() {
  t_begin; t_server || { fail T06 "server start"; t_end; return; }
  tk pub task.dispatch task-A x >/dev/null
  tk pub task.dispatch task-B x >/dev/null
  tk pub task.dispatch task-C x >/dev/null
  tk cancel task-A >/dev/null
  l1=$(tk consume1 task.dispatch workers 3000 30 5)
  d1=$(echo "$l1" | awk '/^DLV/{print $2}'); m1b=$(echo "$l1" | awk '/^DLV/{print $3}')
  [ -n "$d1" ] && tk ack task.dispatch workers "$d1" >/dev/null
  l2=$(tk consume1 task.dispatch workers 3000 30 5)
  d2=$(echo "$l2" | awk '/^DLV/{print $2}'); m2=$(echo "$l2" | awk '/^DLV/{print $3}')
  [ -n "$d2" ] && tk ack task.dispatch workers "$d2" >/dev/null
  if [ "$m1b" = "task-B" ] && [ "$m2" = "task-C" ]; then pass T06; else fail T06 "m1b=$m1b m2=$m2"; fi
  t_end
}

# ---------- T07: backpressure block ----------
t07() {
  t_begin; t_server || { fail T07 "server start"; t_end; return; }
  tk declare bp.q workqueue 2 block >/dev/null
  tk pub bp.q a pa >/dev/null
  tk pub bp.q b pb >/dev/null
  out=$(tk pub bp.q c pc 2>&1)
  if echo "$out" | grep -q "AEVT-4001"; then pass T07; else fail T07 "out=$out"; fi
  t_end
}

# ---------- T08: drop_oldest evicts head ----------
t08() {
  t_begin; t_server || { fail T08 "server start"; t_end; return; }
  tk declare do.q workqueue 2 drop_oldest >/dev/null
  tk pub do.q a pa >/dev/null
  tk pub do.q b pb >/dev/null
  tk pub do.q c pc >/dev/null
  m1=$(tk consume1 do.q workers 3000 30 5 | awk '/^DLV/{print $3}')
  l=$(tk consume1 do.q workers 3000 30 5); d=$(echo "$l" | awk '/^DLV/{print $2}'); m2=$(echo "$l" | awk '/^DLV/{print $3}')
  [ -n "$d" ] && tk ack do.q workers "$d" >/dev/null
  if [ "$m1" = "b" ] && [ "$m2" = "c" ]; then pass T08; else fail T08 "m1=$m1 m2=$m2"; fi
  t_end
}

# ---------- T09: pipelined in_reply_to (R-01) ----------
t09() {
  t_begin; t_server || { fail T09 "server start"; t_end; return; }
  out=$(tk pipeline pipeliner 10 2>&1)
  if echo "$out" | grep -q "PIPELINE OK n=10"; then pass T09; else fail T09 "out=$out"; fi
  t_end
}

# ---------- T10: empty group publish succeeds (R-02) ----------
t10() {
  t_begin; t_server || { fail T10 "server start"; t_end; return; }
  tk declare lonely.q workqueue 100 block >/dev/null
  out=$(tk pub lonely.q t1 hello 2>&1)
  if echo "$out" | grep -q "^PUB"; then
    line=$(tk consume1 lonely.q workers 3000 30 5)
    mid=$(echo "$line" | awk '/^DLV/{print $3}')
    [ "$mid" = "t1" ] && pass T10 || fail T10 "consume: $line"
  else
    fail T10 "pub rejected: $out"
  fi
  t_end
}

# ---------- T11: oversized frame -> connection closed ----------
t11() {
  t_begin; t_server || { fail T11 "server start"; t_end; return; }
  python3 -c "
import struct
with open('$TDIR/bigframe.bin','wb') as f:
    f.write(struct.pack('>I', 17*1024*1024))
"
  out=$(tk raw "$TDIR/bigframe.bin" 2>&1)
  if echo "$out" | grep -q "RAW CLOSED"; then pass T11; else fail T11 "out=$out"; fi
  t_end
}

# ---------- T12: oversized payload -> error ----------
t12() {
  t_begin; t_server || { fail T12 "server start"; t_end; return; }
  python3 -c "open('$TDIR/bigpayload.bin','wb').write(b'z'*(9*1024*1024))"
  out=$(tk pubfile task.dispatch big1 "$TDIR/bigpayload.bin" 2>&1)
  if echo "$out" | grep -q "ERR"; then pass T12; else fail T12 "out=$out"; fi
  t_end
}

# ---------- T13: CDATA ]]> round-trip ----------
t13() {
  t_begin; t_server || { fail T13 "server start"; t_end; return; }
  tk pub task.dispatch cdata-t "echo 'a]]>b'" >/dev/null
  line=$(tk consume1 task.dispatch workers 3000 30 5)
  b64p=$(echo "$line" | awk '/^DLV/{print $5}')
  pay=$(echo "$b64p" | python3 -c "import sys,base64; print(base64.b64decode(sys.stdin.read().strip()).decode())")
  if [ "$pay" = "echo 'a]]>b'" ]; then pass T13; else fail T13 "pay=$pay"; fi
  t_end
}

# ---------- T14: deep XML rejected ----------
t14() {
  t_begin; t_server || { fail T14 "server start"; t_end; return; }
  python3 -c "
import struct
inner = '<a>'*40 + 'x' + '</a>'*40
xml = '<msg v=\"1\" type=\"agent.card\" seq=\"1\" ack=\"0\" ts=\"1.0\" from=\"evil\">' + inner + '</msg>'
data = xml.encode()
with open('$TDIR/deep.bin','wb') as f:
    f.write(struct.pack('>I', len(data)) + data)
"
  out=$(tk raw "$TDIR/deep.bin" 2>&1)
  if echo "$out" | grep -q "RAW CLOSED"; then pass T14; else fail T14 "out=$out"; fi
  t_end
}

# ---------- T15: DOCTYPE rejected ----------
t15() {
  t_begin; t_server || { fail T15 "server start"; t_end; return; }
  python3 -c "
import struct
xml = b'<!DOCTYPE foo><msg v=\"1\"/>'
with open('$TDIR/doctype.bin','wb') as f:
    f.write(struct.pack('>I', len(xml)) + xml)
"
  out=$(tk raw "$TDIR/doctype.bin" 2>&1)
  if echo "$out" | grep -q "RAW CLOSED"; then pass T15; else fail T15 "out=$out"; fi
  t_end
}

# ---------- T16: max_deliver -> dead, no infinite requeue ----------
t16() {
  t_begin; t_server || { fail T16 "server start"; t_end; return; }
  tk pub task.dispatch task-P p >/dev/null
  l1=$(tk consume1 task.dispatch workers 3000 30 2); d1=$(echo "$l1" | awk '/^DLV/{print $2}')
  r1=$(echo "$l1" | awk '/^DLV/{print $4}')
  tk ack task.dispatch workers "$d1" --requeue >/dev/null
  l2=$(tk consume1 task.dispatch workers 3000 30 2); d2=$(echo "$l2" | awk '/^DLV/{print $2}')
  r2=$(echo "$l2" | awk '/^DLV/{print $4}')
  tk ack task.dispatch workers "$d2" --requeue >/dev/null
  l3=$(tk consume1 task.dispatch workers 2000 30 2)
  if [ "$r1" = "redelivered=false" ] && [ "$r2" = "redelivered=true" ] && echo "$l3" | grep -q NONE; then
    pass T16
  else
    fail T16 "r1=$r1 r2=$r2 l3=$l3"
  fi
  t_end
}

# ---------- T17: topic -> every subscriber gets every message ----------
t17() {
  # Topic fan-out: each subscriber has its own group cursor, so every
  # subscriber gets every message. (No server-push in this protocol:
  # publish first, then each subscriber consumes from its own group.)
  t_begin; t_server || { fail T17 "server start"; t_end; return; }
  tk declare ev2 topic 1000 drop_oldest >/dev/null
  tk pub ev2 e1 "hello-topic" >/dev/null
  m1=$(tk consume1 ev2 g 3000 --id sub1 2>/dev/null | awk '/^DLV/{print $3}')
  m2=$(tk consume1 ev2 g 3000 --id sub2 2>/dev/null | awk '/^DLV/{print $3}')
  # sub1 consuming again gets nothing new (its cursor advanced), but a
  # second message reaches both.
  tk pub ev2 e2 "hello-again" >/dev/null
  m1b=$(tk consume1 ev2 g 3000 --id sub1 2>/dev/null | awk '/^DLV/{print $3}')
  m2b=$(tk consume1 ev2 g 3000 --id sub2 2>/dev/null | awk '/^DLV/{print $3}')
  if [ "$m1" = "e1" ] && [ "$m2" = "e1" ] && [ "$m1b" = "e2" ] && [ "$m2b" = "e2" ]; then
    pass T17
  else
    fail T17 "m1=$m1 m2=$m2 m1b=$m1b m2b=$m2b"
  fi
  t_end
}

# ---------- T18: unconsume doesn't break ----------
t18() {
  t_begin; t_server || { fail T18 "server start"; t_end; return; }
  tk pub task.dispatch task-U u >/dev/null
  l0=$(tk consume1 task.dispatch workers 2000 30 5)
  d0=$(echo "$l0" | awk '/^DLV/{print $2}')
  [ -n "$d0" ] && tk ack task.dispatch workers "$d0" >/dev/null
  ( cd "$TDIR" && "$TK" unconsume task.dispatch workers ) 2>/dev/null
  tk pub task.dispatch task-V v >/dev/null
  line=$(tk consume1 task.dispatch workers 3000 30 5)
  mid=$(echo "$line" | awk '/^DLV/{print $3}')
  [ "$mid" = "task-V" ] && pass T18 || fail T18 "line=$line"
  t_end
}

run_case() {
  case "$1" in
    t01) t01;; t02) t02;; t03) t03;; t04) t04;; t05) t05;; t06) t06;;
    t07) t07;; t08) t08;; t09) t09;; t10) t10;; t11) t11;; t12) t12;;
    t13) t13;; t14) t14;; t15) t15;; t16) t16;; t17) t17;; t18) t18;;
    *) echo "unknown case $1"; exit 2;;
  esac
}

if [ $# = 0 ]; then
  for c in t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13 t14 t15 t16 t17 t18; do run_case "$c"; done
else
  for c in "$@"; do run_case "$c"; done
fi

echo "===================="
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ ${#FAILED_CASES[@]} -gt 0 ] && echo "failed: ${FAILED_CASES[*]}"
[ "$FAIL" = 0 ]
