# tmux 编译验收与体验设计

> 对象：tmux_compile 最小可用（TMUX_COMPILE_ANALYSIS.md §3.1）。
> 顺序：先用户故事，再验收标准。验收标准全部可执行。
>
> **执行状态（2026-10-11）**：三个故事已实现为可跑例子，
> 见 `tmux_compile/examples/{bug-hunt,pr-review,parallel-dev}/run.sh`。
> 本节的 YAML 已同步为编译器实际支持的语法（`params` / `parallel` 见
> `TMUX_COMPILE_GUIDE.md` §3）。`test_integration.sh` 覆盖 agent_sock
> 驱动路径（`asock tmux-compile`）。

## 0. 术语

| 术语 | 定义 |
|------|------|
| 编译器 | tmux_compile.py。输入 YAML，输出 bash 产物 |
| 产物 | 编译输出的 bash 脚本。零依赖，独立可执行 |
| 轮 | 一次 send-keys 发出到确认完成 |
| token | wait-for 通道名。每次运行重新生成 |

产物契约：

| 退出码 | 含义 |
|--------|------|
| 0 | 成功。stdout 末行 `COMPILE-OK steps=N` |
| 10 | 单步超时。stderr `COMPILE-FAIL step=N reason=timeout` |
| 11 | pattern 超时。stderr `COMPILE-FAIL step=N reason=pattern-timeout` |
| 12 | 命令非零退出。stderr `COMPILE-FAIL step=N reason=nonzero-exit` |
| 13 | 断言失败。stderr `COMPILE-FAIL step=N reason=assert-failed` |
| 20 | 编译期错误。编译器退出，指出 YAML 行号与原因 |

---

## 1. 用户故事

> 来源：GitHub 真实多 agent 协作模式。故事 1 取自 hamelsmu/claude-review-loop（722 stars）：Claude 实现 → 4 个并行 Codex reviewer → 去重 → 修 → 循环直到通过。故事 2 取自 adstastic/agent-skills/tmux-agents："Split this work across 3 sub-agents"，多 worktree 并行开发。故事 3 取自 d-luop/worktree-dev：fleet 模式 + 只读 reviewer。

### 故事 1：PR 三审循环

**用户想做什么**：开发者每天提 PR 前的固定动作。写完功能后，起 3 个并行 reviewer（安全审、API 审、测试审），每个在独立 tmux pane 里跑。审完汇总，发现问题就修，没问题就过。修完再审一轮，直到干净。

**日常性**：这是开发者每天重复 3–5 次的动作。手动做要开 3 个终端、等结果、汇总、修、再跑，约 20 分钟。

**用户输入**（review-loop.yaml）：

> 可执行版本：`tmux_compile/examples/pr-review/dsl.yaml`（`run.sh` 一键跑通）。
>
> 实现差异：`parallel` 的 legs 含 `steps:`（非裸 `run:`）；`pane:` 标签取消（leg 自动分配 pane）；分支 marker 改用运行时计数 + ERE（`critical-files=[1-9]`，见 GUIDE §6.1 marker problem）；`review.sh`/`fix.sh` 为 agent 的确定性替身，编排全真。

**tmux 交互序列**（编译产物实际做的）：

```bash
# 建 3 个 pane
tmux split-window -h -t "$SESSION" -c /tmp/rev-sec
tmux split-window -v -t "$SESSION" -c /tmp/rev-api
tmux split-window -v -t "$SESSION" -c /tmp/rev-test
# 每个 pane 发任务（prompt 写文件后 paste，避免 send-keys 多行问题）
tmux load-buffer /tmp/task-sec.txt && tmux paste-buffer -t "$PANE_SEC" && tmux send-keys -t "$PANE_SEC" Enter
# ... 同理 api、test
# 轮询等三个 findings 文件都出现（artifact 等待，不是 pane 输出等待）
deadline=$((SECONDS + 600))
while [ $SECONDS -lt $deadline ]; do
  [ -s /tmp/findings-sec.md ] && [ -s /tmp/findings-api.md ] && [ -s /tmp/findings-test.md ] && break
  sleep 5
done
# 任一 agent hang 住超 10 分钟：发 C-c，capture 诊断，标记失败
# 汇总、分支、修、再审
```

