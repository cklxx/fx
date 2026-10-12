# 协议简化建议

> 依据: `tla/` 下 SeqAck / WorkQueue 两个模型的验证结果 (见 VERIFICATION.md)。
> 原则: 只砍**模型证明为非 load-bearing** 的机制; 砍完后已验证的性质保持成立。

## 结论先行

WorkQueue 的核心 (publish / deliver / ack / 超时重投 / 死信 / rebalance 回收)
约 10 个动作, 模型证明它是** sound 且不复杂的**。
复杂度集中在三处, 建议按 S1 > S2 > S3 顺序砍:

| # | 砍什么 | 依据 | 预计减少 |
|---|--------|------|---------|
| S1 | `partition_key` + sticky 分配 + rebalance 重分配 | P5/P6 只在 `clean` (无失败/无rebalance) 时成立 —— 保证最弱时机制最复杂; task.dispatch 不需要跨任务保序 | assign 表、TargetOf sticky 分支、clean 跟踪、AEVT-4004、§3.5.2 顺序保证节 |
| S2 | max_deliver 检查散落三处 → 单个 `requeue_or_dead(m)` 原语 | Issue #1/#2 同一根因: 超时/nack/Leave 三条重入路径各写一遍, 漏了两处 | 消灭整类 bug |
| S3 | `queue.nack` 独立消息类型 → 定义为"消费者触发的提前 Timeout" | 修复后的模型里 Nack 与 Timeout 是**字面相同的状态转移** | 少一种消息类型, 少一条代码路径 |
| S4 | `overflow` 三策略砍到两种 (`block` + `drop_oldest`), 去掉 `drop_newest` | 未建模, 判断: 静默丢弃刚 publish 的任务几乎永远不是想要的语义 | 少一种策略及客户端处理分支 |

## S1 详解: 干掉 sticky partition (收益最大)

模型中的 `KeyOrderPreserved` / `KeySticky` 是**条件不变式**:
`clean[k] ⇒ (保序 ∧ 粘性)`, 其中 `clean[k]` 在 Leave/Timeout/Nack 任一发生时即为假。
也就是说: 只要发生任何值得注意的事 (失败、重投、成员变化),
顺序保证就已失效 —— 而设计文档自己也承认"重分配期间 key 内可能短暂乱序"。

代价侧: assign 表、rebalance 时的 before/after 分配表、
`TargetOf` 的 sticky 分支与 fallback、Leave 时的 clean 失效标记、
`AEVT-4004` 错误码、§3.5.2 整节"顺序保证"。

 task.dispatch 的真实需求是"同一任务恰被一个 agent 领走" (P1+P2, 已验证),
 不是"同一 key 的任务按序被同一 agent 处理"。
**建议**: 从 `queue.publish` 删除 `partition_key`;
 rebalance 简化为"离场成员的 in-flight 回 queued 池" (3 行);
 保留单线程 FIFO 投递 (免费保序)。
 若将来真有保序需求, 作为独立 feature 重新引入, 不做默认旋钮。

## S2 详解: `requeue_or_dead(m)` (bug 修复, 非可选)

Issue #1/#2 证明: "重入队列时检查 max_deliver"这个规则,
 在三个动作 (Timeout / Nack / Leave) 里必须**同时**成立, 漏一处即活锁。
 不要靠文档提醒三处各写一遍 —— 抽成单个原语:

```
requeue_or_dead(m):
    if pendCount[m] >= MaxDeliver: state[m] := "dead"; 发 queue.dead + *.failed
    else: state[m] := "queued"
```

Timeout / Nack / Leave 都调它。模型已验证此结构下 P3
(DeadOnlyAfterMaxDeliver) 与活性成立。

## S3 详解: nack = 提前的 timeout

修复后模型中 `Nack(c,m)` 与 `Timeout(m)` 的转移函数完全相同
(都是 `requeue_or_dead(m)` + `clean` 失效)。
保留"消费者要求立即重投"的能力, 但**删除独立的消息类型与独立的spec小节**,
 定义为: `queue.nack ≡ 消费者请求的提前 Timeout`。
 少一种 wire 消息, 少一条服务端代码路径, 语义零损失。

## S4 详解: overflow 策略做减法

`block` (默认) + `drop_oldest` (telemetry 类队列) 足够。
`drop_newest` = "你刚发来的任务我直接扔了" —— 调用方几乎无法正确处理
(它以为发出去了)。砍掉, 客户端少一个分支。

## 明确不砍的 (模型证明为承重墙)

- **累计 ack + 捎带**: SeqAck 的 AckSound 证明其可靠; 开销只是一个属性。
- **pending 表 (PEL)**: P1 (无孤儿 in-flight) 全靠它。*落盘频率*可以优化
  (模型不要求每次投递 fsync, 那是 crash 恢复的强度选择, 非协议正确性),
  但表本身不能砍。
- **message_id 去重**: P2 (at-most-once effect) 全靠消费者侧去重;
  at-least-once 投递下没有它就没有 exactly-once 效果。
- **topic/workqueue 双语义**: topic 是 workqueue 的简化版 (无 per-group 状态),
  选择指南"通知走 topic, 分活走 queue, 点名走 direct"清晰, 不砍。
- **rebalance 非 stop-the-world**: 模型验证了投递不暂停是安全的, 这是优点, 保留。

## 术语统一 (减概念不减机制)

设计中有三处"去重/幂等": 传输层 seq 去重、task.submit 的 `idempotency_key`、
queue.publish 的 `message_id`。模型证明它们是**同一模式在不同层**。
建议统一叫"幂等键", 文档中只讲一次模式, 三处引用它。

## 简化后的 §3.5 动作清单 (对照)

| 保留 | 删除/合并 |
|------|-----------|
| Publish / Deliver(FIFO) / Ack / Timeout / requeue_or_dead / Join / Leave(回收) / Rebalance(仅回收) / DeadLetter | partition_key、assign 表、TargetOf sticky、queue.nack 独立类型、overflow=drop_newest |

简化后模型可直接从现有 WorkQueue.tla 删减得到
(删 TargetOf sticky 分支、删 Nack 动作、assign 恒空), 性质 P1–P4 与活性保持成立。
