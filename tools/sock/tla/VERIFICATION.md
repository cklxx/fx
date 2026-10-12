# TLA+ 形式化验证报告

> 工具: TLC 2026.10.06 (tla2tools.jar v1.8.0), OpenJDK 21
> 模型: `tla/SeqAck.tla`, `tla/WorkQueue.tla`, `tla/ReqReply.tla`
> 复跑: `cd tla && ./run.sh`

## v4 验证（2026-10-11，REVIEW.md R-01 / R-05 修复）

v4 相对 v3 的变更：

- **R-05（取消语义）**：`WorkQueue.tla` 加 `cancelled` 集合（server 侧 tombstone）与 `Cancel(m)` 动作。`queue.cancel(task_id)` 把 queued 任务记入 tombstone；`Deliver` 投递前检查 `m ∉ cancelled`，已取消的不投递。tombstone 持久：`Timeout`/`Leave` 重入后再次 `Deliver` 仍被过滤。新增安全性质 **P7 CancelledNeverDelivered**：`∀ m : m ∈ cancelled ⇒ state[m] ≠ "pending"`。
- **R-01（in_reply_to）**：新模型 `ReqReply.tla`。请求带客户端分配的单调 seq；server 应答带 `in_reply_to` = 原请求 seq。覆盖流水线（多请求在途）与乱序应答——正是 R-01 反例的场景（register seq=1、card seq=2，server 先回 card）。新增安全性质 **ReplyCorrelates**：每个应答的 `in_reply_to` 必对应一个已发送的请求 seq。

建模决策（诚实边界）：

- `Cancel` 只针对 queued 任务。在途（pending）任务已投递，取消是 no-op（worker 侧取消超出本模型范围）；acked/dead/absent 任务取消无意义。
- FIFO 取"queued 且未取消"中的最小 mid：tombstone 不占队头，否则已取消的队头会饿死其后的正常任务。
- 已取消的任务以 tombstone 为终态（保留在 queued，永不投递）。`Done` 将其计入终态；活性重述为"每条 publish 的消息最终 acked、死信，或被取消"：`(m ∈ published) ~> (state[m] ∈ {"acked","dead"} ∨ m ∈ cancelled)`——取消是合法终态，不是活性失败。

| # | 模型 | 性质 | 状态空间 | 结果 |
|---|------|------|---------|------|
| 1 | SeqAck | 安全：无幻影接收 / ack 可靠 / 副作用至多一次 / ack 连续 | 6,348,712 去重状态 | ✅ |
| 2 | SeqAck | 活性：有界丢包下每条消息最终送达且被 ack | 7,230 状态 | ✅ |
| 3 | WorkQueue v4 | 安全 P1–P4 + P7 | 24,300 状态（v3 为 14,310） | ✅ |
| 4 | WorkQueue v4 | 活性：每条消息最终 acked/死信/被取消（假设 A1） | 20,925 状态（v3 为 12,582） | ✅ |
| 5 | ReqReply | 安全 ReplyCorrelates（R-01 修复） | 15 状态 | ✅ |

结论：R-05 的 tombstone + 投递前过滤使 P7 成立；R-01 的 `in_reply_to` 使应答可关联到原请求 seq，流水线与乱序应答下依然成立。状态空间增长约 1.7 倍，无爆炸。

性质非空验证（反向对照，`/tmp` 一次性模型，未入库）：

- `ReqReplyBad`（server 用未发送的 seq 标注应答）：`ReplyCorrelates` 被违反 → 性质能抓住错配。
- `WorkQueueNoFilter`（`Deliver` 去掉 `m ∉ cancelled` 检查，即 R-05 未修复）：P7 被违反 → 性质能抓住"已取消仍投递"。

## v3 验证（2026-10-10，DESIGN.md v3）

v3 模型相对 v2.1 的删减：删 `Nack` 独立动作（S3，并入 Timeout）、删 `Rebalance` 动作与 `assign`/`clean`/`firstOrder`（S1）、加 `RequeueOrDead` 单个重入原语（S2，Timeout/Leave 共用）。P5/P6 随 partition_key 删除。P1–P4 不变。

