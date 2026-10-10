# agent-bench 设计文档

> 位置：`benchmarks/agent-bench/`
> 目标：测出 fx agent 的真实速度，支持多速率 API 模拟与任务轨迹回放，benchmark 驱动做速度优化。
> 状态：设计评审中（先过目再动手）

---

## 1. 目标与非目标

**目标**
- 端到端测出 fx agent 在真实编码任务上的速度（wall time），而非仅模型 API 延迟。
- 用可控的模拟 API 把"模型速度"和"harness 开销"分开：同一任务在 flash/pro/slow/flaky 四档下跑，剥离变量。
- 轨迹回放：录制一次真实任务的 LLM 交互序列，回放时零模型延迟，纯测 agent 执行层（tool 调度、prompt 组装、流解析）开销。
- 所有结果一键重跑（`./run.sh`），输出 markdown 对比表。

**非目标**
- 不改 `src/` 下现有业务逻辑（约束）。优化点走独立分支或 benchmarks 内 wrapper。
- 不做模型质量评测（pass@k、代码正确性打分）——只做速度 benchmark；任务完成判定是二元的（断言过/不过），不过的样本不计入速度对比。
- 不测交互式 TUI，只测 `fx ask` one-shot 模式（可脚本化、可计时）。

---

## 2. 架构总览

```
┌──────────────┐      ┌──────────────┐      ┌──────────────────┐
│ harness.mjs  │─────▶│  fx binary   │─────▶│   sim-server     │
│ (Node)       │ env  │ (release     │ HTTP │ (Zig, 本地回环)   │
│ - 布任务     │ HOME │  二进制,     │ SSE  │ - rate profile   │
│ - 计时       │ FX_  │  不改 src)   │      │ - 剧本/回放模式   │
│ - 断言       │PROV..│              │      │ - timing JSONL   │
│ - 出表       │      │              │      │                  │
└──────────────┘      └──────────────┘      └──────────────────┘
       │                     │                       │
       └─────────┬───────────┴───────────┬───────────┘
                 ▼                       ▼
        results/<ts>/            trajectory JSON
        - summary.md             (录制/回放共用格式)
        - runs.jsonl
```

**关键设计选择与依据**（已调研仓库验证）：
- 用 **release 二进制**（`gh release download v0.0.13`）而非源码构建：VM 无 Zig 工具链，release 有 linux x86_64 预编译包；且"不改 src"约束下二进制即被测对象。版本号 pin 在 `run.sh`，可升级。
- 协议走 **`openai-chat-completions`**：`configured_provider.zig` 证实这是 settings 可配的协议（`{"sim":{"protocol":"openai-chat-completions","base_url":"http://127.0.0.1:PORT/v1","auth":{"type":"none"}}}`），走标准 SSE `choices[].delta.tool_calls`，比 fx 私有协议更易在 sim-server 里精确控制 timing。不采用 libfx SDK 路径（那是给 bench-fx.mjs 的，不经过 CLI 启动路径，而启动开销正是优化目标之一）。
- 调用模式照抄仓库既有约定（`tests/evals/eval-helpers.ts` 已验证）：`fx ask --auto --json --no-save --timeout N "<prompt>"`，`--json` 输出含 `steps` / `tool_calls[]` / `exit_code`，harness 直接解析，无需脆弱的 stdout 文本解析。
- Provider 注入：harness 为每次 run 建隔离 `HOME`，写 `$HOME/.fx/settings.json`（含 `providers.sim` + `permission_mode: "auto"` + `permission: {bash/edit/read: "allow"}`，照抄 `createEvalHome()`），`FX_PROVIDER=sim` 选择。`FX_MAX_AGENT_STEPS` 设上限防跑飞。隔离、可并行。
- sim-server 用 **Zig**（任务明确要求 `sim-server.zig`，延续 `fake-inference-server.zig` 风格）：单文件、无依赖、SSE 精确到 ms 级 sleep。工具链问题：`run.sh` 检测 `zig`，缺失则下载官方静态包（~50MB，一次性）。

---

## 3. sim-server.zig 设计

### 3.1 协议
- 监听 `127.0.0.1:0`（动态端口，首行 stdout 打 `{"port":N}`，harness 解析；沿用 fake-inference-server 的约定）。
- `POST /v1/chat/completions`，`stream=true` 时返回 SSE：
  ```
  data: {"id":"...","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"write_file","arguments":"{...}"}}]},"finish_reason":null}]}
  data: {"id":"...","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":N,"completion_tokens":M}}
  data: [DONE]
  ```
