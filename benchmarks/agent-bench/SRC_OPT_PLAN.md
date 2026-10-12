# fx src 端到端优化计划（v2）

> 分支：`bench/speed-opt`。基准：E2E_ANALYSIS.md（TTFT 占 80–89%，模型 API 占 91–99%）。
> 工具链：Zig 0.16.0（`~/workspace/agent-sock/zig/toolchain/zig`）。全量构建 ~67s，单文件增量 ~51s。
>
> v2 修订（2026-10-11）：删掉 `tool_choice: required`（hack，逻辑错误）；
> 新增二八分析；确认轮消除升为 P1。

## 0. 构建与验证基线

| 项目 | 结论 |
|---|---|
| Zig 版本 | 必须 0.16.0。0.17.0 不兼容（`build.zig:64` 用 `.Debug`，0.17 已改名）。 |
| 全量构建 | ~67s（`zig build`，Debug，216MB 二进制） |
| 增量构建 | ~51s（单文件改动）。可用，无需 ccache。 |
| 测试 | `zig build test` 必须过。每个优化独立 commit。 |
| 验证 | agent-bench 跑 before/after（`./run.sh`），无数字不合。 |

---

## 1. 二八分析：真正的 80/20 是模型调用次数

### 1.1 关键洞察

TTFT 占 87% 是事实，但 TTFT 是 provider 的推理时间，fx 改不了。
fx 能动的只有一个杠杆：**模型调用次数**。每次调用固定成本 1×TTFT。

```
wall ≈ N_calls × TTFT + N_calls × TPOT×tokens + fx_overhead(~30ms)
```

`fx_overhead` 恒定可忽略。TPOT×tokens 由任务决定，难压缩。
**唯一大头：N_calls。减一次调用 = 省一个 TTFT。**

### 1.2 候选优化按预期收益排序（slow/T1，wall 4581ms）

| 排名 | 优化 | 机制 | 预期节省 | 占 wall | 状态 |
|---|---|---|---|---|---|
| 1 | 确认轮消除 | 干掉纯确认轮，2→1 round | ~2000ms | **44%** | P1，本计划核心 |
| 2 | Prefix caching | round 2+ 的 TTFT −80% | ~1600ms* | 35%* | P2，provider 依赖 |
| 3 | 工具 schema 瘦身 | prefill token −50% → TTFT −15% | ~300ms | 7% | P3 |
| — | 首轮集中度 | 防劣化，不直接省 | 0ms（已 100%） | 0% | 护栏指标，非 P 项 |
| ✂️ | 流式重叠 | <30ms | <1% | <1% | 砍掉 |
| ✂️ | fx 自身 30ms | — | — | <1% | 砍掉 |
| ✂️ | `tool_choice: required` | 逻辑错误 | — | — | 删掉 |

*Prefix caching 的 35% 是 T5/T6 类多 round 任务的值；T1–T4 在确认轮消除后只剩 1 round，无 round 2 可优化。

**Top 3：确认轮消除、Prefix caching、Schema 瘦身。**
**砍掉：**流式重叠（<1%）、fx 开销（<1%）、`tool_choice: required`（错误方案）。

### 1.3 为什么确认轮是最大头

6 个 benchmark 任务的剧本（`replay/t*-pro.json`）揭示：

| 任务 | Round 1 | Round 2 | Round 3 | 末轮性质 |
|---|---|---|---|---|
| T1 | write_file | stop（"Done"） | — | 纯确认，零信息 |
| T2 | edit_file | stop | — | 纯确认，零信息 |
| T3 | write_file | stop | — | 纯确认，零信息 |
| T4 | 3×write_file | stop | — | 纯确认，零信息 |
| T5 | read_file | write_file | stop | 纯确认，零信息 |
| T6 | shell | write_file | stop | 纯确认，零信息 |

**6/6 任务的末轮都是纯确认**：`finish=stop`，无 tool_calls，只有 "Done" 类文本。
在 `fx ask --json` 模式下，该文本不被任何下游消费（harness 只读 `steps`/`tool_calls`，成功由文件断言判定）。

每任务省 1 个 TTFT：
- slow：−2000ms（−44%）
- pro：−800ms（−44%）
- flash：−200ms（−40%）

这是单点最大收益，无其他优化可比。

---

## 2. P1：确认轮消除

### 2.1 技术可行性

**核心问题**：orchestrator 如何在不问模型的情况下判定 turn 完成？

Round 触发逻辑（`src/core/shared/types.zig:1917` `classifyProviderCompletion`）：
- `.tool_calls` + 有 tool_calls → 执行工具 → **新一轮 LLM 调用**
- `.stop` + 无 tool_calls → turn 结束

当前：工具执行完 → 无条件新一轮 → 模型看结果 → 决定 stop 或继续。

**判定规则**（工具结果驱动）：