**复杂度来源**：3 并行 pane 生命周期管理、artifact 文件等待（不是简单的 pane 输出匹配）、hang 检测与恢复、条件循环（修完再审）。

**用户怎么知道成功**：`COMPILE-OK` 且 `/tmp/review-final.md` 无 CRITICAL。失败时知道卡在哪个 reviewer、哪个文件没产出。

### 故事 2：三路并行开发再合并

**用户想做什么**：一个功能拆三块并行做。前端、后端、集成测试各一个 agent，每个在独立 git worktree 里开发，互不干扰。都做完后合并到主分支，有冲突就停下来报给人。

**日常性**：功能开发的标准分工。手动做要建 3 个 worktree、开 3 个终端、分别盯进度、最后合并解冲突。

**用户输入**（parallel-dev.yaml）：

> 可执行版本：`tmux_compile/examples/parallel-dev/dsl.yaml`（`run.sh` 一键跑通）。
>
> 实现差异：同上；merge 冲突检测改为 `conflict-count=[1-9]`（marker problem）；冲突时 `git merge --abort` 后诚实停止，不自动解。

**tmux 交互序列**：

```bash
# 建 worktree（顺序，不能并行，git 锁）
# 起 3 pane，每 pane 一个 agent，done-marker 文件为完成信号
# 等待：轮询 /tmp/done-fe、/tmp/done-be、/tmp/done-it，30 分钟超时
# 任一失败：capture 该 pane 最后 100 行，kill 其他 pane，报错指明哪个模块失败
# 合并：顺序 merge，每步检查 CONFLICT 标记
# 有冲突：停，打印 git status，不自动解（诚实边界）
# 无冲突：跑集成测试
```

**复杂度来源**：worktree 生命周期（建、用、清）、长任务等待（30 分钟）、部分失败时级联清理、merge 冲突检测与诚实停止（不自动解）。

### 故事 3：Bug 猎杀流水线

**用户想做什么**：线上报了个 bug。第一个 agent 复现，第二个 agent 用二分定位引入的 commit，第三个 agent 修，第一个 agent 再验证。任何一步失败就停，报错指明卡在哪。

**日常性**：oncall 修 bug 的标准流程。手动做要在终端里反复切：复现脚本、二分、看 diff、改代码、重跑。

**用户输入**（bug-hunt.yaml）：

> 可执行版本：`tmux_compile/examples/bug-hunt/dsl.yaml`（`run.sh` 一键跑通）。
>
> 实现差异：`run` 内嵌 `branch:` 改为独立 branch 步骤；`assert_output:` 改为 branch + `fail`；bisect 命中判定用`culprit=[0-9a-f]{40}`（marker problem）；全真，无替身。

**tmux 交互序列**：

```bash
# pane 复现：发命令，等 BUG_REPRODUCED 或超时。没复现 → 整个流水线停，fail fast
# pane 二分：git bisect 是交互式命令的典型代表，需要自动应答。产物用 `git bisect run` 非交互模式
#   等 CULPRIT= 写入文件。bisect 本身可能失败（test_cmd 不稳定）→ 报错
# pane 修：读 culprit.env，调 agent fix。等 exit 0
# 回到复现 pane：重跑，还出现 BUG → fix 无效，报错；没出现 → COMPILE-OK
# 关键：阶段间有数据依赖（culprit.env 文件），不是纯顺序执行
```

**复杂度来源**：阶段间文件依赖（culprit.env）、fail-fast 语义（复现失败不继续）、bisect 的非交互化、二分不稳定时的重试、修完验证的闭环。

**三个故事的共同点**（为什么适合验收 tmux 编译）：
- 都是开发者每天做的事，不是 toy
- 都有多 pane 并行 + 阶段间依赖 + 条件分支 + 失败处理
- tmux 交互序列真实：建 pane/worktree、发任务、等 artifact 文件、轮询、超时、kill 清理
- 每个故事都踩中至少 2 个编译风险点（闩锁、注入、token 冲突、超时语义）

