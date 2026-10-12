# Agent Sock — SOTA 调研档案

> 日期：2026-10-10 · 四个方向并行深挖（官方文档 + 源码，非博客二手总结）
> 结论先行：我们的差异化不在"又一个协议"，而在三处——**Unix socket 原生传输**、**协议内建"编译"原语**（多轮→单轮）、**事件即事实的可重放保证**。下面每个方向给出借鉴点与超越点。

---

## 方向一：Agent 通信协议（MCP / ACP / A2A）

### MCP（Model Context Protocol，Anthropic）
- **消息/传输**：JSON-RPC 2.0；stdio（子进程 stdin/stdout，换行分隔）与 Streamable HTTP（单端点 `/mcp`，POST 发消息 + GET SSE 回推；2026-07 修订后传输层无状态，移除 `Mcp-Session-Id`）。
- **角色与原语**：Host（内嵌 LLM 的应用）→ Client（1:1 连接器）→ Server（暴露能力）。Server 侧三原语：tools / resources / prompts；Client 侧反向能力：sampling（递归 LLM 调用）、roots、elicitation；另有 progress、cancellation、logging。
- **场景**：agent↔工具/数据源的标准化接入（M×N → M+N）。
- **硬伤**：版本迭代极快（2024-11→2026-07 四大版，传输与授权多次重写，自研实现必须 pin 版本）；安全包袱重（Streamable HTTP 需防 DNS rebinding、远程需 OAuth 2.1 + RFC 8707）；**只管 agent↔工具，不管 agent↔agent**。
- 来源：https://modelcontextprotocol.io/specification/2025-11-25

### ACP（Agent Client Protocol，Zed）
- **为什么另起**：MCP 只覆盖"agent 调工具"，没覆盖"编排器如何驱动 agent"。Zed 之前把 CLI agent 塞进终端 TUI 跑：看不到 token 成本、工具调用、任务状态。ACP 按 LSP 哲学做解耦层：JSON-RPC 2.0 over stdio，agent 做子进程，client 用结构化消息驱动。2025-08 发布 v1，JetBrains 共同维护，Claude Code / Gemini CLI / Codex 均有适配。
- **核心方法**：`initialize`（协商 protocolVersion + 双向 capability 广告）→ `session/new`（cwd + mcpServers）→ `session/prompt`（阻塞到 `stopReason`：end_turn/max_tokens/max_turn_requests/refusal/cancelled）→ `session/update` 通知（类型化 chunk：agent_message_chunk、tool_call/tool_call_update 9 种、plan、usage_update）→ `session/request_permission`（敏感操作审批门）→ `session/cancel`（协作式中断）。client 可被反向调用 `terminal/*`、`fs/*`。
- **硬伤**：session 内同时只允许一个活跃 prompt turn；回合级阻塞粒度粗（做不了细粒度"编译"控制）；tool_call 种类面向写代码，通用任务需自定义扩展。
- 来源：https://agentclientprotocol.com/protocol/v1/overview · https://github.com/agentclientprotocol/agent-client-protocol

### A2A（Agent-to-Agent，Google → Linux Foundation）
- **消息/传输**：三层——L1 规范数据模型（proto 唯一权威）、L2 抽象操作、L3 协议绑定（JSON-RPC 2.0 over HTTPS 为正式绑定，另有 gRPC/REST）；流式用 SSE，超长任务支持 webhook push。
- **核心原语**：AgentCard（`/.well-known/agent-card.json`：skills、interfaces、capabilities、securitySchemes）做发现；Task 生命周期 `submitted → working → input-required → completed/failed/canceled/rejected`；`message/send` / `message/stream` / `tasks/get|list|cancel`；Message（role+parts）与 Artifact（产出物）分离；与 MCP 分工：MCP 管 agent↔工具，A2A 管 agent↔agent，执行细节互不透明。
- **硬伤**：重量级（AgentCard、OAuth2/JWT/OIDC、三 binding），本地同机多 agent 杀鸡用牛刀；**只定义通信面，不定义编排面**（路由/重试/冲突全扔给实现方）；生态早期（2025-04 发布）。
- 来源：https://a2a-protocol.org/latest/specification/

