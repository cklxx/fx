# fx 回归基线（BASELINE）

基线提交：`c4e7c19`（main 尖端，2026-10-12）
测量方式：每个套件独立跑 3 次，取 wall time 中位数。全部在 `c4e7c19` 的干净 worktree 上实测，非转述。

## 1. 通过率

| 套件 | 规模 | 结果（3 轮） |
|---|---|---|
| `tools/tmux_compile/tests/test_tmux_compile.sh` | 35 cases（A1–A10） | 35/35，35/35，35/35 |
| `tools/tmux_compile/examples/run_all.sh` | 9 stories | 9/9，9/9，9/9 |
| `tools/tmux_compile/tests/soak_tmux_compile.sh` | soak（40 步 + 5 wait_for + retry） | rc=0 ×3 |
| `tools/sock` test_errors | 8 | 8/8 ×3 |
| `tools/sock` test_eventbus | 5 | 5/5 ×3 |
| `tools/sock` test_osc7501 | 44 | 44/44 ×3 |
| `tools/sock` test_pipeline | 10 | 10/10 ×3 |
| `tools/sock` test_proto | 10 | 10/10 ×3 |
| `tools/sock` test_queue | 17 | 17/17 ×3 |
| `tools/sock` test_tmux | 4 | 3 通过 + 1 跳过，×3 |
| `tools/sock` test_server_client | 5 | **0/5：全部卡死（见已知问题 1）** |
| `tools/tmux_compile/demo.sh` | demo | rc=0 |

sock 合计：103 个测试，90 通过，1 跳过，5 卡死，7 个历史失败已在基线提交前修复（见 §4）。

## 2. 耗时基线（wall time，中位数）

### 2.1 套件级

| 套件 | 3 轮实测 | 中位数 |
|---|---|---|
| test_tmux_compile.sh | 58s，60s，60s | **60s** |
| run_all.sh（9 stories） | 43s，44s，43s | **43s** |
| soak_tmux_compile.sh | 14s，14s，13s | **14s** |
| sock test_osc7501 | 14s ×3 | **14s** |
| sock test_tmux | 22s，23s，22s | **22s** |
| sock 其余 5 个模块 | 均 ≤1s | **≤1s** |
| demo.sh | 9s（单轮） | **9s** |
| test_server_client | 超时（60s 未返回） | n/a |

### 2.2 story 级（每 story 独立跑 3 轮，中位数）

| story | 中位数 | 3 轮实测 |
|---|---|---|
| bug-hunt | **2s** | 2，1，2 |
| pr-review | **2s** | 2，3，2 |
| parallel-dev | **5s** | 6，5，5 |
| deploy-healthcheck | **13s** | 13，13，14 |
| retry-until-ready | **11s** | 11，11，11 |
| conditional-setup | **2s** | 2，2，2 |
| trace-iterative-test | **1s** | 1，1，1 |
| trace-retry-build | **5s** | 5，6，5 |
| trace-branch-deploy | **2s** | 2，1，2 |

## 3. 环境

| 项 | 值 |
|---|---|
| 日期 | 2026-10-12（UTC） |
| tmux | 3.4 |
| Python | 3.12.3 |
| 内核 | Linux 7.0.0-39-generic x86_64 |
| CPU | AMD EPYC 9D25（2 vCPU） |
| 内存 | 7 GB |

## 4. 已知问题

1. **test_server_client 全部 5 个测试卡死**（真问题，非环境）。
   根因：`Server.serve()` 用 `async with server:` 包裹 `serve_forever()`。
   测试的 `asyncTearDown` 里 `srv_task.cancel()` 后 `await srv_task`，
   `__aexit__` 调 `wait_closed()` 一直等已连接的 client 断开；
   但 client 的 close 注册在 `addAsyncCleanup`，在 tearDown 之后才执行。
   结果：tearDown 等 server 关，server 等 client 关，client 等 tearDown 结束。
   已用最小复现确认（无 client 时 cancel 正常返回；有连接时必卡死）。
   状态：基线提交 `c4e7c19` 仍未修复，待 sock 负责人处理。

2. **历史问题（基线测量中发现，`c4e7c19` 已修复）**：
   在 `c88d7a2` 上实测时，`errors.ErrorPacket` 是普通 dataclass，
   不是 `Exception` 子类。后果：所有 `raise errors.make(...)`
   的错误路径实际抛出 `TypeError`；`assertRaises(errors.ErrorPacket)`
   的 7 个测试（pipeline 5 + queue 2）全部 error。
   兄弟线提交 `45f680a` 已修复（ErrorPacket 改为 Exception 子类）。
   本基线在修复后的 `c4e7c19` 上重测，上述 7 个测试全部通过。

3. **偶发 flake（环境，非回归）**：
   脏工作树上 `run_all.sh` 第 3 轮出现过一次 bash 解析错误
   （`unexpected EOF while looking for matching '"'`），当时 9 个 stories
   全部 PASS，文件本身无损，`bash -n` 正常，第 4 轮通过。
   未复现，记为瞬时 I/O flake。

## 5. dogfooding 发现

1. **基线测量流程本身只有一半能用 tmux_compile 表达**。
   "每个套件跑 3 次取中位数" 需要循环原语，DSL 没有 for-loop；
   跨轮聚合（取中位数、填表）需要真正的脚本步骤。
   能表达的部分：各套件作为 parallel legs 并行跑 + 汇总步骤。
   结论：DSL 缺迭代原语是真实缺口，基线这类"跑 N 次取统计量"的
   运维流程写不出来。

2. **多线并行共用一个工作树会互相污染**。
   本轮测量中途，兄弟线的未提交修改（ErrorPacket 改 Exception 等）
   直接改变了正在跑的测试行为（同一命令前后两次失败原因不同）。
   后改用 `git worktree` 建干净 worktree 隔离测量。
   建议：dogfooding 的 4 条线以后各用独立 worktree/分支，
   不要共用一个 checkout。

3. **unittest discover 遇到卡死测试时整个套件无输出**。
   `test_server_client` 卡死导致 discover 永远停在第一轮，
   必须逐模块拆跑才能定位。这不是回归，是测试运行方式的教训：
   给会 hang 的模块单独加 timeout 分开跑。

## 6. 对比方法

以后每次改动后，在同样环境（或记录环境差异）下重跑 §1 表格：
- 通过率任何一项下降 → 回归。
- wall time 中位数变化超过 ±20% → 性能回归/提升，值得看一眼。
- story 级耗时用于定位是哪一个 story 变慢。
