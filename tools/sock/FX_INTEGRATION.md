# FX Integration — agent-sock 接入 fx

> 状态：设计文档。agent-sock Zig 实现在 `zig/`（proto/server/client 已跑通 demo）。

## 1. 接入形式

| 方案 | 说明 | 结论 |
|------|------|------|
| A. 独立进程 + Unix socket | asock-server 独立跑，fx 链接 client.zig | **MVP 选这个**。零侵入 fx 构建 |
| B. 编译进 fx 二进制 | agent-sock 做 Zig module，`build.zig` 加依赖 | 二期。fx 的 build.zig 复杂，先验证协议再谈合入 |
| C. libfx 扩展 | sdk/node.js 暴露 queue/eventbus API | 三期。给外部编排器用 |

MVP 不改 fx 一行代码。fx 以外部进程身份当 agent-sock 的 client。

## 2. 功能映射

| agent-sock 能力 | fx 对应点 | 用法 |
|----------------|-----------|------|
| `task.dispatch` workqueue | `src/core/subagent/tool_host.zig` `Runtime.create` | 子任务不走进程内 spawn，改走队列分发。多机多 fx 实例共享任务池 |
| `events` topic | `src/core/agent/runtime/journal.zig`、`src/acp/libfx_journal.zig` | journal 事件镜像到 events。外部 watcher 订阅 `task.*`、`token.usage` 做监控 |
| `stream.<task_id>` topic | worker_runtime 的流式输出 | agent 的 stdout/tool_call 走 stream 队列，`fx` 主进程订阅聚合 |
| `agent.<id>.inbox` | ACP server (`src/acp/server.zig`) 的 session | 点对点控制：cancel/interrupt 发往目标 agent 收件箱 |
| tmux 封装 | 多 agent 并行 | 每个 fx agent 独立 tmux session（`asock-<agent_id>`），`tile` 一键排布 |

## 3. MVP：两个 fx 实例经 agent-sock 交换任务

```
asock-server (unix: .agent-sock/agent.sock)
    |
    +-- fx-A (orchestrator) : fx ask "把 deploy-check 拆成 3 个子任务" 
    |       -> publish task.dispatch {task-001, task-002, task-003}
    |
    +-- fx-B (worker) : 循环 consume task.dispatch/group=workers
            -> 收到 task-001 -> 执行 `fx ask --auto <spec>` -> ack
            -> stream 输出 -> publish stream.task-001
```

fx-B 是薄 wrapper（~100 行 Zig 或 shell）：

```bash
while true; do
  # consume 阻塞等任务（MVP 用轮询）
  task=$(asock-cli consume task.dispatch --group workers --timeout 30)
  [ -z "$task" ] && continue
  fx ask --auto --json "$task" 2>&1 | asock-cli stream-publish "$task_id" &
  wait $!
  asock-cli ack task.dispatch --group workers --delivery-id "$dlv"
done
```

asock-cli 是 client.zig 的 CLI 薄封装（待实现，~200 行）。

## 4. 与 fx 现有机制的关系

- **不替换** ACP（编辑器协议）和 subagent 进程内 spawn。agent-sock 是跨进程/跨机的任务总线，补的是 fx 没有的多实例协同。
- **journal 复用**：fx 已有 journal 事件流，asock 的 events 主题是它的跨进程投影，不是另起一套。
- **权限**：fx 的 permission 系统（`src/core/permissions/`）不动。agent-sock 只传任务规格，执行侧的审批仍走 fx。

## 5. 实施顺序

1. asock-cli（consume/publish/ack/stream 的 CLI）— 解锁 shell 集成
2. fx-worker.sh（上面的循环）— MVP 跑通
3. journal → events 镜像（读 fx 的 journal，publish 到 events）
4. 二期：Zig module 合入 fx build，二进制内置 client