### 借鉴（5 条，可落地）
1. **学 ACP 的 session 模型做任务单元**：`session/new`（cwd+资源声明）→ prompt（阻塞到 stopReason）→ cancel；stopReason 枚举直接纳入统一错误码，解决失败分类。
2. **学 ACP 的类型化 update 做流式输出**：区分 message_chunk / tool_call_update / plan / usage，plan 事件天然支撑流水线可视化。
3. **学 ACP 的 request_permission 做审批门**：敏感操作反向请求编排器裁决（allow once/always），协议层的验收门。
4. **学 MCP 的 capability 协商**：initialize 双向广告能力，agent 注册/心跳上报能力表，编排器按能力路由。
5. **学 A2A 的 AgentCard 做轻量发现**：socket 保留方法 `agent/card` 返回名片（id/skills/endpoint），零依赖服务发现。

### 超越（3 条）
1. **Unix socket 原生传输**：三家假设 stdio 子进程或 HTTP 网络；同机多 agent 场景下 socket 的低延迟、`SO_PEERCRED` 对端凭证、文件权限即 ACL 值得做一等公民，而非把 HTTP 语义硬套上去。
2. **把"编译"做进协议**：三家都是回合级交互；协议层原生支持"bundle 下发 + 分步回执 + 断点续跑"，这是三家都没有的原语。
3. **事件即事实的协议级保证**：每条控制消息先落盘后回 ack，让中断/崩溃恢复成为协议内建能力。注：借鉴点与序列化格式正交，JSON→XML 迁移不受影响。

---

## 方向二：事件订阅系统（NATS JetStream / Redis Streams / CloudEvents）

### NATS JetStream
- **投递语义**：Core NATS 是 at-most-once fire-and-forget；JetStream 默认 at-least-once（AckExplicit/AckAll + AckWait 重投 + MaxDeliver），exactly-once 明确 out of scope（只有发布端 `Nats-Msg-Id` 去重窗口，消费端靠幂等）。
- **持久化/回放**：Stream（持久化日志）+ Consumer（独立读取视图）；Retention 三选一（Limits/Interest/WorkQueue）；DeliverPolicy（All/Last/LastPerSubject/New/ByStartSequence/ByStartTime）；ReplayPolicy（Instant/Original）；KV（每 subject 只留最后一条，常被拿来存 agent 注册表/心跳租约）。
- **订阅过滤**：subject 点分隔层级通配，`*` 单 token、`>` 后缀；Consumer 支持服务端 FilterSubject。
- **agent 案例**：arcana（LangGraph+JetStream，durable at-least-once，72h 回放窗口，poison message 进 dead-letter）；gateforge-ai-ao（`project.*.task.*` 控制平面，Git 做事实源、JetStream 做实时神经系统）。
- **坑**：subject 设计即 API 设计，改名要跨服务协调；durable consumer 状态在 server 端；WorkQueue ack 即删与"事件即事实"审计需求冲突；终究是外部进程。
- 来源：https://github.com/nats-io/nats.docs（`using-nats/jetstream/develop_jetstream.md`）、aetherbus ADR 0001

### Redis Streams
- **投递语义**：at-least-once，机制显式手动：XADD → XGROUP → XREADGROUP（`>` 取新条目，组内单 consumer）→ XACK；未 ack 留在 PEL（Pending Entries List），靠 XPENDING/XCLAIM/XAUTOCLAIM 做故障转移；PEL 不清理会无限增长。
- **持久化/回放**：XRANGE/XREVRANGE 按 ID 区间读；无 JetStream 式 retention（只有 XTRIM/MAXLEN 按条数截断）；持久化靠 RDB/AOF；长历史 = 常驻内存。
- **订阅过滤**：没有。按事件类型拆 key 或客户端过滤。
- **局限**：内存贵、无内置 DLQ、无去重窗口、无 ack deadline 自动重投、group 游标模型粗（只有一个最后投递 ID）。
- 来源：https://github.com/cloudstreet-dev/event-driven-architecture（ch16）、vortexkv docs

### CloudEvents（CNCF 毕业，非 broker，是信封规范）
- **规范 1.0/1.0.2**：必填 `id`、`source`（URI）、`type`（反向 DNS）、`specversion`；`source`+`id` 全局唯一，重试复用同一 id（去重锚点）；可选 `time`（RFC3339）、`subject`、`data`；binary 模式（属性放 header，可不反序列化路由）与 structured 模式。
- **agent 落地**：LangChain/ADK 本体不用（各有自有信封）；但周边收敛中——Apache EventMesh A2A 把 MCP 包进 CloudEvents 信封传输；aetherbus PRD 明确 envelope 采用 CloudEvents + `dataref` 做大 payload claim-check。角色是**互操作信封**：内部格式放 `data`，跨框架/跨组织用人话信封。
- 来源：https://github.com/cloudevents/spec（v1.0.2）、https://cloudevents.io/、apache/eventmesh A2A 设计文档

