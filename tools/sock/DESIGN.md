# Agent Sock — 设计文档 v4

> v4（2026-10-11）：REVIEW 25 项全量修复（R-01–R-25）；信封加 `in_reply_to`；server 单线程 asyncio；新增 `queue.unconsume`；原语 10→11。修订明细见 §10。
> v3（2026-10-10）：TLA+ 修复与 S1–S4 全量采纳；wire 原语 27→10；topic/queue/direct 统一为队列；协议章按 ASD-STE100 重写。
> v2.1→v3 的每处删减都在 §2.8 列出依据。TLA+ 模型同步简化并重验，见 `tla/VERIFICATION.md`。

---

## 0. 术语表

本文术语一词一义。下文只引用，不重复定义。

| 术语 | 定义 |
|------|------|
| 消息 | socket 上传输的一个 XML 帧 |
| 信封 | 消息的属性集合：`v/type/seq/ack/ts/from/in_reply_to` |
| 队列 | 命名的消息通道 |
| 主题 | 语义之一：每个订阅者收到全量消息 |
| 工作队列 | 语义之一：同一消费者组内恰一个消费者收到每条消息 |
| 消费者组 | 共同消费一个工作队列的消费者集合 |
| 投递 | server 把消息交给消费者的动作 |
| 确认 | 消费者通知 server"处理完毕"的动作 |
| 取消集合 | server 维护的已取消任务 id 集合。投递前过滤 |
| 幂等键 | 去重标识。同一幂等键的消息，副作用至多执行一次 |
| 重投 | 未确认的消息重新进入队列 |
| 死信 | 投递次数打满上限仍未确认的消息 |
| 背压 | 队列满时对生产者的反压 |
| 载荷 | 消息的业务数据（XML） |
| 载荷约定 | 特定队列上载荷的固定格式 |
| 收件箱 | 每个 agent 的私有工作队列，名为 `agent.<id>.inbox` |
| 原语 | wire 层 `type` 的取值。v4 共 11 个 |

---

## 1. 总览

| # | 模块 | 一句话 | 依赖 |
|---|------|--------|------|
| 1 | 协议 | Unix socket 上的 agent 通信：11 个原语 + 5 种载荷约定 | 无 |
| 2 | 队列 | 唯一的投递原语；主题与工作队列双语义 | 1 |
| 3 | Tmux | 每个 agent 独立会话；捕获/注键/快照/排布 | 2（事件上报） |
| 4 | 流水线烧录 | 多轮 action 序列编译成单轮可执行 bundle | 1、5 |
| 5 | 报错与恢复 | 统一错误码 + 自动分类 + checkpoint 断点续跑 | 被 1–4 依赖 |

设计原则：

1. **原语最少**：wire 层只有 11 个原语。发送只有 `queue.publish`，订阅只有 `queue.consume`。点对点 = 发往收件箱。
2. **零重依赖**：Python 标准库 + tmux CLI。无消息队列中间件。
3. **事件即事实**：状态变更先写事件（append-only JSONL），再更新内存。
4. **失败是常态**：跨进程操作必有超时、重试、降级路径。错误码全局唯一。

非目标：模型推理、prompt 工程、Web UI、网络 socket（只 Unix domain socket）。

---

## 2. 协议

### 2.1 传输

- 载体：Unix domain socket，`SOCK_STREAM`。默认 `~/.agent-sock/agent.sock`。
- 成帧：4 字节大端长度前缀 + UTF-8 XML。独立成帧，解决粘包。
- 帧上限：`max_frame_bytes` = 16MB。超限 server 断开连接并记事件。
- 载荷上限：`max_payload_bytes` = 8MB。`queue.publish` 超限回 `error`。
- CDATA 转义：发送方把载荷中的 `]]>` 转义为 `]]]]><![CDATA[>`。proto.py 负责，单元测试覆盖。
- 并发：server 单线程 asyncio 事件循环。dispatcher 即事件循环，不存在跨线程写。单连接全双工。
- 安全：socket 文件 `0600`；用 `SO_PEERCRED` 校验对端 uid。
- XML 安全：拒绝 DOCTYPE；最大嵌套深度 32；最大元素数 100000。超限断开连接并记事件。
- 平台：首版仅支持 Linux。

### 2.2 信封

```xml
<msg v="1" type="queue.publish" seq="61" ack="60" ts="1728500000.123" from="orchestrator">
```

