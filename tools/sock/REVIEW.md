# DESIGN.md v3 — 对抗式审核

> 审核对象：`DESIGN.md` v3（2026-10-10）。立场：红队。目标：找漏洞、矛盾、边界缺失、过度简化风险。

## 0. 术语

| 术语 | 定义 |
|------|------|
| 致命 | 破坏正确性保证或引入安全漏洞 |
| 严重 | 造成功能缺失、性能悬崖或高实现风险 |
| 一般 | 歧义或细节缺失，不阻塞但应修复 |
| 流水线 | 客户端连续发送多个请求、不等待应答 |

## 1. 问题总览

| 编号 | 级别 | 位置 | 一句话 |
|------|------|------|--------|
| R-01 | 致命 | §2.3 | 累计 ack 无法在流水线下关联请求与应答 |
| R-02 | 致命 | §2.6 | 空组拒绝 publish，worker 全灭时任务无法排队 |
| R-03 | 致命 | §2.1 | CDATA 未转义 `]]>`，存在 XML 注入面 |
| R-04 | 致命 | §2.1 | 无最大帧限制，长度前缀可触发 OOM |
| R-05 | 致命 | §2.5/§3.1 | 已取消的排队任务仍会被投递执行 |
| R-06 | 严重 | §2.1/§2.5 | 线程模型自相矛盾，跨线程写未设计同步 |
| R-07 | 严重 | §3.1 | 每次投递/ack 后刷盘，吞吐被磁盘锁死 |
| R-08 | 严重 | §2.3 | 无取消订阅原语，退订需断开整个连接 |
| R-09 | 严重 | §2.4 | 收件箱的消费者组名未定义，多会话下控制消息丢失 |
| R-10 | 严重 | §2.4 | 动态 stream 队列无生命周期，资源泄漏 |
| R-11 | 严重 | §2.3 | topic 下 ack_wait_s/max_deliver 语义未定义 |
| R-12 | 严重 | §3.1 | 单个停滞订阅者永久阻塞 compaction |
| R-13 | 严重 | §2.1 | 拒绝 DOCTYPE 防不住 XML 二次展开与深度递归 |
| R-14 | 严重 | §2.1 | dispatcher 跨线程写消费者 socket，两次 send 可交错 |
| R-15 | 一般 | §6.3 | `error.raised{classification}` 格式未定义 |
| R-16 | 一般 | §2.6 | drop_oldest 的计数事件无对应 subject |
| R-17 | 一般 | §2.3 | queue.declare 参数冲突时的行为未定义 |
| R-18 | 一般 | §2.3 | 新消费者组是自动创建还是报错，未定义 |
| R-19 | 一般 | §2.7 | agent 被标 lost 后收不到通知，重连语义不明 |
| R-20 | 一般 | §2.4 | 审批走队列给本地操作增加三段延迟 |
| R-21 | 一般 | §3.2 | stalled 事件无消费方，杀策略未接线 |
| R-22 | 一般 | §2.1 | SO_PEERCRED 仅 Linux，平台支持未声明 |
| R-23 | 一般 | §2.7 | 保留 1000 条 chunk 无字节上限，内存无界 |
| R-24 | 一般 | §2.2/§2.3 | since 依赖发送方时钟，时钟偏移导致漏消息 |
| R-25 | 一般 | §2.5 | "单一写者"表述不准确，实际是每任务两写者 |

## 2. 致命问题

### R-01 请求/应答关联在流水线下失效

- 位置：§2.3
- 描述：设计用累计 ack 关联应答与请求。累计 ack 只表示"已收到的对方最大 seq"，不标识本应答对应哪个请求。
- 反例：client 发送 register(seq=1) 后立即发送 card(seq=2)。server 先回 card 应答，ack=2。client 收到 type=card、ack=2 的消息，无法判断它对应 seq=1 还是 seq=2。client 按序等待 register 应答时，会误判或永久等待。
- 修复：增加 `in_reply_to` 属性，取值为原请求 seq。ack 只做传输确认，不做请求关联。

### R-02 空消费者组拒绝 publish 破坏可用性

- 位置：§2.6
- 描述：workqueue 无成员时 publish 返回 AEVT-4005。worker 全灭时任务连排队都排不上。
- 反例：凌晨 worker 进程 OOM 全灭。orchestrator 提交早间批处理任务，全部被拒。9 点重启 worker 后，3–9 点的任务已丢失。
- 修复：空组时 publish 正常入队，worker 加入后消费。AEVT-4005 改为可选告警事件，不阻塞 publish。

### R-03 CDATA 未处理 `]]>` 转义

- 位置：§2.1
- 描述：设计要求"自由文本用 CDATA 包裹"，但未规定 `]]>` 的转义。bash 脚本含 `]]>` 时提前闭合 CDATA，后续内容被解析为 XML。
- 攻击场景：任务脚本由 LLM 生成，内容不可控。脚本含 `]]>` 后跟伪造的 `<queue><publish>` 帧，server 按伪造帧投递任务。
- 修复：发送方将 `]]>` 转义为 `]]]]><![CDATA[>`。proto.py 单元测试覆盖。