### 借鉴（5 条，单机零依赖约束下）
1. **信封兼容 CloudEvents 1.0**：JSONL 每行用 `id`/`source`/`type`/`specversion`/`time`/`subject`/`data`；`source` 命名 `agent://<id>`、`tmux://<session>`。零成本，未来任何懂 CloudEvents 的工具直接可读。
2. **Subject 层级 + 服务端通配过滤**：如 `agent.worker.completed`；订阅支持 `*`（单 token）与 `>`（后缀），服务端挡掉不需要的事件（Redis 做不到、我们实现便宜）。
3. **Per-subscription durable cursor + 显式 ack**：每个订阅维护 `last_acked_seq` 落盘；`since_ep` 回放 = DeliverByStartSequence；未 ack 超 AckWait 回投（本地 PEL 存内存+定期落盘）。
4. **Retention 双策略**：已有"大小轮转+日归档"即 JetStream Limits；再补可选 WorkQueue 语义流（ack 后即删），任务分发与事实日志不混用保留策略。
5. **发布端幂等键**：借鉴 `Nats-Msg-Id` 去重窗口，用 CloudEvents `id` 天然承载，server 维护最近 N 个 id 集合去重。

### 超越（3 条）
1. **回放零预声明**：JetStream 回放要先建 durable consumer 并管理生命周期；我们 offset 是 client 每次请求的参数（`since_ep` 任意传），server 无状态 serving——单机 append-only 文件相对 server 端状态机的结构性优势。
2. **失败本身也是事件**：不删原事件，append 一条 `*.failed`（带 `causation_id` 指回原事件），形成失败血缘链；审计/重试/复盘都从同一份 JSONL 长出来，不需要第二套 DLQ。
3. **运维即文本**：轮转与归档固定命名（`events-YYYYMMDD.jsonl`+序号），每行自包含；`tail/grep/awk` 直接读，"看不懂内部状态"的问题不存在。

### 附：Work Queue 语义深挖（JetStream vs Redis Streams vs 本设计）

> 2026-10-10 第二轮补充：用户要求多对多消息队列语义正式入设计（DESIGN.md §3.5）。本附录把两家的 work queue 机制拆到可落地的细节。

**NATS JetStream（workqueue 模型）**
- **Retention 三选一**：`LimitsPolicy`（按条数/字节/时间截断）、`InterestPolicy`（无活跃订阅者即删）、`WorkQueuePolicy`（消息被**所有**感兴趣的 consumer ack 后即删）——任务分发用 WorkQueue，审计日志用 Limits。
- **Consumer ack 模型**：`AckExplicit`（逐条 ack）、`AckAll`（ack 某条即确认之前所有）、`AckNone`（fire-and-forget）；`AckWait`（默认 30s）超时未 ack 自动重投；`MaxDeliver`（默认 -1=无限）超限后按配置转 DLQ subject 或丢弃；`BackOff` 可配重投退避时间表。
- **Queue groups（Core NATS 层）**：同 queue 名的订阅者形成负载均衡组，一条消息只投组内一人——这是 NATS 的"竞争消费"原语；JetStream durable consumer 是它的持久化版本（带 cursor、ack、回放）。
- **顺序**：`OrderedConsumer`（单 consumer、server 端重建式恢复，保序）；普通 consumer 重投时不保证顺序。
- **Backpressure**：server 端 `FlowControl`（consumer 消费慢时 server 主动降速）+ `IdleHeartbeat`（空闲心跳，断连早发现）；而不是让 client 被压垮。
- **发布去重**：`Nats-Msg-Id` header，server 侧去重窗口（默认 2 分钟）。
- **KV**：每 subject 只保留最后一条，常被拿来存 agent 注册表/心跳租约（我们的 `agent.heartbeat` 可借鉴，但我们用内存+事件代替）。