| 属性 | 必需 | 说明 |
|------|------|------|
| `v` | 是 | 协议版本。server 拒绝不支持的版本 |
| `type` | 是 | 原语名（§2.3） |
| `seq` | 是 | 发送方单调递增序号 |
| `ack` | 是 | 捎带确认：已收到的对方最大 seq |
| `ts` | 是 | 发送方 epoch 秒 |
| `from` | 是 | 逻辑地址 |
| `in_reply_to` | 否 | 请求/应答关联：值为原请求 `seq`。应答必填，单向消息缺省 |

v3 删除 `to` 属性。寻址 = 队列名。点对点 = 发往对方收件箱。

`ack` 只做传输确认（捎带对方已收最大 seq），不做请求/应答关联。请求/应答关联只用 `in_reply_to`。

可靠性：at-least-once + 幂等键。`queue.publish` 的 `message_id` 即幂等键。server 去重，消费者去重（TLA+ P2）。

术语统一：传输层 seq 去重、任务幂等、队列 message_id 去重是同一模式。本节定义一次，各处引用"幂等键"。

### 2.3 原语（11 个）

每个原语：XML 结构 + 一句话语义 + 一行示例。

**agent.register** — 建立会话。请求携带能力表；应答（ack 关联）携带租约。

```xml
<msg v="1" type="agent.register" seq="1" ts="..." from="agent-7">
  <caps><cap>shell</cap></caps><pid>12345</pid><tmux>asock-agent-7</tmux><resume>false</resume></msg>
<msg v="1" type="agent.register" seq="9" in_reply_to="1" ack="1" ts="..." from="server">
  <lease_s>15</lease_s></msg>
```

规则：请求与应答同类型。`from=server` 且含 `lease_s` 者为应答。应答的 `in_reply_to` = 请求 `seq`。

**agent.heartbeat** — 报告存活。server 据此维护租约。

```xml
<msg v="1" type="agent.heartbeat" seq="2" ack="9" ts="..." from="agent-7">
  <load>0.4</load></msg>
```

**agent.deregister** — 优雅离开。server 原子回收其 in-flight 消息（TLA+ Leave，P1）。

```xml
<msg v="1" type="agent.deregister" seq="3" ts="..." from="agent-7">
  <reason>shutdown</reason></msg>
```

**agent.card** — 查询能力。空体为查询；含 `skills` 为应答（SOTA-A2A）。

```xml
<msg v="1" type="agent.card" seq="4" ts="..." from="orchestrator"><agent_id>agent-7</agent_id></msg>
<msg v="1" type="agent.card" seq="10" in_reply_to="4" ack="4" ts="..." from="server">
  <agent_id>agent-7</agent_id><skills><skill>shell.exec</skill></skills></msg>
```

**queue.declare** — 声明队列。未声明的队列拒绝 publish/consume（AEVT-4006）。

```xml
<msg v="1" type="queue.declare" seq="60" ts="..." from="orchestrator">
  <queue>task.dispatch</queue><semantics>workqueue</semantics>
  <max_depth>10000</max_depth><overflow>block</overflow></msg>
```

规则：约定队列（§2.4）由 server 启动时预声明。`semantics` 必填，无缺省。`overflow ∈ {block, drop_oldest}`（S4），必填，无缺省。重复 declare 参数一致则幂等成功；参数冲突回 AEVT-4007。

**queue.publish** — 发送消息。唯一的发送原语。

```xml
<msg v="1" type="queue.publish" seq="61" ts="..." from="orchestrator">
  <queue>task.dispatch</queue><message_id>uuid</message_id><payload><![CDATA[<task/>]]></payload></msg>
```

规则：`message_id` 必填，是幂等键。workqueue 空组 publish 正常入队；server 发 AEVT-4005 告警事件到 `events`，不阻塞 publish。

**queue.consume** — 订阅队列。唯一的订阅原语。

```xml
<msg v="1" type="queue.consume" seq="62" ts="..." from="agent-7">
  <queue>task.dispatch</queue><group>workers</group><ack_wait_s>30</ack_wait_s><max_deliver>5</max_deliver></msg>
<msg v="1" type="queue.consume" seq="62" ts="..." from="watcher">
  <queue>events</queue><filter>task.*</filter><since>481516</since></msg>
```

规则：workqueue 必须带 `group`，group 首次出现时自动创建；topic 禁止带 `group`。topic 下 `ack_wait_s`/`max_deliver` 必须缺省，携带回 AEVT-4007。`filter` 支持 `*`（单段）与 `>`（后缀）通配。`since` 取 server 分配的 seq（不是发送方 ts），做 catch-up。

**queue.unconsume** — 取消订阅。不断开连接，只退订指定队列。

```xml
<msg v="1" type="queue.unconsume" seq="64" ts="..." from="watcher">
  <queue>stream.abc</queue><group>workers</group></msg>
```

