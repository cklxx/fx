# tmux_compile 用户手册

> 把 YAML 描述的多轮 tmux 交互编译成自包含 bash 产物。产物零依赖、可审计、可重跑。

## 1. 这是什么

`tmux_compile` 把"在 tmux pane 里做一串操作"这件事从 LLM 的多轮 tool call
变成一次编译 + 一次执行。典型输入：部署检查、bisect 猎 bug、多 reviewer
并行评审。编译器在 `tmux_compile/`，产物是可读 bash，只调 tmux CLI。

```
dsl.yaml  --(python3 -m tmux_compile)-->  product.sh  --(bash, TSOCK+PANE)--> COMPILE-OK
```

## 2. 什么时候用编译，什么时候直接调 tmux_tool

| 场景 | 选谁 | 原因 |
|------|------|------|
| 确定性多步序列（bisect、部署验证） | tmux_compile | 编译一次，多次运行；失败定位到步骤 |
| 多 reviewer / 多模块并行 + 汇总 | tmux_compile `parallel` | pane 生命周期 + join 语义开箱即用 |
| 步骤间需要 LLM 临场判断 | tmux_tool 直接调 | 编译只处理确定性流程，不做决策 |
| 单次 ad-hoc 命令 | `TmuxTool.run` | 编译是 overhead |
| 交互式程序（vim、ssh 密码） | 都不行 | 见 §7 已知限制 |

经验规则：流程能写成"如果输出含 X 就做 Y"的确定性规则 → 编译；
需要"看情况" → 留给 agent 运行时调 tmux_tool。

## 3. YAML 语法参考

```yaml
name: my-flow                     # 必填
params:                           # 可选
  branch: {required: true}        # --param branch=x 必填
  base: {default: "main"}          # 可选，有缺省
  mode: "fast"                    # 标量 = 缺省值
steps:                            # 必填，非空
  - run: echo hello               # 单行
    timeout_s: 60                 # 可选，>0，缺省 60
    assert_exit: 0                # 可选，检查最后一行的退出码
  - run: |                        # 多行：逐行发送
      for i in 1 2 3; do
        echo $i
      done
  - wait_for: "READY|DONE"        # ERE，等 pane 出现
    timeout_s: 120
  - branch:                       # 看当前 pane 内容做文本分支
      if_output_contains: "ERROR"
      then:
        - run: echo bad
      else: []                    # 空分支 = no-op
  - parallel:                     # 不可嵌套；leg 之间只通过文件通信
      legs:
        - name: sec               # 必填，块内唯一
          timeout_s: 300          # 可选，单 leg 上限
          steps: [...]            # run/wait_for/branch/fail/retry
        - name: api
          steps: [...]
    timeout_s: 900                # 可选，整个块上限
  - retry:                        # 有界重复，直到条件成立；不可嵌套
      attempts: 3                 # 必填，>=1
      delay_s: 5                  # 可选，>=0；attempt 之间的 sleep
      until_output_contains: "READY"  # ERE，检查新鲜输出；与下二选一（可同时设）
      until_exit_zero: true       # 上一个 run 的退出码 == 0 即停
      steps: [...]                # run/wait_for/branch/fail/parallel
      # 至少一个停止条件必填；until_exit_zero 要求 steps 里至少一个 run；
      # 内部步骤失败（超时等）立即 abort，不重试；耗尽 attempts → exit 15
  - fail: reason-string           # 主动失败，精确报错
```

`{{param}}` 在编译期展开（`--param K=V`）。值必须单行。未声明的引用、
缺失的 required、未声明的 `--param` 都是编译期错误（exit 20，带行号）。

## 4. 产物契约

| 退出码 | 含义 |
|--------|------|
| 0 | 成功。stdout 末行 `COMPILE-OK steps=N` |
| 10 | 单步超时。stderr `COMPILE-FAIL [leg=L ]step=N reason=timeout dsl_line=L` |
| 11 | pattern 超时。stderr `COMPILE-FAIL [leg=L ]step=N reason=pattern-timeout dsl_line=L` |
| 12 | `assert_exit` 不符。stderr `... reason=nonzero-exit rc=R dsl_line=L` |
| 13 | `fail` 步骤。stderr `... reason=<reason> dsl_line=L` |
| 14 | parallel leg 失败。stderr `COMPILE-FAIL step=N reason=parallel-leg-failed legs="a b" dsl_line=L`；失败 leg 的最后 30 行日志会先打到 stderr |
| 15 | retry 耗尽。stderr `COMPILE-FAIL [leg=L ]step=N reason=retry-exhausted attempts=K dsl_line=L` |
| 20 | 编译期错误 / 缺 env（`PANE`、`TSOCK`/`TMUX_SOCK_PATH`） |

`dsl_line` 是该步骤在 YAML 里的行号，直接定位。驱动侧
（`agent_sock/tmux_compile.py`）用宽松正则解析，新增字段不影响它。

运行时 env（二选一 + PANE）：

| 变量 | 含义 |
|------|------|
| `PANE` | 目标 pane id（如 `%0`）。必填 |
| `TSOCK` | `tmux -L` 的 socket 名。独立运行模式 |
| `TMUX_SOCK_PATH` | `tmux -S` 的 socket 路径。agent_sock 驱动模式，优先级高于 `TSOCK` |

## 5. 三种运行方式