- `stream=false` 时返回一次性 JSON（兼容）。
- 请求体解析：取 `messages` 最后一个 user/tool 消息的摘要记入 timing 日志（不做语义理解——语义由"剧本模式"接管）。

### 3.2 Rate profile（可配置）
CLI：`sim-server --profile <name> [--profile-json <file>] [--script <file>] [--timing-log <file>] [--port N]`

| profile | TTFT | TPOT | 失败注入 | 429 概率 | 说明 |
|---|---|---|---|---|---|
| `flash` | 200ms | 8ms/token | 0 | 0 | 快模型上限参考 |
| `pro` | 800ms | 25ms/token | 0 | 0 | 主力模型参考 |
| `slow` | 2000ms | 80ms/token | 0 | 0 | 慢模型/拥塞参考 |
| `flaky` | 800ms | 25ms/token | 5%（500） | 5%（429+Retry-After） | 考验 agent 重试/恢复 |
| 自定义 | JSON 指定 | JSON 指定 | JSON 指定 | JSON 指定 | `--profile-json` |

- TTFT：收到请求后、首个 SSE chunk 前 sleep。
- TPOT：每个 token chunk 间 sleep；token 按"每 ~4 字符一切"模拟（与计时口径一致即可，不求精确分词）。
- 失败注入：按概率直接返回 500（可重试）或 429（带 `Retry-After: 1`），harness 计"API 错误次数"。
- `--jitter <pct>`：给 TTFT/TPOT 加抖动（默认 10%），避免全同步假象。

### 3.3 剧本模式（给轨迹回放用）
`--script trajectory.json`：按**请求序号**（第 N 次 LLM 请求）返回预设响应：
```json
{
  "mode": "script",
  "steps": [
    {"tool_calls": [{"name": "write_file", "arguments": {"path": "hello.py", "content": "..."}}], "text": "创建文件"},
    {"tool_calls": [{"name": "run_command", "arguments": {"command": "python hello.py"}}]},
    {"text": "完成", "finish": "stop"}
  ]
}
```
- 序号超出 steps → 返回 `{"text":"done","finish":"stop"}` 并记 `script_exhausted: true`（回放越界即失败信号，不静默编造）。
- 剧本模式下 TTFT/TPOT 可设 0（`--profile zero`），用于纯 harness 开销测量。

### 3.4 Timing 日志（JSONL，每行一个请求）
```json
{"t_start_ms": 1712345678901, "t_first_chunk_ms": 1712345679105, "t_end_ms": 1712345679230,
 "ttft_ms": 204, "tokens": 42, "profile": "flash", "req_seq": 3,
 "status": 200, "script_hit": true, "req_bytes": 12345, "prompt_summary": "tool result: ..."}
```
harness 用它算：LLM round 次数、token 总量、模型侧耗时占比。

---

## 4. Harness 设计（`harness.mjs`）

### 4.1 指标定义

| 指标 | 定义 | 采集方式 |
|---|---|---|
| `wall_ms` | 任务开始（spawn 前）→ `fx ask` 进程退出 | `performance.now()` |
| `ttftc_ms` | 进程启动 → 首次 tool_call 被执行 | `fx --json` 的 `tool_calls` 无时间戳，改从 sim-server timing 日志推导：首次 tool_calls 请求到达 sim-server 的时刻 − 进程启动时刻（tool 执行紧随其后，误差 < tool 调度间隙，可接受） |
| `llm_rounds` | LLM 请求次数 | sim-server timing 日志行数 |
| `tokens_in/out` | 输入/输出 token 总量 | SSE `usage` 字段累加（sim-server 伪造但自洽：按请求字节估算） |
| `model_ms` | 纯模型侧耗时（Σ TTFT+TPOT） | timing 日志 |
| `harness_ms` | `wall_ms - model_ms`（近似；含启动+tool 执行+调度间隙） | 推导 |
| `api_errors` | 500/429 次数 | timing 日志 status |
| `success` | 任务断言是否全过 | 文件存在 + 内容断言（见 4.2） |

**口径说明**：`harness_ms` 是"宇宙第一速度"优化的主战场——回放模式（profile=zero）下它就是纯执行层开销，可直接对比优化前后。

### 4.2 任务集（6 个，全部真实可执行、有确定性判定）