---

## 2. 验收标准

### 2.1 公共夹具

```bash
export TSOCK="accept-$$"
tmux -L "$TSOCK" kill-server 2>/dev/null
tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')
# 用完清理：tmux -L "$TSOCK" kill-server
```

`tmux_compile.py` 命令行：`python3 tmux_compile.py <dsl.yaml> -o <product.sh>`。

下表每行一个用例。全部自动化（bash 断言），无人工项。

| 编号 | 覆盖 | 输入 | 执行 | 断言 | 反例 |
|------|------|------|------|------|------|
| A1 | 确定性序列 | 3 个 `run: echo stepN`，timeout 10 | 编译后运行产物 | exit 0；stdout 末行 `COMPILE-OK steps=3`；pane 输出含 step1/step2/step3 且有序 | YAML 含未知键 `runn:` → 编译器 exit 20，报错指出行号与键名 |
| A2 | shell 转义 | `run: echo "a;b" '$HOME' '$(id)'` | 编译后运行产物 | exit 0；pane 显示字面 `a;b`、`$HOME`、`$(id)`，无命令执行 |  naive 拼接会执行 `id`。检查产物含转义形式，`$(id)` 未展开 |
| A3 | token 唯一性（闩锁） | `run: sleep 2; echo done`，timeout 10 | 同一产物连续运行两次 | 两次都 exit 0；第二次耗时 ≥2s（证明等待未跳过） | token 硬编码的产物第二次瞬间返回（演示闩锁 bug，编译器必须避免） |
| A4 | 循环等待 | 后台 3s 后打印 READY；`wait_for: READY`，timeout 10 | 编译后运行产物 | exit 0；耗时 ≥3s 且 <10s | READY 拼写错误为 READI → exit 11，`reason=pattern-timeout` |
| A5 | 分支命中 | `run: echo ALREADY_APPLIED` 后接 branch（else 含 `echo SHOULD_NOT_RUN`） | 编译后运行产物 | exit 0；pane 输出不含 SHOULD_NOT_RUN | — |
| A6 | 分支未命中 | `run: echo FRESH` 后接同 A5 的 branch | 编译后运行产物 | exit 0；pane 输出含 SHOULD_NOT_RUN | — |
| A7 | shell 注入 | `run: '"; touch /tmp/pwned-accept; echo "'` | 编译后运行产物 | `/tmp/pwned-accept` 不存在；产物正常结束或干净失败 | 无转义时文件会被创建（演示注入，编译器必须阻止） |
| A8 | token 冲突（并发） | 同一产物在两个 pane 并发运行，各 echo 自身标记 | 两个产物进程并行启动 | 两个都 exit 0；pane A 含标记 A，pane B 含标记 B，无串扰 | token 复用时 A 的完成信号会提前唤醒 B（编译器必须每次生成唯一 token） |
| A9 | 单步超时 | `run: sleep 60`，timeout_s 3 | 编译后运行产物 | exit 10；stderr `COMPILE-FAIL step=1 reason=timeout`；耗时 <10s | 报错若只写 "failed" 不指明步骤，本用例判失败 |
| A10 | pattern 超时 | `wait_for: NEVER_APPEARS`，timeout_s 3 | 编译后运行产物 | exit 11；stderr `COMPILE-FAIL step=1 reason=pattern-timeout`；耗时 <10s | — |

覆盖矩阵：

| 条件/风险 | 用例 |
|-----------|------|
| 确定性序列 | A1 |
| shell 转义 | A2 |
| token 唯一性 | A3 |
| 循环等待 | A4 |
| 文本条件分支 | A5, A6 |
| wait-for 闩锁 | A3 |
| shell 注入 | A7 |
| token 冲突 | A8 |
| 超时语义 | A9, A10 |

### 2.2 自动化说明