### R-04 无最大帧限制

- 位置：§2.1
- 描述：成帧为 4 字节长度前缀，但未定义最大帧长。server 按长度前缀分配缓冲区。
- 攻击场景：本地进程发送长度前缀 0xFFFFFFFF，server 尝试分配 4GB 内存，触发 OOM。
- 修复：定义 `max_frame_bytes`（建议 16MB），超限断开连接并记事件。`queue.publish` 另设 `max_payload_bytes`（建议 8MB），超限回 error。

### R-05 已取消的排队任务仍会被投递

- 位置：§2.5、§3.1
- 描述：状态机允许 queued → cancelled，但队列日志 append-only，无删除机制。设计未定义取消排队任务时 server 是否过滤。
- 反例：orchestrator 提交 `rm -rf /srv/app/cache` 后立即取消。任务仍在 log.jsonl 中。worker 上线后收到投递并执行。状态机承诺的 cancelled 终态被违反。
- 修复：server 维护 cancelled 任务集合，投递前过滤。TLA+ 增加 Cancel 动作，验证"已取消不投递"。

## 3. 严重问题

### R-06 线程模型自相矛盾

- 位置：§2.1、§2.5
- 描述：§2.1 规定"server 每连接一线程"，§2.5 规定"server 单线程投递"。dispatcher 向其他线程的连接写 socket，同步机制未设计。
- 反例：dispatcher 线程向 consumer A 的 socket 写 deliver，同时该连接的读线程在处理 ack。两次 send（长度前缀 + XML）之间被其他线程插入，帧错乱。
- 修复：二选一：dispatcher 独占所有 socket 写（每连接配写队列），或单线程 asyncio 事件循环替代 thread-per-connection。

### R-07 state.json 每次投递/ack 后刷盘

- 位置：§3.1
- 描述："投递/ack 后刷盘"意味着每条消息 2 次 fsync。SATA SSD 的 fsync 约 0.1–1ms，吞吐上限约 500–5000 msg/s。
- 反例：100 个 agent 每秒各产生 10 条 stream chunk，1000 msg/s × 2 fsync = 2000 fsync/s。磁盘打满，投递延迟飙升，heartbeat 超时误判 lost。
- 修复：WAL 批量刷盘（每 10ms 或每 100 条）。文档明确批量窗口与 crash 时的数据丢失边界。

### R-08 无取消订阅原语

- 位置：§2.3
- 描述：10 个原语中无 unsubscribe。§3.3 暗示断开连接即退订。
- 反例：watcher 长连接订阅 `events` 和 50 个 `stream.<task_id>`。任务完成后想退订单个 stream，必须断开整个连接重建，重发所有 consume 并触发 catch-up 风暴。
- 修复：增加 `queue.unconsume` 原语。

### R-09 收件箱的消费者组约定缺失

- 位置：§2.4
- 描述：收件箱定义为"单消费者工作队列"，但 workqueue 的 consume 必须带 group。agent 消费自己收件箱时 group 填什么，文档未定义。
- 反例：agent-7 的主进程和调试 client 同时 consume 同一收件箱，group 不同。orchestrator 发 cancel，只投递给其中一个组。另一个收不到 cancel，任务继续跑。
- 修复：规定收件箱的 group 固定为 `inbox`，server 拒绝其他 group 订阅收件箱。

### R-10 动态 stream 队列无生命周期管理

- 位置：§2.4
- 描述：`stream.<task_id>` 按任务动态创建，但由谁 declare、何时删除，文档未定义。
- 反例：运行一年后 `queues/` 下有 100 万个 `stream.*` 目录。无人订阅的 stream 队列永不 compaction，磁盘耗尽。
- 修复：server 在任务创建时隐式声明 stream 队列，任务终态后保留 1 小时供 catch-up，随后自动删除。

### R-11 topic 消费的参数语义未定义

- 位置：§2.3
- 描述：`queue.consume` 的 `ack_wait_s`/`max_deliver` 在 topic 语义下无意义。文档只规定"topic 禁止带 group"，未规定其他参数。
- 反例：client 对 `events` 发送带 `ack_wait_s=30` 的 consume。实现 A 忽略，实现 B 报错。两种实现互不兼容。
- 修复：topic 下 `ack_wait_s`/`max_deliver` 必须缺省，携带则回参数错误。文档写死。

### R-12 慢订阅者永久阻塞 compaction

- 位置：§3.1
- 描述：compaction 条件是"所有 group 的 cursor 超过 N"。单个停滞订阅者使 N 无法推进。
- 反例：watcher 订阅 `events` 后进程假死。`events.jsonl` 无限增长，100MB×10 段的 retention 被击穿。
- 修复：compaction 增加时间上限（如 7 天），超时强制推进并记事件。或对 stalled 订阅者自动退订。

### R-13 XML 解析的 DoS 面未覆盖全