规则：`group` 只在 workqueue 下必填。退订不存在的订阅幂等成功。

**queue.deliver** — 投递消息。server 发往消费者。

```xml
<msg v="1" type="queue.deliver" seq="20" ack="62" ts="..." from="server">
  <queue>task.dispatch</queue><group>workers</group><delivery_id>dlv-123</delivery_id>
  <redelivered>false</redelivered><message_id>uuid</message_id><payload><![CDATA[...]]></payload></msg>
```

规则：投递前查取消集合（§2.5）。命中则跳过投递，不重投。

**queue.ack** — 确认处理完毕。`<requeue/>` 表示立即重投（原 queue.nack，S3）。

```xml
<msg v="1" type="queue.ack" seq="63" ts="..." from="agent-7">
  <queue>task.dispatch</queue><group>workers</group><delivery_id>dlv-123</delivery_id></msg>
```

**error** — 同步错误。`in_reply_to` 关联触发消息。完整错误包见 §6。

```xml
<msg v="1" type="error" seq="14" in_reply_to="61" ts="..." from="server">
  <code>AEVT-4001</code><message>queue full</message><retryable>true</retryable></msg>
```

### 2.4 队列：唯一的投递原语

topic、workqueue、direct 是同一原语的三种用法，不是三种原语。

| 用法 | 做法 | 示例 |
|------|------|------|
| 广播 | `semantics=topic` 的队列 | `events` |
| 分工 | `semantics=workqueue` 的队列 + 消费者组 | `task.dispatch` |
| 点对点 | 发往对方收件箱（单消费者工作队列） | `agent.agent-7.inbox` |

约定队列（server 预声明）：

| 队列 | 语义 | 生产者 | 消费者 | 载荷 |
|------|------|--------|--------|------|
| `task.dispatch` | workqueue | orchestrator | workers 组 | task |
| `agent.<id>.inbox` | workqueue | 任意 | 该 agent（独占） | control / approval decision / 定向 task |
| `approval.requests` | workqueue | agents | server | approval request |
| `events` | topic | server、agents | 订阅者 | event |
| `stream.<task_id>` | topic | agent | 订阅者 | stream_event |

选择指南：**通知走 topic，分活走 workqueue，点名走收件箱。**

收件箱规则：consume 收件箱时 `group` 固定为 `inbox`。server 拒绝其他 group 订阅收件箱（回 AEVT-4007）。

stream 队列生命周期：server 在任务创建时隐式声明 `stream.<task_id>`。任务进入终态后保留 1 小时供 catch-up，随后自动删除。

审批代价：`approval.requests` 的消费者是 server 自己。走队列增加三段延迟：序列化（μs 级）、WAL 落盘（≤10ms 批量窗口）、投递（ms 级）。这是为统一性（审计事件天然落盘）付出的代价，设计接受。

### 2.5 载荷约定（5 种）

载荷是领域概念，不是原语。格式固定，client 库封装。

**task** — 任务规格。发往 `task.dispatch` 或某 agent 收件箱（定向）。

```xml
<task><task_id>uuid</task_id><spec executor="bash"><![CDATA[#!/bin/bash
...]]></spec><timeout_s>600</timeout_s></task>
```

规则：`task_id` 即幂等键。client 发布任务时取 `message_id = task_id`。`task.cancelled` 进入取消集合（§3.1）；server 投递前过滤，命中不投递。

**event** — 领域事件。发往 `events`。信封兼容 CloudEvents 1.0。

| subject | 生产者 | 说明 |
|---------|--------|------|
| `task.queued` / `task.started` / `task.completed` / `task.failed` / `task.cancelled` | server、agent | 任务状态机 |
| `agent.started` / `agent.stopped` | server | 成员变更 |
| `tool.called` | agent | `{tool, args_hash, duration_ms}`，args 只记 hash |
| `token.usage` | agent | 按任务聚合 |
| `queue.dead` | server | 死信（§2.6） |
| `queue.dropped` | server | 丢弃计数：`{queue, count, reason}`（drop_oldest / stream 字节封顶） |
| `error.raised` | 任意 | 统一错误包；`classification` 在 data 字段 |
| `*.failed` | 任意 | 失败血缘链：`causation_id` 指回原事件 |

任务状态机：

| 从 | 事件 | 到 |
|----|------|----|
| — | task.queued | queued |
| queued | task.started | running |
| running | task.completed | done |
| running | task.failed | failed |
| queued / running | task.cancelled | cancelled |

server 单线程投递，同一主题 FIFO。每任务两写者，因果有序：queued（server 写）先于 started（执行 agent 写）。订阅者看到因果序。

