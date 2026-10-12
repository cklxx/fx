# fx 性能与协议文档地图（DOCMAP）

> 生成日期：2026-10-13。范围：`tools/tmux_compile/`、`tools/sock/`、`benchmarks/agent-bench/` 共 19 份文档。
> 状态列：**有效** = 当前仍指导开发或使用；**历史** = 已被替代或完成使命，留作证据。

## 1. 文档清单

### 1.1 tools/tmux_compile/（编译式 tmux 流水线）

| 文档 | 一句话 | 给谁看 | 时效性 |
|------|--------|--------|--------|
| `README.md`（根） | 项目入口：关系图、快速开始、性能表 | 开发者/用户 | 有效（2026-10-13 修正 2 处过时数字） |
| `docs/TMUX_COMPILE_GUIDE.md` | 用户手册：YAML 语法、产物契约、已知限制 | 用户 | 有效 |
| `docs/USER_CASES.md` | 29 个真实场景的可编译性裁定库 | 开发者 | 有效 |
| `docs/PERFORMANCE.md` | 编译产物 vs LLM 驱动的加速比实测与方法 | 开发者/评审 | 有效（§1.2 自标"偏高估算"，§5 有真实 trace 修正） |
| `docs/TRACE_VALIDATION.md` | 120 万 tool 调用的真实 trace 联合验证 | 开发者 | 有效（最新，2026-10-12/13） |
| `docs/TMUX_COMPILE_ANALYSIS.md` | 可编译性条件与失败模式的可行性分析 | 开发者 | 历史（设计前分析，结论已沉淀进 GUIDE §7） |
| `docs/TMUX_COMPILE_ACCEPTANCE.md` | 验收与体验设计（35 测试、用户故事） | 开发者 | 历史（验收已通过，2026-10-11） |
| `examples/README.md` | 六个用户故事的说明 | 开发者 | 有效 |

### 1.2 tools/sock/（Agent Sock 协议）

| 文档 | 一句话 | 给谁看 | 时效性 |
|------|--------|--------|--------|
| `DESIGN.md`（v4） | 协议规范：11 原语、队列语义、server 行为 | 开发者/评审 | 有效（当前规范） |
| `OSC7501.md` | 状态上报协议 OSC 7501 的映射与解析器行为 | 开发者 | 有效 |
| `FX_INTEGRATION.md` | agent-sock 接入 fx 的形式与 MVP 步骤 | 开发者 | 有效 |
| `tla/VERIFICATION.md` | TLA+ 模型验证记录（v4 已同步重验） | 评审 | 有效 |
| `REVIEW.md` | 对 DESIGN v3 的对抗式红队审核（R-01–R-25） | 评审 | 历史（审核对象是 v3，DESIGN 已是 v4） |
| `SOTA.md` | 四方向 SOTA 调研档案（MCP/ACP/A2A 等） | 开发者 | 历史（2026-10-10，决策依据已定） |
| `tla/SIMPLIFICATION.md` | 协议简化建议 S1–S4 | 开发者 | 历史（S1–S4 已全量采纳进 DESIGN v3） |

### 1.3 benchmarks/agent-bench/（fx 速度测量与优化）

| 文档 | 一句话 | 给谁看 | 时效性 |
|------|--------|--------|--------|
| `DESIGN.md` | bench 架构：sim-server、harness、轨迹录制回放 | 开发者 | 有效 |
| `PARADIGM_IDEAS.md` | 范式级想法（编译式 pipeline 等），每个带可验证预测 | 开发者 | 有效（想法 1 已实现，状态已标注） |
| `HETEROGENEOUS.md` | 异构分解验证报告（idea #4） | 开发者 | 有效（最新，2026-10-13） |
| `E2E_ANALYSIS.md` | 端到端分阶段耗时分析（sim 三档 profile） | 开发者 | 历史（sim 档位；真实 TTFT 以 TRACE_VALIDATION 为准） |
| `HIGHSPEED_ANALYSIS.md` | 高速场景的 Amdahl 外推与未来路线图 | 开发者 | 历史（E2E 的推论篇，P1/P3 已落地） |
| `SRC_OPT_PLAN.md`（v2） | fx src 端到端优化计划（P1/P2/P3） | 开发者 | 历史（P1/P3 已合入 main，计划使命完成） |

## 2. 重复、过时、矛盾

