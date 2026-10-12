# 高速场景端到端分析

> 目标：当模型很快时，瓶颈转移到哪里。为未来优化指方向。
> 数据：`results/e2e-highspeed/`（slow/ultrafast/cached × 6 任务 × 3 reps，P1 二进制）
> 补充：`results/e2e-hyper/`（prefill 20000 tok/s, decode 2000 tok/s）

## 1. 三档阶段占比对照

T1（1 round，P1 优化后）：

| 阶段 | slow (4642ms→2574ms*) | ultrafast (1434ms) | cached (1386ms) | hyper (403ms) |
|---|---|---|---|---|
| P1b TTFT | 77.6% | **94.1%** | **94.3%** | **84.5%** |
| P2 streaming | 18.7% | 0.6% | 0.5% | 1.8% |
| P0+P3+P4 固定 | 3.7% | 5.3% | 5.2% | 13.7% |

*slow wall 因 P1 从 4642ms 降至 2574ms（−45%）

**核心发现：瓶颈没有转移，反而加剧。** ultrafast 下 TTFT 占比从 81% 升至 96%。

### 为什么

1. P1 干掉了确认轮，只剩 round 1。而 round 1 永远冷启动（prefix cache 无命中）。
2. Prefix caching 的价值被 P1 吃掉了大半：它只加速 round 2+，而现在 T1–T4 只有 1 round。
3. ultrafast 的 prefill 5000 tok/s 处理 6700 token prompt 仍需 1340ms。

## 2. 真正的约束：Prompt 大小

```
TTFT = prompt_tokens / prefill_tps + ttft_fixed
     = 6700 / prefill_tps + 10ms
```

27KB 请求体（~6700 tokens）是铁律。无论 prefill 多快，TTFT 与 prompt 大小成正比。

| prefill_tps | TTFT (6700 tok) | TTFT (3350 tok) | 加速比 |
|---|---|---|---|
| 5,000 | 1350ms | 680ms | 2.0× |
| 20,000 | 340ms | 175ms | 1.9× |
| 100,000 | 77ms | 44ms | 1.8× |

**P3（schema 瘦身）在 slow 世界只值 7%，在高速世界是第一优先级。**
prompt 砍半 = 任何 prefill 速率下 TTFT 砍半。

## 3. Amdahl 外推与拐点

模型（T1，1 round）：`wall = 6700/prefill_tps*1000 + 10 + 13 + 50`

| prefill_tps | wall | TTFT% | 固定开销% | 边际收益 |
|---|---|---|---|---|
| 5,000 | 1413ms | 95.5% | 3.5% | — |
| 20,000 | 408ms | 84.6% | 12.3% | −71% |
| 50,000 | 207ms | 69.6% | 24.2% | −49% |
| 100,000 | 140ms | 55.0% | 35.7% | −32% |
| 500,000 | 86ms | 27.1% | 58.1% | −38% |

**拐点**：固定开销（~50ms：P0 17ms + P4 20ms + P3 5ms + 杂项）占比超 50% 时，
prefill 需 >180,000 tok/s。按当前硬件趋势，这是 3–5 年后的事。

**Amdahl 极限**：prefill → ∞ 时，wall → 63ms（固定 50ms + streaming 13ms）。
再快的模型也突破不了这个地板，除非动固定开销。

## 4. 高速下瓶颈排序（未来视角）

按"优化后 wall 下降"排序：

1. **Prompt 瘦身**（P3）：6700 → 3350 tokens，任何速率下 −45% TTFT。这是未来第一优先级。
2. **固定开销压缩**：P0（17ms 启动）+ P4（20ms 收尾）= 37ms。当 prefill >50k tok/s 时，这 37ms 占 18%，成为第二瓶颈。
3. **P3 inter-round**：tool 执行 3–12ms。单 round 任务中占比 <1%，多 round 任务中累加。不是瓶颈。
4. **Streaming**：13 tokens @ 1000 tok/s = 13ms。decode 再快也省不了几 ms。忽略。
5. **fx 自身 30ms**：永远 <5%，除非 prefill >200k tok/s。忽略。

## 5. 结论：未来优化路线图

**现在（prefill 5k tok/s）**：
- P1 已做（−45%）。下一步做 P3 prompt 瘦身（−45% TTFT）。

**近期（prefill 20k tok/s）**：
- wall ~400ms。TTFT 仍占 85%。P3 收益最大。
- 固定开销 12%，开始值得看 P0/P4。

**远期（prefill 100k tok/s）**：
- wall ~140ms。TTFT 55%，固定开销 36%。
- 优化重点转向：P0 启动、P4 收尾、进程复用（砍掉 P0）。
- 终极地板 63ms，需要架构级改动（常驻进程、连接复用）。

**一句话**：高速下真正的瓶颈是 prompt 大小，不是模型速度。P3 是未来第一优先级。