**stream_event** — 流式输出。发往 `stream.<task_id>`。`kind ∈ {chunk, tool_call, usage}`。

```xml
<stream_event><kind>chunk</kind><stream>stdout</stream><offset>4096</offset>
<data encoding="base64">aGVsbG8=</data><eof>false</eof></stream_event>
```

**control** — 控制命令。发往目标 agent 收件箱。`signal ∈ {interrupt, kill, cancel}`。

```xml
<control><signal>cancel</signal><task_id>uuid</task_id></control>
```

**approval** — 审批。request 发往 `approval.requests`；decision 发往 agent 收件箱。`phase ∈ {request, decision}`。

```xml
<approval><phase>request</phase><task_id>uuid</task_id>
<action>shell.exec</action><summary>rm -rf /srv/app/cache</summary></approval>
```

### 2.6 可靠性

**重入原语**（S2，修复 Issue #1/#2）：

```
requeue_or_dead(m):
  若 pendCount[m] >= max_deliver：m 进死信，发 queue.dead + *.failed
  否则：m 回队列
```

超时、离开回收、ack+`<requeue/>` 三处都调用它。不准各写一遍。

**参数**：`ack_wait_s` 缺省 30。`max_deliver` 缺省 5。

**死信**：不另建存储。原消息不动，append `queue.dead` 事件 + `*.failed`（血缘链）。`asock queue replay-dlq` 重放。

**背压**：`max_depth` 缺省 10000。超限按 `overflow` 处理：`block`（回 AEVT-4001 + `retry_after_s`）或 `drop_oldest`（挤掉最旧未消费 + 发 `queue.dropped` 事件）。组 pending 超限暂停向该组投递，降至水位线自动恢复。

**空组语义**：workqueue 无成员时 publish 正常入队，不阻塞。server 发告警事件（code AEVT-4005）到 `events`。worker 加入后按序消费。

### 2.7 断线重连

- Client 指数退避重连（1s 起，上限 30s）。重连后发 `agent.register`（`resume=true` + 上次 ack）。
- `resume=true` 时 server 回复会话状态。会话已标 lost，回 AEVT-4008；client 重建状态后重新 register。
- Server 按字节保留每个 agent 的 stream chunk，上限 10MB/agent。超限丢最旧，发 `queue.dropped` 事件。client 用 `queue.consume`（`since` = server seq）补洞。
- 心跳租约：15s 无心跳标 suspect；60s 无心跳标 lost，其 running 任务按 §2.6 回收。

### 2.8 原语对照表（v2.1 → v4）

v2.1 共 27 个原语。v4 共 11 个（新增 `queue.unconsume`）。

| v2.1 | v3 | 依据 |
|------|----|------|
| agent.register | 保留（应答并入，ack 关联） | 会话建立无替代 |
| agent.registered | 并入 agent.register | 请求/应答同类型，规则统一 |
| agent.heartbeat | 保留 | 存活信号；lost 判定与离开回收依赖可监控的成员关系 |
| agent.deregister | 保留 | TLA+ Leave；P1 依赖原子回收 |
| agent.card | 保留（应答并入） | pull 式能力发现（SOTA-A2A） |
| agent.card.result | 并入 agent.card | 同上 |
| task.submit | = queue.publish（载荷 task） | P2 覆盖任务幂等 |
| task.accepted | = task.queued 事件 | 状态机更完整 |
| task.status | = events 上的 task.* 事件 | 单写者 + FIFO，顺序有保证 |
| task.cancel | = control 载荷（signal=cancel） | 控制面统一 |
| queue.declare | 保留 | 语义与策略的显式配置点 |
| queue.publish | 保留 | 唯一的发送原语；P4 的起点 |
| queue.consume | 保留（吸收 event.subscribe） | 唯一的订阅原语 |
| — | queue.unconsume（v4 新增） | 退订不断开连接 |
| queue.deliver | 保留 | TLA+ Deliver；P1/P2 的载体 |
| queue.ack | 保留（nack 并入为 requeue 标志） | TLA+ Ack；P3 依赖 ack 区分成功与重投 |
| queue.nack | 删除 | S3：TLA+ 证明与 Timeout 同一转移 |
| task.approval.request | 并入 approval 载荷（phase） | SOTA-ACP 审批门；方向由队列名区分 |
| task.approval.decision | 并入 approval 载荷（phase） | 同上 |
| stream.chunk | 并入 stream_event（kind） | 类型化保留，wire 层统一 |
| stream.tool_call | 并入 stream_event（kind） | 同上 |
| stream.usage | 并入 stream_event（kind） | 同上 |
| stream.resume | = queue.consume 的 cursor | 流即主题；catch-up 统一 |
| stream.end | = task.completed/failed 事件 | 状态机吸收；exit_code 进事件 data |
| control.interrupt | 并入 control 载荷（signal） | 控制面统一 |
| control.kill | 并入 control 载荷（signal） | 同上 |
| event.subscribe | = queue.consume（topic + filter） | 订阅统一 |
| error | 保留 | 同步错误通道；fail-fast 载体 |
| 信封 `to` | 删除（地址=队列名） | 寻址能力保留 |
| partition_key | 删除 | S1：P5/P6 只在 clean 时成立 |