**Redis Streams（consumer group 模型）**
- **基本循环**：`XADD key * f v` → `XREADGROUP GROUP g c COUNT n BLOCK ms STREAMS key >`（`>` 取从未投递过的新消息；用具体 ID 则读 PEL 旧消息）→ `XACK key g id`。
- **PEL（Pending Entries List）**：未 ack 的消息显式留在 PEL；`XPENDING key g` 按区间查；`XAUTOCLAIM key g c 60000 0`（Redis 6.x+）把超时未 ack 的转给当前 consumer（故障转移）；`XCLAIM` 是手动版。**PEL 不清理会无限增长**（运维坑）。
- **无 ack deadline 自动重投**：全靠 client 轮询 XPENDING + XCLAIM，没有 server 端 AckWait。
- **无内置 DLQ**：超限消息要手动 `XADD` 到另一个 stream（社区约定俗成，无标准）。
- **阻塞读**：`BLOCK ms` 做 long-poll，`COUNT n` 批量拉——backpressure 全靠 client 自限。
- **持久化**：stream 常驻内存，长历史贵；`XTRIM key MAXLEN n` 按条数截断；持久化靠 RDB/AOF（不是为队列设计的）。
- **无服务端过滤**：按事件类型拆 key 或客户端过滤。

**三方对比**

| 维度 | JetStream | Redis Streams | 本设计（§3.5） |
|---|---|---|---|
| 投递保证 | at-least-once（AckWait+MaxDeliver） | at-least-once（手动 PEL） | at-least-once per group（ack_wait 30s + max_deliver 5） |
| 竞争消费 | queue group / durable consumer | `XREADGROUP ... >` | consumer group + round-robin |
| 失败转移 | server 自动重投 | XPENDING+XAUTOCLAIM（client 驱动） | AckWait 超时 server 自动重投 |
| DLQ | 可配（MaxDeliver 后转 subject） | 无（手动另建 stream） | `queue.dead` + `*.failed` 血缘链（无第二存储） |
| Backpressure | FlowControl + IdleHeartbeat | 无（client 自限 COUNT/BLOCK） | `max_depth`+overflow 三策略+组级 flow control+`stalled` 检测 |
| 顺序 | OrderedConsumer / 无跨重投保证 | 单 stream 内 ID 有序 | FIFO + `partition_key` sticky（rebalance 短暂乱序诚实声明） |
| 留存 | WorkQueue / Limits / Interest | XTRIM MAXLEN | WorkQueue（compaction）+ topic 用 Limits |
| 过滤 | subject `*`/`>` 通配 | 无（按 key 拆） | topic 用通配；queue 按名 |
| 运维面 | 外部进程 + server 端状态机 | 外部进程 + 常驻内存 | 单机文件（JSONL+state.json），`tail/grep` 可读 |

**落到我们设计的关键取舍**（为什么不是"照抄 JetStream"）：
1. **单机文件 vs 外部进程**：JetStream/Redis 都要常驻服务进程；我们用 `log.jsonl`+`state.json`，crash 恢复 = 重放文件。代价是吞吐上限（单机文件 IO），但 agent 任务分发是低频场景（<1000 msg/s），够用。
2. **DLQ 不另建存储**：JetStream 转 subject、Redis 手动另建 stream——都是第二套存储。我们的 `*.failed` 血缘链让死信和审计长在同一份 JSONL 里（SOTA.md 方向二"超越 #2"的延伸）。
3. **PEL 落盘**：Redis 的 PEL 在内存（RDB 才持久化）；我们的 pending 表每次投递/ack 后刷 `state.json`——crash 不丢"谁拿了没 ack"的状态，这是 work queue 正确性的关键。

---

## 方向三：tmux 工具（最强实践）

### 三个代表性路线
1. **superharness**（https://github.com/udlrcodes/superharness）：主 agent 即调度器；每个 worker 独占 tmux session + 独立 git worktree（文件级隔离）；权限审批、stall 检测、Away Mode。**借鉴：session 拓扑与工作区隔离绑定**（session 名编码归属 `agent-<task>-<worktree>`）。
2. **tmux-router**（https://github.com/btakita/tmux-router，Rust）：**Hybrid Pane Policy**——生命周期与事件走 control mode，持久化输出流走 `pipe-pane`，输入走 tmux 提交回退，只有字节精确交付关键时才用自有 PTY。**借鉴：按用途分流的策略层**（读输出/注输入/感知生命周期走各自最优通道），而非统一抽象。
3. **kesslerio/xagent tmux SKILL**（https://github.com/kesslerio/xagent/blob/HEAD/workspace/skills/tmux/SKILL.md）：**独立 socket 文件**（`tmux -S /tmp/xxx.sock`）隔离 agent 世界与用户 tmux；completion 检测用 prompt 匹配（诚实承认是启发式）。