```
after_tool_execution(tool_results):
  if any tool FAILED → 必须问模型（需要决定重试/放弃）
  else if any tool 返回了决策相关内容（read_file 内容、shell stdout/stderr）→ 必须问模型
  else → 所有工具成功且无决策相关输出 → 跳过确认轮，直接结束 turn
```

**为什么这个规则是 sound 的**：
- 模型在上一轮已经做了全部决策（发了哪些 tool_call）。
- 工具成功执行且无新信息 → 模型在确认轮中没有任何新输入，它只能重复已知信息说 "Done"。
- 确认轮的输出是输入的纯函数（无新信息 → 无新决策），因此可跳过。

**为什么这个规则是 complete 的**（不会误杀必要轮次）：
- 工具失败 → 模型必须看到错误才能决定 → 保留轮次 ✓
- 工具返回内容（read/shell 输出）→ 模型需要内容做下一步决策 → 保留轮次 ✓
- T5（read→write）：R1 read 返回内容 → 保留 R2。R2 write 成功无内容 → 跳过 R3 ✓
- T6（shell→write）：R1 shell 返回 stdout → 保留 R2。R2 write 成功 → 跳过 R3 ✓

### 2.2 什么情况下不能省

| 场景 | 能否省 | 原因 |
|---|---|---|
| `fx ask --json`（非交互） | ✅ 能省 | 确认文本无消费者 |
| `fx ask`（文本输出，非交互） | ⚠️ 可选 | 用户可能想看总结；加 flag 控制 |
| 交互式 shell | ❌ 不能省 | 用户期望看到模型收尾 |
| 工具失败 | ❌ 不能省 | 模型需决定重试/放弃 |
| 工具返回决策相关内容 | ❌ 不能省 | 模型需基于内容决策 |

**实现策略**：只在 `fx ask` 非交互模式下启用（`cli_ask.zig` 的执行路径），交互式 shell 不动。
这是行为变更，但限定在 programmatic 场景，风险可控。

### 2.3 实现位置

| 改动 | 文件 | 说明 |
|---|---|---|
| 工具结果分类：`has_decision_relevant_output()` | `src/core/agent/runtime/orchestrator.zig` | 判断工具结果是否含模型决策所需信息：tool 失败、返回非空 content/stdout |
| 跳过确认轮的分支 | `src/core/agent/runtime/orchestrator.zig`（`agent_steps_loop` 工具执行后） | 若无决策相关输出且为 `ask` 模式，直接走 turn 完成路径，不发起新一轮 LLM 调用 |
| 模式开关 | `src/core/cli/cli_ask.zig` | 非交互 `ask` 默认启用；预留 `--no-skip-confirm` 回退 flag |

行数估：~40 行（含测试）。

### 2.4 风险与回滚

- **风险 1**：模型本想在确认轮做更多事（如写完 A 后想起还要写 B）。
  缓解：这是模型规划质量问题。首轮集中度（§3）要求模型一次性发出所有独立 tool_call。
  实测 T4 已证明模型能一次发 3 个。
- **风险 2**：`--json` 输出的 `steps` 缺少最后的文本步骤，下游解析器若依赖它会坏。
  缓解：harness 已验证只读 `steps[].name`/`tool_calls`，不读末轮文本。先跑 benchmark 验证。
- **回滚**：删分支，恢复无条件新一轮。一行开关。

### 2.5 验证

- agent-bench T1–T6 × 4 profile：`llm_rounds` 每任务 −1，`wall_ms` 下降 33–44%，`success` 不变。
- `zig build test` 通过。
- 边界 case：故意让工具失败，确认轮次保留（模型能看到错误）。

### 2.6 预期收益总表

| 任务 | 当前 rounds | 优化后 rounds | slow 节省 | pro 节省 |
|---|---|---|---|---|
| T1 | 2 | 1 | −2000ms（−44%） | −800ms（−44%） |
| T2 | 2 | 1 | −2000ms（−44%） | −800ms（−44%） |
| T3 | 2 | 1 | −2000ms（−44%） | −800ms（−44%） |
| T4 | 2 | 1 | −2000ms（−44%） | −800ms（−44%） |
| T5 | 3 | 2 | −2000ms（−33%） | −800ms（−33%） |
| T6 | 3 | 2 | −2000ms（−33%） | −800ms（−33%） |

---

## 3. 首轮集中度（替代 `tool_choice: required`）

### 3.1 为什么删掉 `tool_choice: required`

用户指出其逻辑错误：
- `required` 假设任务一定需要工具调用。
- 若任务可直接文本回答（如"解释这段代码"），强制工具调用反而增加 round（模型硬凑一个无意义的 tool_call，或空转）。
- 这是 benchmark 场景的 hack，不是通用优化。

**删掉，不做。**

### 3.2 替代方案：首轮集中度

