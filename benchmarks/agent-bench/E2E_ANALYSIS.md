# agent-bench 端到端分阶段耗时分析

> 方法：sim-server 细粒度打点（收到请求 → 读完 body → 发完头 → 首字节 → 末字节 → 收尾）
> + harness 记录进程 spawn/exit epoch，与 server epoch 时钟对齐。会计 100% 闭合。
> 数据：T1（2 round）× flash/pro/slow × 3 reps，T4/T6 × pro 补充。jitter=0。

## 1. 阶段链定义

| 阶段 | 定义 | 测量方式 |
|---|---|---|
| P0 startup | 进程 spawn → 首个请求到达 server | 首个 t_start − spawn_epoch |
| P1a ingress | 请求头到达 → body 读完 | t_body_read − t_start（server 侧） |
| P1b TTFT | body 读完 → 首个 content 字节发出 | t_first_byte − t_body_read（server 侧） |
| P1c headers | 响应头发出耗时 | t_headers_sent − t_first_chunk（server 侧） |
| P2 streaming | 首字节 → 末字节（TPOT 累积） | t_last_byte − t_first_byte（server 侧） |
| P2b resp teardown | 末字节 → 连接 flush 完成 | t_end − t_last_byte（server 侧） |
| P3 inter-round | 上轮末字节 → 下轮请求到达 | t_start[i+1] − t_end[i]（client：SSE 解析 + tool 调度 + tool 执行 + 下轮请求构造 + 发送） |
| P4 teardown | 末轮结束 → 进程退出 | exit_epoch − 末个 t_end |

## 2. 瀑布图数据（T1，2 round，n=3 均值）

### flash（wall 502ms）

| 阶段 | ms | 占比 |
|---|---|---|
| P0 startup | 29.0 | 5.8% |
| P1b TTFT × 2 | 400.3 | 79.7% |
| P2 streaming × 2 | 57.0 | 11.3% |
| P3 inter-round × 1 | 8.0 | 1.6% |
| P4 teardown | 8.0 | 1.6% |
| P1a/P1c/P2b | 0 | 0% |

### pro（wall 1800ms）

| 阶段 | ms | 占比 |
|---|---|---|
| P0 startup | 7.7 | 0.4% |
| P1b TTFT × 2 | 1600.7 | 88.9% |
| P2 streaming × 2 | 177.0 | 9.8% |
| P3 inter-round × 1 | 8.7 | 0.5% |
| P4 teardown | 5.3 | 0.3% |
| P1a/P1c/P2b | 0 | 0% |

### slow（wall 4581ms）

| 阶段 | ms | 占比 |
|---|---|---|
| P0 startup | 8.0 | 0.2% |
| P1b TTFT × 2 | 4000.3 | 87.3% |
| P2 streaming × 2 | 560.3 | 12.2% |
| P3 inter-round × 1 | 6.3 | 0.1% |
| P4 teardown | 5.7 | 0.1% |
| P1a/P1c/P2b | 0 | 0% |

### ASCII 瀑布图（pro / T1，1 格 ≈ 50ms）

```
ms:     0         500        1000        1500
        |----------|----------|----------|
P0      ██
        (8ms startup)
req1    ..........████████████████
                   |<-- TTFT 800ms -->|
req1s                          ███
                               (177ms streaming, 2 rounds)
P3                                 █
                                   (9ms: parse+tool+build)
req2                               ████████████████
                                   |<-- TTFT 801ms -->|
req2s                                               █
                                                    (26ms)
P4                                                   █
                                                     (5ms teardown)
```

## 3. 瓶颈排序（按占比）

| 排名 | 阶段 | 占比范围 | 说明 |
|---|---|---|---|
| 1 | P1b TTFT | 79.7–88.9% | 模型首 token 延迟，绝对主导。每 round 付一次。 |
| 2 | P2 streaming | 9.8–12.2% | TPOT 累积。token 越多占比越高。 |
| 3 | P0+P3+P4（fx 侧全部） | 0.7–9.0% | 启动 + 轮间 + 收尾。flash 下 9% 是因为分母小，绝对值仅 45ms。 |
| 4 | P1a/P1c/P2b/网络 | 0% | localhost，无网络开销。 |

**模型 API（TTFT + streaming）占端到端 91–99%。fx 自身开销恒定 ~20–45ms，与 profile 无关。**

补充观测：
- P3 与 tool 类型无关：write_file（T1）gap 8ms，3× write_file 批处理（T4）gap 6–8ms，shell（T6）gap 3–4ms。tool 执行（sub-ms 级磁盘写）淹没在 fx 开销里。
- P0 冷启动 69ms vs 热启动 7–10ms（page cache），仅首跑。
- T4 把 3 个 tool_call 并在一 round 里：2 round 完成 3 个工具，round 数不随工具数线性增长。

## 4. 优化方向（按端到端收益排序）

### O1. 减少 round 数（收益最大）

每 round 固定成本 = 1 × TTFT。T1 用 2 round（tool_call + stop 确认），若能 1 round 完成：
- slow：省 2000ms（−44%）
- pro：省 800ms（−44%）
- flash：省 200ms（−40%）

路径：
- prompt 工程：让模型一次输出所有 tool_call（T4 已证明可行，3 工具并一 round）。
- 协议层：如果最后一步只是 stop 确认，考虑"tool_call 即终态"语义，省掉确认 round（需改 fx src）。