砍掉的语义无一携带独立性质。P1–P4 在简化模型中重验通过（tla/VERIFICATION.md）。

---
## 3. 队列实现

§2 定义语义。本节定义存储与运维。

### 3.1 存储

```
queues/<name>/log.jsonl     # append-only 消息日志
queues/<name>/state.json    # {group: {cursor, pending}}，批量刷盘
server/cancelled.json       # 取消集合：已取消 task_id，投递前过滤
```

WAL 批量刷盘：每 10ms 或每 100 条消息刷一次 state.json，取先到者。crash 最多丢一个窗口的投递/ack 状态；重放恢复后，未 ack 的 pending 重投。

Tombstone 不占队头：FIFO 取队头时先过滤已取消任务再取最小 mid，否则已取消队头饿死其后任务（TLA+ Deliver 的 `m \notin cancelled` 前提）。

Compaction：所有 group 的 cursor 超过 seq N，或距上次 compaction 超 7 天，截断 log 到 N（保留最近 1000 条）。7 天超时强制推进：落后 group 视为已推进，记事件。

`events` 主题落盘：`events/events.jsonl`，先 fsync 再广播。Retention：100MB 一段，保留 10 段；每日 04:00 生成 `events-YYYYMMDD.jsonl.gz`。

### 3.2 慢消费者

`deliver` 后 2×`ack_wait_s` 无 ack，标 `stalled` 并发事件。stalled 持续 5 分钟且组 pending 超限，server 停止向该消费者投递；恢复后继续。不自动杀。杀是编排器的决策（§4 `terminate`）。

### 3.3 与 §2 的关系

队列复用同一 socket 连接。不另开端口。订阅状态记在连接上下文；重连后 client 自动重发 `queue.consume`（带 cursor 补洞）。

---

## 4. Tmux 工具封装

目标：tmux 是 agent 的"物理机房"，本库是机房管理员。直接调 `tmux` CLI，不依赖 libtmux。

### 4.1 资源模型

```
Session (1:1 agent) → Window (1:1 task) → Pane (1:1 worker)
```

- agent 跑在独立 socket：`tmux -S ~/.agent-sock/tmux.sock`，与用户日常 tmux 物理隔离。
- Session 名 `asock-<agent_id>`。task 一个 window。pane 寻址永远用 `%id`。
- 事件上报：spawn/stop/stall/death 走 `events` 主题。

### 4.2 API（`tmux_tool.py`）

| 方法 | 说明 |
|------|------|
| `spawn_agent(agent_id, cmd)` | 建 session，起 agent 进程；记录恢复元数据 |
| `run_in(task_id, cmd)` | 在 agent session 内新 window 跑命令 |
| `run(cmd, timeout)` | 确定性同步：注入 `cmd; tmux wait-for -S <uuid>` 并阻塞等待 |
| `capture(agent_id, window?, lines=200)` | `capture-pane -p` 取文本 |
| `capture_since(agent_id, window?)` | 游标式增量读取；游标落后返回 `missed=True` 并重建 |
| `snapshot(agent_id)` | 快照"恢复意图"（cwd/layout/launch_cmd/handle），不含进程内存 |
| `restore(snapshot)` | 重建现场 + 执行 `launch_cmd` |
| `tile(agent_ids)` | 多 agent 网格排布 |
| `terminate(agent_id, graceful_timeout)` | 两段式终止：SIGINT 确认 → 超时 kill-pane + 进程树收尸；全程写事件 |

规则：`send-keys` 返回不等于命令执行。用 `wait-for` 做确定性同步。存活判断读 `pane_dead`，不读 session 存在性。

### 4.3 输出事件源

- `PollingEventSource`（首版）：轮询 + `capture_since` 游标。
- `ControlModeEventSource`（二期插槽）：`tmux -C` 解析 `%output`，实时事件。
- control mode 告诉"何时变"，capture-pane 告诉"现在何样"。