- 位置：§2.1
- 描述："拒绝 DOCTYPE" 防住 billion laughs，但防不住二次展开（深层嵌套）与深度递归。
- 反例：10KB 的 10 万层嵌套 `<a>` 使 ElementTree 递归解析栈溢出，server 线程崩溃。
- 修复：约束最大嵌套深度（如 32）与最大元素数。文档明确约束值。

### R-14 dispatcher 跨线程写消费者 socket

- 位置：§2.1
- 描述：server 主动 `queue.deliver` 需向消费者连接写数据。thread-per-connection 下写操作跨线程。
- 反例：同 R-06。Python 的 `socket.send` 单次调用线程安全，但"长度前缀 + XML"分两次 send，中间可被插入。
- 修复：与 R-06 一并解决。每连接写加锁，或集中由 dispatcher 写。

## 4. 一般问题

### R-15 `error.raised{classification}` 格式未定义

- 位置：§6.3
- 描述：分类结果"写事件 error.raised{classification}"，但 classification 取值与拼写未定义。
- 修复：subject 固定为 `error.raised`，classification 进事件 data 字段。

### R-16 drop_oldest 的计数事件未定义

- 位置：§2.6
- 描述："挤掉最旧未消费 + 计数事件"，但 §2.5 事件表无对应 subject。
- 修复：增加 `queue.dropped` 事件（`{queue, count, reason}`）。

### R-17 queue.declare 参数冲突行为未定义

- 位置：§2.3
- 描述：重复 declare 同一队列但 semantics/max_depth 不同时，server 行为未定义。
- 修复：参数一致则幂等成功，不一致回错误（新增 AEVT-4007）。

### R-18 消费者组隐式创建未定义

- 位置：§2.3
- 描述：consume 携带新 group 名时，组自动创建还是报错，未定义。
- 修复：workqueue 的 group 在首次 consume 时自动创建。文档明确。

### R-19 agent 被标 lost 后无通知

- 位置：§2.7
- 描述：server 60s 无心跳标 lost，但 agent 端无通知。网络分区恢复后，会话是恢复还是新建，未定义。
- 修复：重连 register(resume=true) 时 server 回复会话状态。已被标 lost 则回特定错误码，client 重建状态。

### R-20 审批走队列增加本地延迟

- 位置：§2.4
- 描述：`approval.requests` 的消费者是 server 自己。server 内部审批本可函数调用，走队列增加序列化、落盘、投递三段延迟。
- 修复：文档承认这是为统一性付出的代价。或 server 内走快路径，队列只记审计事件。

### R-21 stalled 信号无消费方

- 位置：§3.2
- 描述：慢消费者标 stalled 并发事件，但"杀是编排器的决策"。编排器如何订阅、多久后杀，未定义。
- 修复：定义默认策略（如 stalled 持续 5 分钟且 pending 超限，server 停止向该消费者投递）。

### R-22 平台支持未声明

- 位置：§2.1
- 描述：`SO_PEERCRED` 仅 Linux 可用。macOS/BSD 的替代方案未定义。
- 修复：声明首版仅支持 Linux，或定义 macOS 降级方案（`LOCAL_PEERCRED`）。

### R-23 stream chunk 保留无字节上限

- 位置：§2.7
- 描述："保留每个 agent 最近 1000 条 stream chunk"，chunk 大小无上限。1000 条 × 1MB = 1GB/agent。
- 修复：按字节封顶（如 10MB/agent），超限丢弃最旧并记事件。

### R-24 since 依赖发送方时钟

- 位置：§2.2、§2.3
- 描述：`ts` 是发送方本地时钟，`since` 按 ts 做 catch-up。时钟差 5 分钟时漏消息或重放大量历史。
- 修复：`since` 改用 server 分配的 seq，不用 ts。或要求 NTP 同步并定义最大容忍偏移。

### R-25 "单一写者"表述不准确

- 位置：§2.5
- 描述：文档称"状态事件由单一写者发布"，但括号内写"queued 由 server，其余由执行 agent"。实际是每任务两写者。
- 修复：改为"每任务两写者，因果有序：queued 先于 started，server 单线程投递保证订阅者看到因果序"。

## 5. §9 待拍板项裁决

6 项全部可定，无需用户拍板：

| # | 事项 | 裁决 |
|---|------|------|
| 1 | retention 100MB×10 | 接受为缺省值，改为可配置项 |
| 2 | pipeline 默认目标 | 选 A（bash）。烧录的卖点是零依赖单文件 |
| 3 | pane 捕获轮询/hook | 首版轮询，EventSource 接口已预留 hook 插槽 |
| 4 | Web dashboard | 移出 v1 范围 |
| 5 | 包名 | `agent_sock`（PEP8 可 import 名），CLI 保持 `asock` |
| 6 | 队列满默认策略 | 按队列区分：`task.dispatch` 用 block，`events` 用 drop_oldest。declare 时必填，无全局缺省 |

## 6. 统计

- 致命：5（R-01–R-05）
- 严重：9（R-06–R-14）
- 一般：11（R-15–R-25）
- 合计：25