| # | 模型 | 性质 | 状态空间 | 结果 |
|---|------|------|---------|------|
| 1 | SeqAck | 安全：无幻影接收 / ack 可靠 / 副作用至多一次 / ack 连续 | 6,348,712 去重状态 | ✅ |
| 2 | SeqAck | 活性：有界丢包下每条消息最终送达且被 ack | 7,230 状态 | ✅ |
| 3 | WorkQueue v3 | 安全 P1–P4 | 14,310 状态（v2.1 为 106,164） | ✅ |
| 4 | WorkQueue v3 | 活性：每条消息最终 acked/死信（假设 A1） | 12,582 状态（v2.1 为 46,746） | ✅ |

结论：S1–S4 删减后，P1–P4 与活性依然成立。状态空间缩小约 7 倍，模型即简化本身。

Issue #1/#2 的修复（`requeue_or_dead` 单原语）在 v3 模型中是结构性的：`Timeout` 与 `Leave` 都调用同一算子，不存在"漏一处"的可能。

---

## v2.1 验证记录（2026-10-10，DESIGN.md v2.1）

> 对象: `~/workspace/agent-sock/DESIGN.md` v2.1 §2 (协议) / §3.5 (队列语义)
> 日期: 2026-10-10

## 1. 建模范围 (有意缩小)

| 模型 | 覆盖的设计机制 | 未覆盖 (有意) |
|------|---------------|--------------|
| SeqAck | seq 分配 / 累计 ack / 丢包重传 / 接收方去重 / 幂等副作用 | XML 序列化细节、heartbeat lease、stream 续传 |
| WorkQueue | publish / workqueue 投递 / consumer group / ack 超时重投 / max_deliver 死信 / nack / rebalance / partition sticky | topic 广播、backpressure、retention/compaction、PEL 落盘频率 |

建模抽象:
- ack 超时建模为**非确定性动作** (pending 消息可随时超时): 这是对真实超时的**过近似** ——
  在此模型下成立的安全性质, 在真实定时器下同样成立。
- 网络丢包用**有界预算** (LOSS) 建模: 活性结论表述为"有界丢包 + 公平重传 ⇒ 收敛"。
  无界对抗性丢包下任何协议都无法保证活性, 这是诚实边界, 不是模型缺陷。

## 2. 验证结果总览

| # | 模型 | 性质 | 规模 | 结果 |
|---|------|------|------|------|
| 1 | SeqAck | 安全: 无幻影接收 / ack 可靠 / 副作用至多一次 / ack 连续 | 3 消息, 丢包预算 4; **6,348,712 去重状态** | ✅ 通过 |
| 2 | SeqAck | 活性: 每条消息最终被收到; 最终 unacked 为空 | 2 消息, 丢包预算 2; 7,230 状态 | ✅ 通过 |
| 3 | WorkQueue | 安全 P1–P6 (见 §3) | 3 消息, 2 消费者, MaxDeliver=2, 2 key; **106,164 状态** | ✅ 通过 (修模型后) |
| 4 | WorkQueue | 活性: 每条消息最终 acked/死信; rebalance 最终收敛 | 同上 + 假设 A1; 46,746 状态 | ✅ 通过 |

复跑: `cd tla && ./run.sh` (需 `java`; tla2tools.jar 已随附)。

## 3. WorkQueue 安全性质定义

- **P1 PendingHolderActive**: pending 消息的持有者必在线 (Leave 原子回收, 无孤儿 in-flight)。
- **P2 AtMostOnceEffect**: 同一消费者对同一消息的副作用至多执行一次
  (message_id 去重 ⇒ at-least-once 投递下的 exactly-once 效果)。
- **P3 DeadOnlyAfterMaxDeliver**: 死信只发生在投递次数打满 MaxDeliver 之后。
- **P4 NoPhantom**: queued/pending 的消息必已 publish。
- **P5 KeyOrderPreserved**: 未经历失败/rebalance 的 key, 首次投递保序 (FIFO)。
- **P6 KeySticky**: 未经历失败/rebalance 的 key, 首次投递落在同一消费者。