| # | 任务 | prompt 要点 | 完成判定 |
|---|---|---|---|
| T1 | 创建文件 | 写 `hello.py`，打印 `hello agent-bench` | 文件存在 + 内容含 `hello agent-bench` |
| T2 | 改 bug | 给定 `buggy.py`（off-by-one），修复并使自带断言通过 | `python buggy.py` 退出码 0 |
| T3 | 重构函数 | 把 `long.py` 里的重复代码抽成函数，保持行为 | `python long.py` 输出与预期一致 + 函数定义数减少 |
| T4 | 多文件装配 | 按 spec 建 3 个文件并互相 import，能跑通 | `python main.py` 输出 `ok` |
| T5 | 读-改-验证闭环 | 读 `data.json`，按规则生成 `report.md` | `report.md` 存在 + 含预期字段 |
| T6 | 失败恢复 | 任务要求先跑一个必失败的命令，再按错误信息修正 | 最终产物正确（考验多 round） |

- 每个任务：独立 temp 工作目录 + 种子文件（`tasks/<id>/seed/`）+ `assert.mjs`（断言脚本，退出码判定）。
- 任务 prompt 固定、 deterministic；sim-server 在"基准模式"下对同一任务返回**固定剧本**（见 5.1 录制），保证可比性。注意：benchmark 测的是**速度**不是模型智能——剧本固定后，不同 profile 下的 wall time 差异即来自 timing。
- T6 故意多 round，用于测 `llm_rounds`  scaling。

### 4.3 评测流程
```
for profile in [flash, pro, slow, flaky, zero]:
  for task in [T1..T6]:
    for rep in 1..3:
      1. 起 sim-server（对应 profile；zero 用录制剧本+零延迟）
      2. 建 temp HOME + 工作目录，布种子文件
      3. 计时 spawn: fx ask "<prompt>"（env: FX_PROVIDER=sim, HOME=temp）
      4. 跑 assert.mjs → success?
      5. 收 timing JSONL，记 runs.jsonl
输出 results/<ts>/summary.md 对比表（profile × task，wall_ms mean/p50 + success 率）
```
- `flaky` 下 success 可能抖动：单独列 api_errors，不计入速度排名。
- 总耗时估算：6 任务 × 5 profile × 3 rep = 90 runs；flash 下每 run ~5-15s，总计约 15-30 min。可接受；`--quick` 模式（1 rep、跳 slow）用于冒烟。

---

## 5. 轨迹录制 / 回放（`replay/`）

### 5.1 录制
- `record.mjs --task T1 --profile pro`：跑一次真实任务，sim-server 开 `--record trajectory.json`。
- 记录内容（不含 prompt 全文，只存形状，避免体积爆炸）：
```json
{
  "task": "T1", "profile": "pro", "fx_version": "v0.0.13",
  "steps": [
    {"seq": 1, "tool_calls": [{"name":"write_file","arguments":{"path":"hello.py","content":"..."}}],
     "text": "...", "usage": {"in": 1234, "out": 56}},
    ...
  ],
  "assert": "passed"
}
```
- **至少录 2 条**：T1（短，1-2 rounds）、T6（长，多 round 含失败恢复）。
- 录制时 sim-server 返回的是"合理但固定"的剧本（手写，针对任务目标），不是真实 LLM——诚实起见，文档中明确这是 *scripted baseline*，不是模型能力评测。

### 5.2 回放
- `replay.mjs --trajectory replay/t1.json [--profile zero|pro]`：sim-server `--script` 模式按 seq 回放。
- **一致性验证**：回放后跑同一 `assert.mjs`，必须通过；且 tool_call 序列（name+arguments 摘要）与录制一致（`--verify` 对比，不一致即 fail）。
- 回放的核心价值：`--profile zero` 时 `wall_ms ≈ harness_ms`，即**剥离模型延迟后的纯执行层速度**——优化前后的对比在这里做，最干净。

### 5.3 录制 vs 回放的诚实边界
文档中明确写：回放测的是"给定相同模型输出时 agent 执行层的速度"，不是"模型变快了"。任何优化声明必须标注是在哪个 profile/模式下测得的。

---

## 6. 速度优化方法（benchmark 驱动）