### 4.4 编译式交互（`tmux_compile`，已迁至 cklxx/fx）

§5"烧录"在 tmux 域的具体实现：把 YAML 描述的多轮 pane 交互编译成自包含
bash 产物（§5.2 目标 A 的实例化）。LLM 只做一次编译决策，执行零 LLM 参与。

**位置**：编译器已迁至 cklxx/fx 的 `tools/tmux_compile/`（fx 性能项目的一
部分，见该目录 README）。agent-sock 只保留驱动侧：

- `agent_sock/tmux_compile.py` — `compile_and_run()`，产物跑在 agent pane 上。
  依赖 fx 的 `tmux_compile` 包（PYTHONPATH 指向 fx 的 tools/tmux_compile）。
- `asock tmux-compile` — 驱动到 agent pane 的 CLI。
- `tests/test_tmux_compile_integration.sh` — 驱动层集成测试。

编译器能力（`run`/`wait_for`/`branch`/`parallel`/`retry`/`fail`、`{{param}}`
展开）与产物契约（exit 0/10/11/12/13/14/15）见 fx 侧
`tools/tmux_compile/docs/TMUX_COMPILE_GUIDE.md`。

---

## 5. 流水线烧录

"烧录" = 把 N 轮 LLM 交互的 action 序列提前编译成单轮可执行 bundle。LLM 只做一次编译决策，执行零 LLM 参与。

### 5.1 输入（DSL）

```yaml
name: deploy-check
vars: {host: "prod-1", retries: 3}
steps:
  - id: build
    run: "make -C /srv/app build"
    timeout_s: 300
    retry: {times: 2, backoff_s: 5}
    on_fail: fail
  - id: health
    run: "curl -sf http://{{host}}/health"
    checkpoint: true
  - id: rollback
    run: "./rollback.sh {{host}}"
    when: "steps.build.failed"
    needs: [build]
```

### 5.2 编译

- 目标 A（默认）：自包含 bash。零运行时依赖，tmux 里直接跑。
- 目标 B：XML 任务包，由 server executor 解释执行。
- `needs` 建 DAG，拓扑排序，环则编译失败。无依赖节点并行（`&`+`wait`）。
- 条件用 CEL 子集：编译期 parse + 类型检查 + 变量引用分析。语言本身不可表达副作用，防注入不靠沙箱。
- 非确定步骤标 `effect: llm`，强制配 checkpoint + 幂等键。

### 5.3 语义

- 变量：`{{var}}` 编译期展开；`$VAR` 透传环境变量。上游 `outputs` 具名，下游按名引用。
- 失败：`on_fail ∈ {fail, continue, goto:<step>}`。重试耗尽才算 step failed。重试只用于幂等操作，指数退避，有界 3–5 次。
- 超时：单步 `timeout -k` 两段杀；pipeline 级 `total_timeout_s`。
- Checkpoint：标 `checkpoint: true` 的步骤成功后原子写检查点（临时文件 + `mv`）。重跑 `--resume-from` 跳过已完成步骤。
- 编译器输出 → `client.submit_task(spec)`（= `queue.publish` 到 `task.dispatch`）。执行中每步起止发事件。

---

## 6. 报错与恢复

### 6.1 错误包

```json
{"code": "ASOCK-2003", "message": "agent heartbeat timeout", "severity": "error",
 "retryable": true, "agent_id": "agent-7", "task_id": "uuid", "ts": 1728500000.123,
 "context": {"last_seen_s": 47}, "caused_by": {"code": "ATMUX-1001", "message": "..."}}
```

`code` 全局唯一，前缀按模块：`ASOCK` / `AEVT` / `ATMUX` / `APIPE` / `ACOM`。`retryable` 由抛出处判定。`caused_by` 只一层。

### 6.2 错误码表

| code | 场景 | 分类 |
|------|------|------|
| ASOCK-1001 | socket 不存在/权限拒绝 | 需人工 |
| ASOCK-2001/2002/2003 | 连接拒绝/版本不匹配/心跳超时 | 可重试 |
| AEVT-3001 | 事件落盘失败 | 致命 |
| AEVT-4001 | 队列满（`overflow=block`） | 可重试（按 `retry_after_s`） |
| AEVT-4003 | 消息进死信 | 需人工 |
| AEVT-4005 | 空消费者组 publish（告警事件，不阻塞） | 观察（检查组） |
| AEVT-4006 | 队列未声明 | 需人工（先 declare） |
| AEVT-4007 | 参数错误：declare 冲突 / topic 携带 ack 参数 / 收件箱 group 非 inbox | 需人工（修正参数） |
| AEVT-4008 | resume 时会话已标 lost | 可重试（重建状态后重连） |
| ATMUX-1001/1002 | tmux 未安装/server 失联 | 需人工 |
| ATMUX-2001 | pane 命令超时 | 可重试 |
| APIPE-1001 | 编译期错误（变量未定义等） | 致命（不执行） |
| APIPE-2001 | 步骤失败且无 on_fail | 按步骤策略 |
| APIPE-3001 | checkpoint 损坏 | 需人工 |

