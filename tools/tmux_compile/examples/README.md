# tmux_compile 例子：九个用户故事

每个目录一个故事：`setup.sh`（建测试场）→ `dsl.yaml`（可编译）
→ `run.sh`（编译 + 运行 + 断言）。`run_all.sh` 全跑。

| 故事 | 编排 | 对应真实 case | 真实度 |
|------|------|-------------|--------|
| `bug-hunt` | 复现 → `git bisect run` → 逆向 culprit → 验证 | 通用 bisect 模式 | 全真 |
| `pr-review` | 3 reviewer 并行 → 汇总 → 条件修复 | M2（三路并行 review） | 编排全真（`review.sh`/`fix.sh` 替身） |
| `parallel-dev` | 3 worktree 并行 → 顺序 merge → 冲突诚实停 | M3 + T5 | 编排全真（`implement.sh` 替身） |
| `deploy-healthcheck` | 蓝绿部署 → 健康检查 → 条件切流量（含失败路径） | D1（capistrano-bluey） | 全真（fake service，无外部依赖） |
| `retry-until-ready` | 迁移 → 有界重试等 lag 排空 → panic flag 熔断 | D7（gh-ost） | 全真 |
| `conditional-setup` | 逐服务探测 → 只给运行中的挂 monitor | T2（tmuxinator#658） | 全真 |
| `trace-iterative-test` | 迭代调试（真实 trace 模式1） | trace 联合验证 | run 序列 + wait_for |
| `trace-retry-build` | 失败重试（真实 trace 模式3） | trace 联合验证 | retry 原语 |
| `trace-branch-deploy` | 条件分支（部署检查） | trace 联合验证 | branch 原语 |

`test_integration.sh`：走 `asock tmux-compile`（agent_sock 驱动，
`TMUX_SOCK_PATH` 模式）跑 bug-hunt，验证驱动链路。

已知限制见 `TMUX_COMPILE_GUIDE.md` §7。实现细节见
`TMUX_COMPILE_ANALYSIS.md`。