1. **先跑 baseline**：`./run.sh --quick` 拿全量数字，重点看 `harness_ms` 在 zero-profile 回放下的分布。
2. **Profile 找大头**：候选（按预期收益排序）—
   - 启动开销：`fx ask` 冷启动（Zig 二进制应已很快，验证）。
   - 首 token 前准备：prompt 组装、工具 schema 序列化、settings 加载。
   - Tool 调度间隙：tool_call 返回 → 下一次 LLM 请求之间的 gap（从 timing 日志的 `t_end_ms(n)` → `t_start_ms(n+1)` 直接读出）。
   - 流解析：SSE chunk 处理（对比不同 TPOT 下的 harness_ms 是否恒定——若随 TPOT 涨，说明解析在热路径上）。
3. **做 2-3 个优化**，每个都要 before/after 数字（zero-profile 回放，3+ reps，报 mean/p50）。
4. **约束**：不碰 `src/`。可行的优化面：环境/配置（`FX_ULTRAFAST` 等已有开关的实测对比）、wrapper（预热、并发跑任务）、以及**独立分支**上的代码改动（`bench/opt-*` 分支，改动 patch 随报告附上，merge 与否由用户定）。

---

## 7. 目录结构与一键重跑

```
benchmarks/agent-bench/
  DESIGN.md            # 本文档
  run.sh               # 一键入口：装依赖→下二进制→编 sim-server→跑 harness→出表
  sim-server.zig       # 多速率模拟 API（§3）
  harness.mjs          # benchmark harness（§4）
  record.mjs           # 轨迹录制（§5.1）
  replay.mjs           # 轨迹回放（§5.2）
  tasks/               # 任务集
    T1-create-file/{prompt.txt, seed/, assert.mjs}
    ... T6-recover/
  replay/              # 录制的 trajectory JSON（≥2 条）
    t1-pro.json  t6-pro.json
  results/             # 输出（gitignore）
    <ts>/summary.md  runs.jsonl
  lib/                 # 共享：stats、assert helper、fx env 组装
```

`run.sh` 流程：
```sh
./run.sh [--quick] [--profile flash] [--task T1]
# 1. 检查 node/z​ig（缺 zig 则下载官方静态包到 .tools/）
# 2. zig build-exe sim-server.zig -O ReleaseFast
# 3. gh release download v0.0.13 -p 'fx-linux-x86_64*' （已存在则跳过，校验 sha256）
# 4. node harness.mjs [args] → results/<ts>/summary.md
```

---

## 8. 风险与开放问题

**与仓库既有 benchmark 的关系**：`.github/workflows/bench.yml` 已有启动延迟预算（Linux CI 2ms，`FX_BENCH=1` 路径）。agent-bench 不重复它——bench.yml 测的是"进程启动到退出"，agent-bench 测的是"任务级端到端 + 执行层开销分解"。两者互补；agent-bench 暂不进 CI（on-request 运行，如 `long_turn_memory` 那样），等稳定后再议。

| # | 风险 | 缓解 |
|---|---|---|
| 1 | `fx ask` 的 tool 权限/审批可能卡住无人值守 run | 已解决：照抄 `tests/evals` 模式——`--auto` + settings `permission_mode: "auto"` + `permission.{bash,edit,read}: "allow"`；另设 `FX_MAX_AGENT_STEPS` 上限 + harness 超时 kill 记 fail |
| 2 | Zig 工具链下载在 CI/离线环境失败 | run.sh 允许 `--sim-node` fallback（Node 版 sim-server，同协议；精度稍差但可用） |
| 3 | sim-server 的"固定剧本"让 benchmark 变成自证预言 | 文档诚实声明（§5.3）；flaky profile 和真实 LLM 抽查（可选 `--live` 跑一次真 API 做 sanity） |
| 4 | timing 精度：Node `performance.now()` ~ms 级，够用；Zig 端用 `std.time.milliTimestamp()` | 同一指标两端对齐（都用 ms），不做 µs 级声明 |
| 5 | `fx ask` 输出解析脆弱 | 优先用退出码 + 产物断言；ttftc 尽量从 sim-server 的"首次 tool 请求到达时间"推导（比解析 stdout 可靠） |

**待你拍板**：
- Q1：任务集 6 个是否够？要不要加"真实仓库级"大任务（如在 fx-fork 里修一个小 bug）？
- Q2：`flaky` 的 5% 失败率是否太高/太低？
- Q3：优化部分，"独立分支改 src"是否在本次范围内，还是只做不碰 src 的 wrapper/配置优化？（任务原文说"优化点单独开分支"，我理解为允许开分支改，但默认先做不碰 src 的）

---

*下一步：你过目后，我按此动手。预计实现顺序：sim-server.zig → tasks+assert → harness.mjs → 跑 baseline → record/replay → 优化。*