### control mode vs 轮询 capture（推 vs 拉）
| 维度 | control mode（`tmux -C`） | 轮询 capture-pane |
|---|---|---|
| 延迟 | 输出即推送，毫秒级 | 受轮询间隔限制 |
| 开销 | 一条长连接，零进程派生 | 每次 fork+exec，pane 多了线性放大 |
| 可靠性 | 不丢字节（`%pause`/`%continue` 背压）；`%output`/`%pane-died` 结构化 | 两次轮询之间只见终态；send-keys 后立刻 capture 是竞态 |
| 复杂度 | 要写行协议解析器 | subprocess 一把梭 |

**结论**：control mode 做事件总线（输出流+生命周期），capture-pane 做状态读取（快照+按需查询）。**control mode 告诉你"什么时候变了"，capture-pane 告诉你"现在长什么样"**。另有 demux 架构笔记论证"control mode 而非 hooks"（hook 每事件 fork 进程，做世界模型是错的）。

**头号坑**（libtmux-mcp gotchas）：`send-keys` 返回只表示"按键已接受"，不表示"命令已执行"；想知道命令跑完必须自己织入标记（`; tmux wait-for -S <channel>` 确定性同步）或 echo 唯一 marker。

### pane 捕获最佳实践
- **防撕裂**：capture-pane 抓的是实时可变网格；增量场景用"状态先行"（先读 `#{history_size}` 元信息再 capture，双读校验漂移）。
- **shell 回显污染**：marker 必须设计为命令不可能回显的形态（随机 token），或放输出侧；libtmux 官方 `run_and_capture` 示例曾因此永远"毫秒级成功"。
- **回滚截断**：scrollback 环形缓冲，游标落后于截断点时诚实报告 `missed=True` 并重建，不静默撒谎。
- **游标 = 绝对行号**：用 `#{history_size}` 锚定，做区间增量读（`capture-pane -S <start> -E <end>`），不对两次抓屏做文本 diff（清屏/重排会失效）。
- **寻址永远用 `%id`**：window 名/pane 索引会变，只有 `%` pane id 全局唯一（server 重启失效，快照不持久化它）。

### 快照恢复的诚实语义（tmux-resurrect/continuum 的确立边界）
- **能存**：session/window/pane 结构、名字、layout、cwd、回滚内容、注入的元数据（agent 类型、任务描述、agent 侧可恢复句柄如 Claude `--resume` id）。
- **恢复不了**：进程本身。resurrect 按白名单重跑程序；诚实语义 = "**重建现场 + 重放意图**"：重建同名同 cwd 同 layout 的 pane，执行启动命令，历史可查；进程内存/未落盘状态/子进程树一律不承诺。
- `remain-on-exit` 让 `has-session` 不再是存活测试——**存活判断必须读 `pane_dead`**（nightmachinery 实战：22/76 个 session 是"尸体"）。
- 两段式 kill 要杀**进程树**：`send-keys C-c`/SIGINT 前台进程组 → 超时 `kill-pane` → 按 `pane_pid` 查子孙无残留。

### libtmux 取舍（不用，但要懂）
libtmux（~1200 stars）：Server/Session/Window/Pane 四级对象封装。真正价值是 gotchas 文档（上千用户踩坑清单）+ `wait-for-text`/`capture-since` 等竞态安全原语。坑：对象即过期缓存（pane 重建后静默指错目标）；竞态只在文档里修（库层面无原语）；第三方依赖版本漂移。结论：自己维护薄而诚实的封装。

### 借鉴（5 条，可落地）
1. **独立 socket + 命名编码**：`tmux -S ~/.agent-sock/agent.sock`，session 名 `agent-<agent-id>`，cwd 绑定 git worktree；杜绝 kill-server 误伤与重名撞车。
2. **确定性命令同步原语**：`run(cmd, timeout)` = 注入 `cmd; tmux wait-for -S <uuid>` 并阻塞等 channel；prompt 嗅探只留作黑盒 CLI 的启发式补充。
3. **输出读取器 = 游标 + 绝对行号 + 丢行诚实报告**：`capture_since` API，`missed=True` 时重建游标。
4. **事件总线预留 control mode 插槽**：内部把"输出事件/生命周期事件"抽象成 `EventSource` 接口；首版低频轮询+确定性原语交付，不把轮询假设焊进调用方。
5. **快照存"恢复意图"**：`{cwd, layout, agent_type, launch_cmd, agent_session_handle, scrollback_path}`；文档明确列出不恢复的三样东西。

