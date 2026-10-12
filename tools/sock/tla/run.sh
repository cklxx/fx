#!/bin/bash
# 一键复跑全部 TLA+ 验证。要求: java 在 PATH 中。tla2tools.jar 已随附。
set -e
cd "$(dirname "$0")"
JAR=tla2tools.jar
run() {
  echo "=== $1 ==="
  java -cp "$JAR" tlc2.TLC -workers 4 -config "$2" "$3" 2>&1 \
    | grep -E "Model checking completed|Invariant.*violated|Temporal property.*violated|Error:|states generated.*distinct|Finished in" \
    | grep -v "^Parsing\|^Semantic"
  echo
}
run "SeqAck 安全 (3消息/丢包4)"      SeqAck.cfg      SeqAck.tla
run "SeqAck 活性 (2消息/丢包2)"      SeqAckLive.cfg  SeqAck.tla
run "WorkQueue 安全"                 WorkQueue.cfg   WorkQueue.tla
run "WorkQueue 活性 (假设A1)"        WorkQueueLive.cfg WorkQueue.tla
run "ReqReply 安全 (R-01 in_reply_to)" ReqReply.cfg   ReqReply.tla