**定义**：`首轮集中度 = （第 1 轮发出的 tool_call 数）/（总 tool_call 数）`

**机制**：prompt 工程。在 system prompt 的工具调用说明段加一句：
独立工具一次返回，不要分轮；不需要工具时直接文本回答。

| 改动 | 文件 | 行数估 |
|---|---|---|
| prompt 加并行指令文案 | `src/acp/prompt.zig` | ~5 行（文案） |

**当前值**（benchmark 实测）：T1–T4 已 100%，T5/T6 有真依赖无法并行。
因此这是**护栏指标**（防回归），不是优化项：
- 若未来模型退化（如把 T4 的 3 个 write_file 拆成 3 轮），集中度下降即告警。
- agent-bench 的 summary 表加 `first_round_concentration` 列，持续监控。

**不进入 P 阶段**，作为 prompt hygiene 一次性落地。

---

## 4. P2：Prefix Caching（降 TTFT）

### 4.1 背景

Prefix 模拟数据（`E2E_ANALYSIS.md §6`）：90% 命中时 round2 TTFT 1366ms → 146ms。
确认轮消除后，T5/T6 仍有 2 rounds，round 2 的 TTFT 可用 prefix caching 压缩。

### 4.2 子项

| 子项 | 改动 | 文件 | 行数估 |
|---|---|---|---|
| 2a. 前缀稳定性审计 | 检查 `stable_prefix` 与 `ephemeral_overlay`（`prompt_context.zig:205`）哪些字段每轮变化；输出审计报告 | 只读分析 | 0 行（先审计） |
| 2b. 缓存透传 | 若 provider 支持（如 Anthropic `cache_control`），fx 侧传透；保证 `stable_prefix` 字节稳定 | `src/gateway/chat_completions_protocol.zig` | ~30 行（审计后定） |

### 4.3 预期收益

- T5/T6 的 round 2 TTFT −80%（若 provider 支持且前缀稳定）。
- T1–T4（确认轮消除后只剩 1 round）：无收益。诚实标注。

### 4.4 风险与回滚

- 只加透传/保证稳定性，不改变语义，低风险。
- 回滚：删透传代码。

---

## 5. P3：工具 Schema 瘦身（降 TTFT）

### 5.1 现状

请求体 27KB / ~6700 tokens（实测）。构成（`build_request`，`src/gateway/chat_completions_protocol.zig:395`）：
1. `instructions`：system prompt
2. `tools`：全部工具的完整 JSON schema
3. `messages`：历史（随 round 增长）

### 5.2 方案

`select_functions`（`src/gateway/chat_completions_protocol.zig:100`）按任务裁剪：
只传本轮可能用的工具。先做静态裁剪（`fx ask` 场景常用工具白名单），再考虑动态。

| 改动 | 文件 | 行数估 |
|---|---|---|
| 工具白名单裁剪 | `src/gateway/chat_completions_protocol.zig` | ~40 行 |
| system prompt 去重（检查 `stable_prefix` vs `ephemeral_overlay` 冗余） | `src/acp/prompt.zig` | 文案级 |

### 5.3 预期收益

- 工具 schema 若占 10KB，砍半 → prefill −50% → TTFT −15%（按 prefill 线性）。
- 这是对**剩余** round 的优化，与 P1/P2 正交叠加。

### 5.4 风险与回滚

- 裁掉模型实际需要的工具 → 任务失败。回滚：恢复全量。缓解：benchmark 先测。
- `success` 下降即回滚。

---

## 6. 实施顺序与里程碑

| 阶段 | 内容 | 预期 wall 收益（slow） | 验证门 |
|---|---|---|---|
| P0 | 基线锁定：当前 `bench/speed-opt` 跑 3 轮存档 | — | 数据存档 |
| P1 | 确认轮消除（§2） | T1–T4 −44%，T5–T6 −33% | rounds −1，success 不变 |
| P2 | Prefix caching 审计+透传（§4） | T5/T6 round2 TTFT −80% | ttftc_ms 下降 |
| P3 | Schema 瘦身 + prompt 去重（§5） | TTFT −15% | 请求体字节数下降 |
| — | 首轮集中度（§3） | 护栏，无直接收益 | summary 表加列 |

每个阶段独立 commit，agent-bench 验证后才进下一阶段。
任一阶段 `success` 下降即回滚该阶段。

**累计预期**（slow/T1）：P1（−44%）→ P3（−15% TTFT on 剩余 1 round）→ 总计约 −50%。

## 7. 不做清单

- `tool_choice: required`：逻辑错误，已删。
- 流式重叠：<1% 收益，砍掉。
- fx 自身 30ms 开销：<1%，不碰。
- 交互式 shell 的确认轮：用户期望看到总结，不动。只改 `fx ask` 非交互路径。
- 主从/多机：单机场景不需要。