### 超越（3 条）
1. **从"猜进程"到"知进程"**：resurrect 靠进程名白名单猜；我们是 spawn 方，天然知道 agent 类型/启动命令/可恢复句柄，spawn 时写入快照元数据——恢复从启发式变确定性。
2. **带证据的 stall 检测**：control mode 事件 + 每 pane 输出游标 → "输出停滞 N 秒 + 进程存活 + 无输入消费 = 疑似 stall"，证据 = 最后输出时间戳、pending 输入字节数（`-P`），可解释。
3. **有审计的两段式终止**：`terminate(graceful_timeout)`：SIGINT 前台进程组并确认退出 → `kill-pane` + 进程树收尸 → 全程写事件日志（谁/何时/因何 kill、退出码）。"杀不干净的幽灵进程写坏下一个任务工作区"是最阴险的故障。

---

## 方向四：流水线编译（多轮转单轮 / workflow 编译 / LLM pipeline 优化）

### Durable Execution：Temporal / Cadence / Restate
| 系统 | 核心机制 |
|---|---|
| Temporal/Cadence | workflow 写成普通代码；状态变更以事件追加到 history；恢复时从头重放代码，已发生副作用用 history 值代替；强制分离：workflow 确定无副作用，副作用全关进 activity（要求幂等/不可重试） |
| Restate | 每个调用维护 journal；非确定操作经 `ctx.run` 等 context API 记入 journal；恢复跳过已完成步骤 |
| DBOS/Inngest | 按步骤记忆化，已完成步骤直接跳过 |

借鉴：**副作用与编排分离**（非确定点显式标记为步骤边界）；**恢复 = 跳过已完成步骤**（journal 最小语义：步骤输出落盘、命中即跳过）；**确定性约束前置**（编译期验证，而非运行时重放报错）。
局限：要常驻服务端/集群；重放依赖代码确定（LLM 输出天然非确定，模型错配）；恢复粒度是整个 workflow；烧录要零依赖单文件 + bundle 级断点续跑。

### 规划一次、执行多次
- **CI/DAG 编译**（GitHub Actions/Tekton/Argo）：`needs/dependencies` 建 DAG（解析期拓扑排序）+ `when/if` 分支正交；`outputs` 具名传值；`strategy.matrix` 编译期展开。LLM = "写 YAML 的 planner"，执行完全确定。
- **LangChain plan-and-execute / LangGraph**：planner → executor → replanner 循环；plan 是结构化数据；replan 输出受控枚举；`interrupt()` 在规划后挂审批点。
- **OpenAI 并行 function calling**：单轮多 tool_call 并行执行；`parallel_tool_calls` 控制；strict mode 约束解码保 schema。**依赖分析前置**：无依赖才能并行；**参数校验左移**。
- 局限：plan-and-execute 是运行时循环（每步调 LLM），与烧录"规划后零 LLM"目标相反；function calling 只压缩一轮，不管重试/超时/checkpoint。

### 纯 bash/DAG 编译最佳实践
| 机制 | 可靠做法 |
|---|---|
| 超时 | `timeout -k <kill> <secs> cmd`（TERM→KILL 两段，防吞 TERM 挂死） |
| 重试 | 只重试幂等操作；指数退避 + jitter；有界次数（3–5）+ 总预算；4xx 不重试 |
| checkpoint | 每步完成写标记文件；临时文件 + `mv` 原子改名；入口检查命中即跳过 |

**受限表达式求值**：CEL（google/cel-spec）是标准答案——非图灵完备（无循环/递归）、无副作用、强类型编译期检查、可嵌入（host 给白名单变量/函数）。Tekton `when.cel`、K8s admission、Envoy 同理。做法：**编译期 parse+check，求值只暴露白名单变量**；防注入靠"语言不可表达副作用"，不靠沙箱。

