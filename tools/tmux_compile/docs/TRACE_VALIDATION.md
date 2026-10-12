# TRACE_VALIDATION.md — 真实 Trace 联合验证

> 数据集：[harvardMadsys/freeinference_agentic_trace](https://huggingface.co/datasets/harvardMadsys/freeinference_agentic_trace)（Nixon et al. 2026, CC BY 4.0）
> 窗口：2026-08-30 ~ 2026-09-05（1 周）
> 规模：2,047 sessions / 190,544 requests / 196,975 tool calls
> 限制：无消息文本（隐私），仅结构分析。arguments 中的路径/代码已脱敏为 `<path>`/`<code>`。

---

## 1. TTFT 验证：我们的假设偏乐观

sim-server 假设 vs 真实：

| 档位 | sim-server 假设 | 真实最接近的模型 | 真实 p50 | 偏差 |
|------|---------------|----------------|---------|------|
| flash | ~200ms | qwen3.6-35b | 504ms | **2.5×** |
| flash | ~200ms | deepseek-v4-flash | 807ms | **4×** |
| pro | ~800ms | deepseek-v4-flash | 807ms | ≈准 |
| slow | ~2000ms | minimax-m3 | 2788ms | 1.4× |

**模型 TTFT 全表**（p50 / p90）：

| model | n | p50 | p90 |
|-------|---|-----|-----|
| deepseek-v4-flash | 109,097 | 807 | 2,215 |
| glm-5.3-flash | 51,201 | 5,727 | 14,573 |
| minimax-m3 | 11,641 | 2,788 | 6,288 |
| glm-5.2 | 9,094 | 4,448 | 10,227 |
| glm-5.3 | 6,552 | 4,421 | 10,008 |
| qwen3.6-35b | 2,412 | 504 | 1,359 |

**结论**：
1. "flash" 是营销词不是性能保证——glm-5.3-flash 的 p50（5.7s）比 deepseek-v4-flash（0.8s）慢 7 倍。
2. 我们的 flash 假设（200ms）比最快的真实 flash 模型还要快 2.5–4 倍。**PERFORMANCE.md 的加速比是在偏乐观的 TTFT 假设下算的**，真实加速比会更小。
3. 我们的 pro 假设（800ms）恰好撞上 deepseek-v4-flash 的 p50——这是生产环境最主流的模型（109k requests，占 57%）。

**Harness TTFT**（p50）：pi 1467ms / hermes 1180ms / opencode 1756ms / kilo 4414ms——harness 本身也引入延迟。

---

## 2. Session 结构：真实世界比 benchmark 长得多

| 指标 | agent-bench 假设 | 真实 trace |
|------|----------------|-----------|
| requests/session p50 | 1–3 | **35** |
| requests/session p90 | — | **218** |
| requests/session avg | — | **93.1** |
| ≤2 轮 session 占比 | P1 主战场 | **1.6%**（32/2047） |
| tool_calls/request p50 | 1 | **1** ✅ |

**轮数直方图**：

| 轮数 | sessions |
|------|---------|
| 1 | 6 |
| 2 | 26 |
| 3–5 | 128 |
| 6–10 | 251 |
| 11–20 | 317 |
| 20+ | 1319（64%）|

**对 P1 的影响**：P1（确认轮消除，2→1 轮）只覆盖 1.6% 的 session。真实瓶颈是 35 轮中位数里的每一轮 TTFT，不是确认轮。P1 的方向没错，但覆盖面比预期小一个数量级。

**对 tmux_compile 的影响**：64% 的 session 超过 20 轮——"编译式 pipeline"的价值比 benchmark 显示的更大。每省一轮 TTFT，35 轮就是 35 倍。

---

## 3. Prefix Caching：生产环境标配

- **97.1%** 的 requests 有 cache_read_tokens > 0
- p50 cache tokens = **166,400**（整个上下文几乎全缓存）
- 几乎全部 stream=True（190,379/190,544）

**结论**：P2（prefix caching 零代码改动）的判断正确——生产环境本来就这么用。sim-server 的 cached profile（95% 命中）反而偏保守。

---

## 4. Prompt 大小：真实比我们假设的大

| 指标 | 我们的假设 | 真实 p50 | 真实 p90 |
|------|-----------|---------|---------|
| tool_definitions tokens | ~6,862（P3 前）/~4,864（P3 后） | **10,692** | **19,909** |

真实 tool schema 比我们的估计大 56%。P3（schema 瘦身）在真实世界的收益比 benchmark 显示的更大。

---

## 5. tmux_compile 候选模式（真实 trace 佐证）

| 模式 | sessions | 占比 | tmux_compile 原语 |
|------|---------|------|------------------|
| 连续 3+ shell 调用 | 663 | 32.4% | run 序列 |
| 失败→同工具重试 | 802 | 39.2% | retry |
| tool outcome=error | 4,544 calls | 2.3% | branch/retry |

**Shell 工具分布**：bash 13,357 / terminal 4,648 / execute_code 4,359 / execute 3,975

**典型模式**（arguments 已脱敏，结构真实）：
1. **迭代调试**：`python -c ... 2>&1 | head -40` → 改 → 再跑 → `head -60`（同一 session 内 6 次）
2. **构建测试循环**：`node -e ...` → `node <path> 2>&1 | Tee-Object`（25–35s 每次）
3. **失败重试**：error 后同 name 工具再次调用（802 sessions）

---

## 6. 提取的 Example（本目录 ../examples/trace-*）

| example | 来源模式 | 验证 |
|---------|---------|------|
| trace-iterative-test | 迭代调试（模式1） | run 序列 + wait_for |
| trace-retry-build | 失败重试（模式3） | retry 原语 |
| trace-branch-deploy | 条件分支（部署检查） | branch 原语 |

> 注：arguments 脱敏无法还原真实命令，example 使用模式等价的代表性命令。

---

## 7. 方法局限（诚实声明）

1. 无消息文本——无法验证"确认轮"的语义，只能数轮数。
2. arguments 脱敏——example 命令是模式等价重构，非原文。
3. 单周数据——16 周全量可能有季节性差异。
4. TTFT 含 harness 开销——不纯是模型延迟。
5. cache_read_tokens > 0 即计命中——未区分部分命中与全命中。