v3 删除：AEVT-4002（rebalance 事件，随 S1 删除）、AEVT-4004（partition 乱序，随 S1 删除）。

### 6.3 自动分类器

```
可重试 = retryable 且 同一 task 5 分钟内重试 < 3 次
需人工 = 不可重试 或 重试耗尽
致命   = severity=fatal
```

分类结果写事件：subject 固定为 `error.raised`，`classification` 进 data 字段。

### 6.4 Checkpoint 与恢复

- 粒度：pipeline step 级 + task 级（server 任务队列持久化，重启 requeue）。
- `asock resume <pipeline_id>`。checkpoint 只保证"从某步重跑"，不保证副作用可逆。

---

## 7. 包结构

```
tools/sock/  (cklxx/fx)
  DESIGN.md / SOTA.md / protocol-spec.md / ERROR_HANDLING.md
  agent_sock/
    proto.py      # 信封编解码、成帧、11 原语常量、错误包
    errors.py     # 错误码、分类器
    server.py     # sock server + 队列引擎 + 注册表
    client.py     # 重连、心跳、submit/stream/subscribe（封装 queue.*）
    queue.py      # workqueue/topic：group、PEL、requeue_or_dead、死信、背压、compaction
    tmux_tool.py
    pipeline.py   # DSL 解析 + 编译器（bash/XML 双目标，CEL 子集）
    cli.py        # asock serve/submit/tail/events/snapshot/resume/queue
  tla/
    SeqAck.tla / WorkQueue.tla   # v3 简化模型
    VERIFICATION.md / SIMPLIFICATION.md
    run.sh / tla2tools.jar
  tests/
    test_proto.py / test_server_client.py / test_queue.py
    test_tmux.py / test_pipeline.py / test_errors.py
  events/         # 运行时 JSONL（gitignore）
```

`queue.py` 不再有：partition_key、nack 独立路径、三策略 overflow。`test_queue.py` 用例：竞争消费恰一人拿到、ack 超时重投、`max_deliver` 进死信、ack+requeue 立即重投、背压 block 回 AEVT-4001、空组 publish 正常入队+告警事件、drop_oldest 发 `queue.dropped`、取消集合过滤投递、unconsume 退订、compaction 截断+7 天强制推进。

---

## 8. 测试策略

- 单元：proto 成帧 fuzz、CDATA `]]>` 转义用例（`]]]]><![CDATA[>` 回环）、pipeline 编译 golden 测试、分类器表驱动。
- 集成：本地 socket 回环跑完整任务生命周期；订阅 + 回放；WAL crash 恢复（kill -9 后至多丢一个批量窗口）。
- 队列：见 §7 `test_queue.py` 用例。
- 混沌（二期）：随机 kill agent 验重传；server 重启验 requeue。
- 覆盖率：proto/queue/pipeline ≥ 90%，tmux/client ≥ 70%。

---

## 9. 待拍板（已裁决）

REVIEW §5 已全部裁决，无需用户拍板。结论如下：

| # | 事项 | 裁决 |
|---|------|------|
| 1 | 事件 retention | 100MB×10 为缺省值，改为可配置项 |
| 2 | pipeline 默认编译目标 | A（bash）。烧录卖点是零依赖单文件 |
| 3 | pane 捕获：轮询/hook | 首版轮询；EventSource 接口预留 hook 插槽 |
| 4 | Web dashboard | 移出 v1 范围 |
| 5 | 包名 | `agent_sock`（PEP8 可 import 名）；CLI 保持 `asock` |
| 6 | 队列满默认策略 | 按队列区分：`task.dispatch` 用 block，`events` 用 drop_oldest；declare 时必填，无全局缺省 |

---

## 10. 修订记录

v4（2026-10-11，REVIEW 25 项全量修复）：