### O2. 降低 TTFT（模型侧，client 可配合）

TTFT 占 80–89%，其中 prefill 是大头（800 prompt tokens，27KB 请求 JSON）。
- prompt 缓存：system prompt + tool 定义跨 round 不变，缓存命中后 TTFT 只付增量 prefill。
- 瘦身请求：27KB 里 tool schema 占大头；按任务动态裁剪可用工具。
- 预期：缓存命中可将第 2+ round 的 TTFT 降 50–80%（以实测为准）。

### O3. 流式重叠：不等 [DONE] 就调度 tool

当前 fx 等整轮 SSE 收完才解析调度。tool_calls chunk 到达后即可开始执行：
- 本数据：tool_calls 在流末尾，重叠收益小（省 < 30ms）。
- 长输出场景：tool_calls 在流中部时，可省数百 ms。值得在 fx src 里做增量 SSE 解析。

### O4. fx 自身开销（不值得）

P0+P3+P4 合计 20–45ms，占端到端 0.7–9%。即使全砍掉，slow profile 下收益 < 1%。
结论：不要再优化 fx 那 30ms。

## 5. 一句话总结

**端到端 91–99% 是模型 API 时间（TTFT 占 8 成），fx 开销可以忽略。**
**真正的优化只有三个：少 round、降 TTFT、流式重叠。**

## 6. 前缀缓存（prefix caching）建模与实测

### 6.1 模型

sim-server 实现 prefill/decode 分离：

```
TTFT = ttft_fixed_ms + (1 - hit_ratio) × prompt_tokens / prefill_tps
TPOT = 1000 / decode_tps
```

前缀缓存：请求体按 64 字节分块做 FNV-1a 哈希，server 保留上一请求的块哈希，新请求计算最长公共前缀（LCP），命中部分跳过 prefill。`prefix_hit_pct = -1` 时按真实 LCP 计算，0–100 时强制指定比率（对照实验用）。

**结构性约束（不可配置）**：
1. 共享池只存 prefill 阶段的 KV。decode 生成的 token 是 per-request 的（其 KV 依赖本请求自身的上下文），永不进入共享池。实现上缓存只对请求体（prefill 输入）做哈希，decode 产物不参与。
2. 最后一个 prompt token 恒为 miss。KV 按整块缓存，尾部不满一块的部分（含最后一个 token）总是重算。实现为 `hit_tokens ≤ prompt_tokens − 1`，因此 hit_ratio 恒小于 100%。

来源：对应 vLLM automatic prefix caching 语义——按 token 块做内容哈希链、只缓存整块、APC 只加速 prefill（decode 生成新 token，不重算旧 token）。

**实现细节**：按字节对原始 JSON 做 LCP 会低估命中率。fx 的请求 JSON 里 `"messages"` 排在 `"tools"` 前面，第二轮的 messages 数组一延长就切断字节前缀（实测只有 32%），尽管 tool 定义完全相同。sim 按推理 server 的实际行为做规范化：`tools JSON ++ 0x00 ++ messages JSON` 再分块哈希（对应 chat template 里 tool 定义在前、对话在后的渲染顺序）。规范化后第二轮真实命中率 98%。

### 6.2 命中率–TTFT 对照（T1，prefill 5000 tok/s，decode 1000 tok/s）

| 强制命中率 | round 1（冷） | round 2 实际命中 | round 2 TTFT | wall |
|---|---|---|---|---|
| 0% | 0% / 1349ms | 0% / 1365ms | 1366ms | 2812ms |
| 25% | 0% / 1349ms | 24% / 1026ms | 1027ms | 2418ms |
| 50% | 0% / 1349ms | 49% / 687ms | 687ms | 2076ms |
| 75% | 0% / 1349ms | 74% / 349ms | 350ms | 1732ms |
| 90% | 0% / 1349ms | 89% / 146ms | 146ms | 1540ms |
| 100% | 0% / 1349ms | **99%** / 10ms | 10ms | 1413ms |

结论：
- round 1 永远是冷启动（0%），诚实。
- TTFT 与 miss 比率严格线性。
- 强制 100% 只得到 99%：结构性上限生效（最后一个 token 恒 miss）。

### 6.3 端到端对比：slow vs cached vs ultrafast（T1，3 reps）

| profile | prefill | decode | 缓存 | wall | vs slow |
|---|---|---|---|---|---|
| slow | 3440 tok/s | 12.5 tok/s | 关 | 4620ms | — |
| cached | 5000 tok/s | 1000 tok/s | 强制 95% | 1547ms | −67% |
| ultrafast | 5000 tok/s | 1000 tok/s | 真实 LCP | 1503ms | −67% |

ultrafast 细节（round 1 / round 2）：TTFT 1349ms → 33ms（真实命中 98%），streaming 8ms → 3ms（TPOT 1ms）。

结论：
- 前缀缓存把稳态 TTFT 从秒级打到数十毫秒，是降 TTFT 最有效的手段。
- 高速 decode（1000 tok/s）把 streaming 占比压到可忽略。
- 缓存生效后，round 1 冷启动成为新的主导成本 → 下一步优化方向：减少 round 数（O1）与冷启动并行预热。