```bash
# 1. 独立 CLI（产物零依赖，哪里都能跑）
python3 -m tmux_compile flow.yaml -o flow.sh --param branch=main
TSOCK=mysock PANE=%0 bash flow.sh

# 2. agent_sock 驱动（pane = 某个 agent 的）
asock tmux-compile --file flow.yaml --agent agent-7 --param branch=main
# 输出 JSON: {"ok": true, "exit_code": 0, "steps": N, "stdout": ..., ...}

# 3. Python API
from agent_sock.tmux_tool import TmuxTool
from agent_sock.tmux_compile import compile_and_run
res = compile_and_run(TmuxTool(), "agent-7", "flow.yaml", params={"branch": "main"})
```

关系说明：产物**不**调用 agent_sock（独立 bash，直调 tmux CLI）。
`agent_sock/tmux_compile.py` 是驱动侧：编译 → 把产物跑在 agent 的 pane 上。

## 6. 常见坑（按踩坑顺序）

### 6.1 命令回显自动抑制（marker 问题已解决）

每个 `run` 步骤执行前后，产物用 `stty -echo` / `stty echo` 包住命令发送。
pane 里看不到键入的命令文本，只看到输出。因此 `branch` / `wait_for`
的 pattern 不会误命中命令本身——直接写 plain marker 即可，不再需要
"运行时值 + ERE 类"的绕法：

```yaml
# 现在这样写就行：命令文本不会出现在 pane 里
- run: |
    n=$(grep -l CRITICAL findings-*.md 2>/dev/null | grep -c .)
    if [ "$n" -gt 0 ]; then echo NEEDS_FIX; else echo ALL_CLEAN; fi
- branch:
    if_output_contains: NEEDS_FIX
```

注意：pane 里仍然能看到 `stty -echo` 这一行本身（它是关闭回显前发出的），
以及每个 run 的 `TC-BEGIN-<token>` 锚点行。pattern 不要匹配这两个。

超时失败（exit 10）时产物会尽力恢复 `stty echo`，但如果 pane 卡死了，
恢复命令只会排队。下一个 `run` 步骤开始时会重新关闭回显，自愈。

### 6.2 输出自动新鲜（stale output 已解决）

每个 `run` 步骤开始时先在 pane 里打印 `TC-BEGIN-<token>` 锚点。
`branch` / `wait_for` / `retry` 的条件只匹配**该锚点之后**的文本，
即"上一个 run 之后的新输出"。不需要再手动 `clear`。

```yaml
- run: ./repro.sh        # 输出 BUG_REPRODUCED
- run: ./verify.sh       # 输出 ALL_CLEAN
- branch:
    if_output_contains: BUG_REPRODUCED   # 看不到上一步的输出 → 走 else
```

规则：matcher 看到的是"离它最近的上一个 run 之后"的内容。
`wait_for` 作为第一个步骤时（前面没有 run），看整个可见 pane。

`TC-BEGIN` 前缀是保留的：不要在命令里打印它。锚点如果滚出 scrollback
（>2000 行，极少见），matcher 保守地什么都不匹配（fail closed），
表现为 pattern-timeout 而不是误判。

### 6.3 Multi-line run 的退出码

取**最后一行**的退出码。需要"任一失败即停"时用 `&&` 链或 `set -e`：

```yaml
- run: |
    set -e
    cd /tmp/work
    make && make test
  assert_exit: 0
```

### 6.4 wait-for 闩锁

tmux 的 `wait-for -S` 信号发出后永不清除。产物是"编译一次、实例化多次"：
TOKEN 在每次运行时重新生成（`uuidgen`），不要硬编码。见
TMUX_COMPILE_ANALYSIS.md §1.1。

### 6.5 Leg 间只通过文件通信

`parallel` 的 legs 是独立 pane + 独立 subshell，不共享变量。
阶段间传数据用文件（如 `/tmp/culprit.txt`），见 bug-hunt 例子。

### 6.6 `{{}}` 无转义

`{{` 永远开始一个 param 引用。shell 里极少用到，如需字面 `{{`
请改写（目前不支持转义）。

## 7. 已知限制（诚实声明，不会修的）

| 项 | 原因 |
|----|------|
| 交互式程序（vim、ssh 密码提示） | 提示符集合不封闭，条件列不完（分析 §1.2） |
| `parallel` 嵌套 | 一层已覆盖真实场景；嵌套的 pane 管理复杂度超最小可用 |
| `retry` 嵌套 | 内层耗尽会立即 abort 外层，嵌套无意义；编译期拒绝 |
| 失败回滚 | tmux 无事务能力；产物只做到精确报错到步骤/leg |
| 自动解 merge 冲突 | 冲突语义需要人判断；产物诚实停止并指明状态 |
| 裸 `sleep` 的等待 | 写 `wait_for: <pattern>`，不要 `sleep N` 猜时间 |
| `retry` 里的超时 | 内部步骤超时立即 abort，不会触发下一 attempt；`until_exit_zero` 只看退出码，不看超时 |

## 8. 例子

`tmux_compile/examples/`：三个故事全部可跑（`run.sh`），外加
`test_integration.sh`（走 agent_sock 驱动）。

| 例子 | 内容 | 真实度 |
|------|------|--------|
| `bug-hunt` | 复现 → `git bisect run` → 逆向 culprit → 验证 | 全真：无 test double |
| `pr-review` | 3 reviewer 并行 → 汇总 → 条件修复 | 编排全真；`review.sh`/`fix.sh` 是 agent 的确定性替身 |
| `parallel-dev` | 3 worktree 并行 → 顺序 merge → 冲突诚实停 | 编排全真；`implement.sh` 是 agent 的确定性替身 |

```bash
for s in bug-hunt pr-review parallel-dev; do
  bash tmux_compile/examples/$s/run.sh
done
bash tmux_compile/examples/test_integration.sh
```