A1–A10 全部写入 `tests/test_tmux_compile.sh`，每个用例独立函数，失败时打印用例编号与实际输出。退出码非零即整体失败。无人工确认项。

---

## 3. Demo 脚本

目标：3 分钟讲清"编译多 agent tmux 协作"是什么。用故事 1（PR 三审循环）演示，因为它最直观：3 个 pane 并行跑，观众能看到分工。

### 3.1 环境准备（一键）

```bash
./demo/setup.sh
# 建隔离 tmux server（-L demo），建测试 git 仓库（含一个待审 PR 分支），输出 pane id
```

### 3.2 演示顺序（按出彩程度）

| 时间 | 内容 | 观众看到 |
|------|------|----------|
| 0:00–0:30 | 展示 review-loop.yaml（并行 3 reviewer + 汇总 + 条件修） | 输入是声明式的 YAML，不是 shell 脚本 |
| 0:30–1:00 | `tmux_compile.py` → `review.sh`，`cat` 看产物（可读 bash） | 产物零依赖，能审计 |
| 1:00–2:00 | 运行，3 个 pane 同时出现 reviewer 输出 | 并行真的在跑，不是串行 |
| 2:00–2:30 | findings 汇总，有 CRITICAL → 自动进修复分支 | 条件分支生效 |
| 2:30–3:00 | `COMPILE-OK`，展示 /tmp/review-final.md | 端到端闭环 |

### 3.3 关键帧（录屏用）

1. YAML 的 `parallel:` 块（3 个 reviewer）。
2. 3 个 tmux pane 并排跑（tiled layout）。
3. 汇总后的 review-final.md（含 CRITICAL 标记）。
4. `COMPILE-OK` 或 `COMPILE-FAIL step=N reason=...`。

---

## 4. 验收环境

### 4.1 前置条件

| 项 | 要求 |
|----|------|
| tmux | 3.4+（已验证 3.4） |
| socket | 隔离：`tmux -L <name>`，不用默认 socket |
| pane 尺寸 | 建 pane 时固定 `-x 200 -y 50` |
| uuid | `uuidgen` 或 `/proc/sys/kernel/random/uuid`（产物二选一） |
| Python | 3.10+（只编译器需要，产物不需要） |

### 4.2 可重跑保证

- 每个用例开始前 `tmux -L "$TSOCK" kill-server 2>/dev/null`，结束后同样清理。
- socket 名含 `$$`，并行跑用例不串扰。
- `/tmp/pwned-accept` 等标记文件用例前后各删一次。
- 产物不写 pane 之外的状态，无残留。

### 4.3 CI 可行性

可行。tmux 的 `send-keys`、`capture-pane`、`wait-for` 都不需要 attach，headless 可跑。GitHub Actions 的 ubuntu runner 自带 tmux（没有则 `apt install tmux`）。注意两点：

1. CI 里不要复用默认 tmux server，一律 `-L` 隔离。
2. 超时类用例（A9/A10）在高负载 runner 上耗时抖动，断言用"耗时 < 2×timeout"而非精确值。

---

## 5. 不验收什么（诚实边界）

| 项 | 原因 |
|----|------|
| 交互式程序编译 | 提示符集合不封闭（分析 §1.2），不在最小可用范围 |
| 失败回滚 | tmux 无事务能力（分析 §2.4），产物只做到精确报错 |
| 并行 pane 间依赖 | 最小可用支持并行执行，但 pane 间的数据依赖只支持文件方式（故事 3 的 culprit.env），不支持 pane 间直接通信 |
| 裸 `sleep` 的自动重写 | 编译器直接报错，要求人工改写（分析 §1.6） |
| 自动解 merge 冲突 | 故事 2 遇到冲突时诚实停止，不自动解（冲突语义需要人判断） |

## 6. 自动化/人工标注

| 部分 | 方式 |
|------|------|
| A1–A10 | 全自动（`tests/test_tmux_compile.sh`） |
| Demo | 人工演示（2 分钟脚本辅助） |
| 产物可读性 | 人工抽查（`cat` 看一眼） |