### 借鉴（5 条，可落地）
1. **编译期拍平 DAG**：解析 `needs/depends` 建图 → 拓扑排序 + 环检测；无依赖节点标可并行（bash `&`+`wait`）；无需运行时调度器。
2. **步骤级 checkpoint 文件协议**：`$CKPT_DIR/<step>.done` 原子 `mv` 写入；入口检查命中即跳过（journal 零依赖实现）。
3. **条件表达式用 CEL 子集**：编译期 parse + 类型检查 + 静态变量引用分析（未定义引用直接编译失败）；运行时只暴露白名单变量。
4. **超时/重试生成为模板函数**：`with_timeout`/`with_retry` 语义固定为 `timeout -k` + 指数退避 + 有界次数；策略不暴露给 LLM（防它"发明"重试逻辑）。
5. **非确定点显式标记**：LLM 调用/网络请求/时间戳声明为 `effect` 步骤；强制配 checkpoint + 幂等键（activity/`ctx.run` 的对应物）。

### 超越（3 条）
1. **零依赖**：Temporal/Restate/Argo 都要服务端或集群；烧录产物是单个自包含 bash，`bash bundle.sh` 即跑——"运行时"被整个编译掉。
2. **编译期确定性**：Temporal 把确定性检查留给运行时重放；我们把 DAG 无环、变量引用、类型、超时/重试策略全在编译期验证；编译通过 = 执行路径确定。
3. **可审计**：产物是人类可读 bash + 追加式文本日志；`diff` 两个 bundle 即见行为差异，不需要专用工具读二进制 history/etcd。

---

## 综合：SOTA 对我们设计决策的影响矩阵

| 我方决策 | SOTA 影响 | 动作 |
|---|---|---|
| sock 消息 JSON→XML（用户要求） | 与所有借鉴点正交（ACP/MCP/A2A 都是 JSON-RPC，但借鉴的是语义层：session 模型、类型化 update、capability 协商） | 语义照抄，序列化换 XML |
| 事件信封格式 | CloudEvents 1.0 兼容（零成本互操作） | 事件 JSONL 字段向 `id/source/type/specversion/time/subject/data` 对齐 |
| 订阅过滤 | NATS subject 通配（`*`/`>`）服务端过滤 | 补到 event.subscribe 的 filter 语义 |
| 订阅可靠性 | JetStream per-consumer cursor + 显式 ack | 补 `last_acked_seq` + AckWait 回投（本地 PEL） |
| 任务状态机 | ACP stopReason 枚举 | task.status 的 state 枚举扩展，失败原因进错误码 |
| 审批门 | ACP request_permission | 新增协议消息（见修订） |
| 服务发现 | A2A AgentCard | 新增 `agent/card` 保留方法 |
| tmux 输出读取 | control mode vs 轮询取舍 | EventSource 接口抽象，首版轮询+确定性原语，不焊死 |
| tmux 命令同步 | `tmux wait-for` 确定性原语 | 取代"send-keys+sleep+轮询 grep" |
| tmux 快照语义 | resurrect 诚实边界 | 快照存"恢复意图"，文档列不恢复三样 |
| pipeline 条件表达式 | CEL 子集 | 替代原"受限子集"模糊描述，编译期 parse+check |
| pipeline 非确定点 | Temporal activity/Restate ctx.run | DSL 新增 `effect` 步骤类型，强制 checkpoint+幂等键 |
| pipeline 并行 | OpenAI parallel_tool_calls 依赖分析 | 编译器做依赖分析，无依赖节点 `&`+`wait` |
| queue/topic 双语义 | JetStream Retention 三选一 | 同一 server 跑两种语义，`queue.declare` 指定（DESIGN §3.5.1） |
| 竞争消费 | NATS queue group / Redis XREADGROUP | consumer group + round-robin，at-least-once per group |
| 失败转移 | JetStream AckWait / Redis XAUTOCLAIM | AckWait 30s server 自动重投；PEL 落盘（`state.json`） |
| 死信 | JetStream MaxDeliver 转 subject / Redis 手动 | `queue.dead` + `*.failed` 血缘链，不另建存储 |
| 背压 | JetStream FlowControl | `max_depth`+overflow 三策略+组级 flow control |
| 保序 | 分区语义 | FIFO + `partition_key` sticky，rebalance 乱序诚实声明 |

---

*调研基线：2026-10。四路子报告：协议（MCP/ACP/A2A 官方 spec+源码）、事件（NATS JetStream/Redis Streams/CloudEvents）、tmux（superharness/tmux-router/xagent/control mode）、流水线（Temporal/Restate/CI DAG/LangGraph/CEL/bash 最佳实践）。*
