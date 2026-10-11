# tmux_compile 例子：三个用户故事

每个目录一个故事：`setup.sh`（建真实 git 测试场）→ `dsl.yaml`（可编译）
→ `run.sh`（编译 + 运行 + 断言）。`run_all.sh` 全跑。

| 故事 | 编排 | agent 替身 | 真实度 |
|------|------|-----------|--------|
| `bug-hunt` | 复现 → `git bisect run` → 逆向 culprit → 验证 | 无 | 全真 |
| `pr-review` | 3 reviewer 并行 → 汇总 → 条件修复 | `review.sh`、`fix.sh` | 编排全真 |
| `parallel-dev` | 3 worktree 并行 → 顺序 merge → 冲突诚实停 | `implement.sh` | 编排全真 |

`test_integration.sh`：走 `asock tmux-compile`（agent_sock 驱动，
`TMUX_SOCK_PATH` 模式）跑 bug-hunt，验证驱动链路。

已知限制见 `TMUX_COMPILE_GUIDE.md` §7。实现细节见
`TMUX_COMPILE_ANALYSIS.md`。