| # | 修订 | 对应 |
|---|------|------|
| 47 | 信封新增 `in_reply_to`（值为原请求 seq）；`ack` 只做传输确认 | R-01 |
| 48 | 空组 publish 正常入队；AEVT-4005 改为告警事件，不阻塞 | R-02 |
| 49 | 发送方强制转义 `]]>` → `]]]]><![CDATA[>`；§8 加转义用例 | R-03 |
| 50 | `max_frame_bytes`=16MB（超限断连接+记事件）；`max_payload_bytes`=8MB（超限回 error） | R-04 |
| 51 | server 维护 cancelled 集合，投递前过滤；取消语义进 §2.5/§3.1 | R-05 |
| 52 | server 改为单线程 asyncio 事件循环；删除 thread-per-connection；dispatcher 即事件循环 | R-06/R-14 |
| 53 | WAL 批量刷盘（10ms 或 100 条）；crash 最多丢一个窗口 | R-07 |
| 54 | 新增 `queue.unconsume` 原语；原语 10→11 | R-08 |
| 55 | 收件箱 group 固定为 `inbox`；server 拒绝其他 group 订阅收件箱 | R-09 |
| 56 | 任务终态后 stream 队列保留 1 小时，自动删除 | R-10 |
| 57 | topic 下 `ack_wait_s`/`max_deliver` 必须缺省，携带回 AEVT-4007 | R-11 |
| 58 | compaction 加 7 天时间上限；超时强制推进并记事件 | R-12 |
| 59 | XML 解析约束：最大嵌套深度 32，最大元素数 100000 | R-13 |
| 60 | `error.raised` subject 固定；classification 进 data | R-15 |
| 61 | 新增 `queue.dropped` 事件 `{queue, count, reason}` | R-16 |
| 62 | declare 参数冲突回 AEVT-4007（新增）；一致则幂等成功 | R-17 |
| 63 | workqueue group 首次 consume 自动创建 | R-18 |
| 64 | `resume=true` 时已标 lost 回 AEVT-4008（新增）；client 重建状态 | R-19 |
| 65 | 承认审批走队列是统一性代价；文档写明三段延迟量级 | R-20 |
| 66 | 默认策略：stalled 持续 5 分钟且 pending 超限，停止向该消费者投递 | R-21 |
| 67 | 声明首版仅支持 Linux | R-22 |
| 68 | stream chunk 按字节封顶 10MB/agent；超限丢最旧并记事件 | R-23 |
| 69 | `since` 改用 server 分配的 seq，不用发送方 ts | R-24 |
| 70 | "单一写者"改为"每任务两写者，因果有序" | R-25 |
| 71 | §9 六项待拍板按 REVIEW §5 裁决全部定掉 | §9 |

v3（2026-10-10，用户拍板 S1–S4 全采纳 + 深度简化）：

| # | 修订 | 依据 |
|---|------|------|
| 31 | Issue #1/#2 修复：`requeue_or_dead(m)` 单原语，超时/离开回收/ack+requeue 三处共用 | TLA+ |
| 32 | 删除 partition_key、sticky 分配、assign 表、AEVT-4004 | S1 |
| 33 | 删除 Rebalance 动作；Leave 回收即全部；删除 AEVT-4002 | S1 |
| 34 | 删除 `queue.nack` 独立原语；`queue.ack` 加 `<requeue/>` 标志 | S3 |
| 35 | overflow 去掉 `drop_newest`，剩 `block` + `drop_oldest` | S4 |
| 36 | wire 原语 27→10：`queue.publish`/`queue.consume` 为唯一发送/订阅原语 | 深度简化 |
| 37 | topic/queue/direct 统一为队列；direct = 发往收件箱 | 深度简化 |
| 38 | 信封删除 `to` 属性；寻址 = 队列名 | 深度简化 |
| 39 | `task.submit`/`task.accepted`/`task.status`/`task.cancel` 并入队列 + 事件 | 深度简化 |
| 40 | `stream.*` 5 原语并入 `stream_event` 载荷；`stream.resume` 并入 consume cursor | 深度简化 |
| 41 | `control.*` 并入 control 载荷；`approval.*` 并入 approval 载荷；请求/应答同类型 | 深度简化 |
| 42 | `event.subscribe` 并入 `queue.consume`（topic + filter） | 深度简化 |
| 43 | 幂等键术语统一：seq 去重/task 幂等/message_id 去重只讲一次 | SIMPLIFICATION.md |
| 44 | 新增 AEVT-4005（空组 publish）、AEVT-4006（队列未声明） | TLA+ A1 |
| 45 | TLA+ 模型同步简化（删 Nack/Rebalance/partition），TLC 重验通过 | v3 验证 |
| 46 | 协议章按 ASD-STE100 重写：术语表 + 每原语 schema/一句话/一示例 | 用户要求 |

v2.1 修订见 git 历史。v2 修订（SOTA 合入 #1–#24）见 git 历史。