## 4. 发现的问题 (2 个, 同一根因)

### Issue #1: `queue.nack` 绕过 `max_deliver` —— 无限重投活锁

- **反例**: Deliver(count=1) → Nack → Deliver(count=2=MaxDeliver) → Nack → Deliver(count=3)
  → `pendCount` 超出 `0..MaxDeliver`, TypeOK 破坏; 现实中 = poison message 永不进死信。
- **根因**: 设计 §3.5.2 只在"ack 超时"路径描述了 max_deliver 检查,
  `queue.nack` ("立即重投") 被当成无害的快捷路径, 没计入投递次数。
- **模型修复**: Nack 与 Timeout 共享同一检查 —— `pendCount >= MaxDeliver` 则进死信。
- **设计修改要求**: DESIGN.md §3.5.2 必须明确 ——
  **所有重入队列的路径 (超时 / nack / rebalance 回收) 都执行 max_deliver 检查**。
  建议实现时抽成单个 `requeue_or_dead(m)` 原语, 而不是三处各写一遍。

### Issue #2: `Leave` 的 in-flight 回收绕过 `max_deliver`

- **反例**: Deliver(count=2=MaxDeliver) → Leave(持有者) → 消息回 queued (count=2)
  → Deliver(count=3) → 同上破坏。
- **根因**: 同 Issue #1。"rebalance 时 in-flight 先回池"没说明已打满投递次数的消息怎么办。
- **模型修复**: Leave 回收时同样检查, 打满则直接进死信。
- **设计修改要求**: 同上, 并入 `requeue_or_dead(m)`。

### 未发现问题的机制 (同样有价值)

- seq/ack 累计确认 + 丢包重传: 安全, 无幻影 ack。
- at-least-once + 接收方去重 ⇒ exactly-once 效果: 在两层 (传输层/消费层) 均成立。
- rebalance 非 stop-the-world (投递不暂停): 安全, P1 在 Leave 原子回收下成立。
- partition sticky + FIFO: 在 `clean` 前提下 (无失败/无 rebalance) 保序保粘性;
  设计中"重分配期间可能短暂乱序"的诚实声明与模型一致 —— 乱序只发生在
  `clean=false` 的 key 上, 模型用条件不变式精确刻画了这条边界。

## 5. 假设与边界

- **A1 (活性)**: consumer group 内始终至少有一个成员。
  反例轨迹 (无需运行, 由模型直接可得): Publish(m) → Leave(c1) → Leave(c2)
  → m 永久 queued。设计必须在文档中声明此假设, 或让 server 在成员归零时
  拒绝 publish / 告警 (建议后者: `queue.publish` 在空组时返回 AEVT-4005)。
- **A2 (活性)**: 丢包预算有界 + 重传/接收公平调度。这是标准假设, 见 §1。
- **A3**: 模型是单 queue、单 group。`queue.declare` 的多队列、topic 语义未建模
  (topic 是 workqueue 的简化版, 无 per-group 状态, 风险更低)。

## 6. 文件清单

```
tla/
  SeqAck.tla / SeqAck.cfg       安全运行 (NMSGS=3, LOSS=4)
  SeqAckLive.cfg                活性运行 (NMSGS=2, LOSS=2, SpecLive)
  WorkQueue.tla                 v4: 加 Cancel 动作 / cancelled tombstone / P7
  WorkQueue.cfg                 安全运行 (P1–P4 + P7)
  WorkQueueLive.cfg             活性运行 (CONSTRAINT NonEmptyMembers)
  ReqReply.tla / ReqReply.cfg   v4 新增: R-01 in_reply_to, ReplyCorrelates
  run.sh                        一键复跑
  tla2tools.jar                 TLC (v1.8.0)
```

注: TLC 对公平性合取的 DNF 转换有规模上限 —— SeqAck 的 6 条公平性合取
一次写会报 "exceeds the maximum supported size in disjunctive normal form"。
已拆分为 SpecSafe (无公平) / SpecLive (全公平) 分别验证, 见 `run.sh`。
这是 TLC 工具限制, 不是模型问题。