| # | 位置 | 问题 | 处理 |
|---|------|------|------|
| 1 | `tmux_compile/README.md` | "flash ~1.7×" 与 `PERFORMANCE.md` §5 的真实 flash 2.6–4.1× 矛盾 | 已修（2026-10-13） |
| 2 | `tmux_compile/README.md` | "three end-to-end stories"，实际 6 个（`examples/README.md`） | 已修（2026-10-13） |
| 3 | `agent-bench/SRC_OPT_PLAN.md` §0 | 工具链路径 `~/workspace/agent-sock/zig/toolchain/zig` 指向已不存在的本地仓库 | 已修（2026-10-13） |
| 4 | `PARADIGM_IDEAS.md` 想法 1 | 预测 "T1 2500ms → <100ms（25×）"，实测 story 级 2.6–4.1×；预测口径（单任务）与实测口径（整故事）不一致，差距未解释 | 待补：标注口径或更新预测 |
| 5 | `E2E_ANALYSIS.md` §6 vs `SRC_OPT_PLAN.md` §4 | 两处都建模 prefix caching，结论重复 | 同归档，归档后自然消解 |
| 6 | `TMUX_COMPILE_ANALYSIS.md` vs `GUIDE.md` §7 | 可编译性限制在两处各说一遍 | ANALYSIS 归档，GUIDE 为唯一当前版本 |
| 7 | `REVIEW.md` vs `DESIGN.md` | REVIEW 审核 v3，DESIGN 已是 v4；读者误以为审核的是当前版 | REVIEW 归档，DESIGN §10 保留修订明细 |
| 8 | `PERFORMANCE.md` §1.2 | P1/P3 提交前的 27KB prompt 数据，加速比偏高 | 文档自标"偏高估算"，§5 有修正；P3 后重测 sim 可消除 |

## 3. 死链接检查（2026-10-13）

全仓库扫描 markdown 链接 `](path)`：13 个可解析，**0 个死链**。
反引号路径引用无死链；发现 1 处过时路径（#3，已修）。

## 4. 重构提案（待确认，不直接动手）

目标：每个 tool 目录 = 一个 `README.md` 入口 + `docs/`（当前文档）+ `docs/archive/`（历史文档）。

### 4.1 搬（git mv）

| 源 | 目标 |
|----|------|
| `tools/tmux_compile/docs/TMUX_COMPILE_ANALYSIS.md` | `tools/tmux_compile/docs/archive/` |
| `tools/tmux_compile/docs/TMUX_COMPILE_ACCEPTANCE.md` | `tools/tmux_compile/docs/archive/` |
| `tools/sock/REVIEW.md` | `tools/sock/docs/archive/` |
| `tools/sock/SOTA.md` | `tools/sock/docs/archive/` |
| `tools/sock/tla/SIMPLIFICATION.md` | `tools/sock/docs/archive/` |
| `benchmarks/agent-bench/E2E_ANALYSIS.md` | `benchmarks/agent-bench/docs/archive/` |
| `benchmarks/agent-bench/HIGHSPEED_ANALYSIS.md` | `benchmarks/agent-bench/docs/archive/` |
| `benchmarks/agent-bench/SRC_OPT_PLAN.md` | `benchmarks/agent-bench/docs/archive/` |
| `tools/sock/DESIGN.md`、`OSC7501.md`、`FX_INTEGRATION.md` | `tools/sock/docs/`（新建 docs/，DESIGN 留根一份做入口跳转或只放 docs/） |
| `tools/sock/tla/VERIFICATION.md` | 保留原位（TLA+ 模型旁） |
| `benchmarks/agent-bench/DESIGN.md`、`PARADIGM_IDEAS.md`、`HETEROGENEOUS.md` | `benchmarks/agent-bench/docs/`（新建 docs/） |

### 4.2 建（新写）

| 文件 | 内容 |
|------|------|
| `tools/sock/README.md` | 入口：协议一句话、DESIGN/OSC7501/FX_INTEGRATION/tla 导航、版本史 |
| `benchmarks/agent-bench/README.md` | 入口：bench 是什么、DESIGN/PARADIGM_IDEAS/HETEROGENEOUS 导航、一键重跑 |
| `tools/sock/docs/archive/README.md` 等 | 每目录一个归档说明：为什么归档、被什么替代 |

### 4.3 删

无。归档代替删除，git 历史保留一切。

### 4.4 改引用

| 文件 | 改法 |
|------|------|
| `tools/tmux_compile/examples/README.md` | "实现细节见 `TMUX_COMPILE_ANALYSIS.md`" → `docs/archive/TMUX_COMPILE_ANALYSIS.md` |
| `tools/sock/DESIGN.md`（若搬进 docs/） | 内部 `tla/VERIFICATION.md` 引用改为 `../tla/VERIFICATION.md` |
| `tools/tmux_compile/README.md` | `docs/` 列表加一行指向 `docs/archive/` |
| `benchmarks/agent-bench/PARADIGM_IDEAS.md` | 想法 1 补注 25× 预测与实测口径差异（#4） |

### 4.5 不动

`results/` 下的 summary.md（测量原始记录）、`.tools/`（工具链）、`docs/long-turn-memory.md`（根目录，不在范围）。

## 5. dogfooding 记录

- `osc7501.py` 的 `emit()` 可用：工作流中用它上报了两次状态，输出序列格式正确。
- DOCMAP 起草中发现：`tmux_compile/README.md` 的性能表与 `PERFORMANCE.md` §5 脱节——README 写于 §5 修正之前，说明"文档只呈现知识"时，入口页的数字最容易腐烂。提案中 README 只放导航、数字只留一份在 PERFORMANCE.md，可根治。
