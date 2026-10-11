# tmux_compile 用户场景库

> 29 个真实场景，来自 GitHub issue/PR/README。每个标注可编译性。
> 搜集日期：2026-10-12。宁缺毋滥：无强链接的不收。

**判定标准**（对照编译器原语）：
- **能**：run / wait_for / branch / parallel（一层）/ retry（有界）/ fail / params 可完整表达
- **部分能**：主干可编译，某环节超出原语（见"卡点"）
- **不能**：核心语义超出原语（无界循环、人机交互、运行时动态干预、失败回滚）

---

## 一、多 agent 编排（10）

### M1 — review-loop：两阶段 task→review→addressing 循环
- **来源**：[hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) README §What it does
- **场景**：Claude 写完代码，stop hook 并行启动最多 4 个 Codex reviewer，合并报告后 Claude 修 feedback；无 Codex 时 fallback 自评
- **tmux 交互**：run codex ×4（并行）→ wait_for 全完成 → 读合并报告 → 发 feedback 给 Claude → wait_for 修完 → branch（无 Codex → 自评分 支）
- **判定：部分能**。单轮 task→review→address 可用 parallel + wait_for + branch；"修完再审"的无界收敛循环超出 retry（有界）

### M2 — tmux-agents：3 路并行分角 review
- **来源**：[adstastic/agent-skills/tmux-agents/SKILL.md](https://github.com/adstastic/agent-skills/blob/HEAD/tmux-agents/SKILL.md) §5
- **场景**：3 个子 agent 各审一块（auth/API/tests），各写 deliverable 文件，primary 汇总
- **tmux 交互**：new-session + window ×3 → 各 pane 经文件投递任务 → 轮询 deliverable → 聚合 → kill-session
- **判定：能**。一层 parallel + leg 间文件通信 + wait_for，正中原语设计

### M3 — tmux-agents：write→review→edit 串行三阶段
- **来源**：[同上 SKILL.md](https://github.com/adstastic/agent-skills/blob/HEAD/tmux-agents/SKILL.md) §Agent count decision rules
- **场景**：writer 写 → reviewer 审 → editor 改，严格串行
- **tmux 交互**：开 agent-1 → wait_for 产出 → 开 agent-2 → wait_for review → 开 agent-3 → wait_for 完成
- **判定：能**。纯串行 staged，run + wait_for，无嵌套无分支

### M4 — tmux-agents：hang/crash 错误恢复
- **来源**：[同上 SKILL.md](https://github.com/adstastic/agent-skills/blob/HEAD/tmux-agents/SKILL.md) §Error recovery
- **场景**：子 agent hang 超 10min → C-c 中断重发；pane blank（crash）→ 重跑；彻底坏 → kill-window 重开
- **tmux 交互**：wait_for（10min 超时）→ send-keys C-c → capture 检查 → branch（恢复→重发 / 仍坏→重建）
- **判定：部分能**。重启重跑可用有界 retry；hang 检测依赖 wait_for 超时语义

### M5 — worktree-dev：fleet 并行 + 独立只读 reviewer
- **来源**：[d-luop/worktree-dev](https://github.com/d-luop/worktree-dev) README "Typical flow"
- **场景**：每 worktree 一 agent 并行开发；pre-push review 由人手动触发，独立只读 reviewer 通过才能 push
- **tmux 交互**：开任务 ×N → 各自推进 → wait_for roster ready → 人跑 review → branch（通过→push / 不过→打回）
- **判定：部分能**。并行启动 + 等状态文件可编译；人审门是交互式，超出原语

### M6 — worktree-dev：fleet_send agent 间消息（双层审批）
- **来源**：[d-luop/worktree-dev/.wtd/templates/CLAUDE.md](https://github.com/d-luop/worktree-dev/blob/HEAD/.wtd/templates/CLAUDE.md)
- **场景**：A agent 想问 B agent，需用户 chat 批准 + VS Code 二次批准，消息在对方 turn 结束时送达
- **tmux 交互**：起草 → wait 用户批准 → wait VS Code 批准 → 投递 → 对方 turn 结束收到
- **判定：不能**。双层人机审批 + turn 边界运行时语义，非 pattern 可表达

### M7 — codex-orchestrator：七阶段 pipeline
- **来源**：[kingbootoshi/codex-orchestrator](https://github.com/kingbootoshi/codex-orchestrator/blob/HEAD/README.md) §The Claude Code Plugin
- **场景**：Claude 按 Ideation→…→Testing 逐阶段委托 tmux 里的 Codex agent，各阶段不同 flag
- **tmux 交互**：start job（带阶段 flag）→ await-turn 等完成 → 读 jobs --json → 综合 → 下一阶段
- **判定：部分能**。阶段串行骨架可编译；"综合判断进哪阶段"是 LLM 语义决策，超出原语

### M8 — codex-orchestrator：并行调查 + 运行时纠偏
- **来源**：[同上 README](https://github.com/kingbootoshi/codex-orchestrator/blob/HEAD/README.md) §Examples
- **场景**：3 只读 agent 并行审 auth/N+1/XSS；发现走偏时向运行中的 agent 实时注入纠偏而非杀掉重开
- **tmux 交互**：start ×3 → 轮询 jobs --json → 发现走偏 → send 纠偏（pane 持续运行）→ 汇总
- **判定：部分能**。静态并行 + 等待可编译；"运行中 send 干预"超出 run（一次性发命令）

### M9 — swarm-forge：six-pack 角色链 + durable handoff
- **来源**：[unclebob/swarm-forge](https://github.com/unclebob/swarm-forge) README
- **场景**：specifier→coder→cleaner→architect→hardener→QA 六角色，各占 worktree + session；handoffd 守护进程投递；dashboard 审批门
- **tmux 交互**：起全部角色 → 上游 run+commit → handoff → 下游接收 → 完成；back-one/back-all 回传
- **判定：部分能**。纯前向链可编译；back-all 回传、审批门超出原语

### M10 — orchestrator-swarm：/loop 自治调度
- **来源**：[diffuzmetall/orchestrator-swarm](https://github.com/diffuzmetall/orchestrator-swarm/blob/HEAD/README.md)
- **场景**：orchestrator 以 3 分钟 tick 无限循环调度 worker 认领 beads；pane 挂掉时 failover 重分配；AFK 6 tick 停 loop
- **tmux 交互**：spawn pane → dispatch 角色 → /loop tick（poll→认领→干活→关闭）→ failover
- **判定：不能**。无界循环（retry 有界不适用）+ 运行时动态调度，超出原语

---

## 二、tmux 自动化工具（10）

### T1 — session 销毁时联动清理 docker 容器
- **来源**：[tmuxinator/tmuxinator#1004](https://github.com/tmuxinator/tmuxinator/issues/1004)（open）
- **场景**：`on_project_start` 装后台 watcher：等 session 消失后自动 `docker container kill foo`
- **tmux 交互**：启动 session 跑 pane 命令 → nohup 轮询 `tmux has-session`（等出现→等消失）→ 消失后执行清理
- **判定：能**。等状态翻转 = wait_for 轮询；原生的 nohup 轮询 hack 正是 wait_for 要表达的

### T2 — 按服务存活情况条件创建窗口
- **来源**：[tmuxinator/tmuxinator#658](https://github.com/tmuxinator/tmuxinator/issues/658)（closed）
- **场景**：20 个微服务每服务一窗口监控；dev 模式只有部分在跑，按 `ps` 结果决定建不建窗口
- **tmux 交互**：`ps a | grep <svc>` 探测 → 非空则建窗口跑日志，为空跳过
- **判定：能**。run 探测 + branch 分支，branch 原语的典型用例

### T3 — 按 CLI 参数开关窗口
- **来源**：[tmuxinator/tmuxinator#638](https://github.com/tmuxinator/tmuxinator/issues/638)（closed）
- **场景**：同一配置兼顾前后端；只做后端时不想手动关前端窗口，希望按参数条件开关
- **tmux 交互**：读启动参数 → 判断 → 决定是否建某 window
- **判定：能**。params + branch，静态分支完全覆盖

### T4 — 等条件满足再发送命令（阻塞式 send）
- **来源**：[tmux-python/tmuxp#96](https://github.com/tmux-python/tmuxp/issues/96)（open）
- **场景**：测试交互式程序：发命令前必须等 shell prompt 出现；试过等 title、等 prompt、等光标/scrollback 增长
- **tmux 交互**：send-keys → 轮询 capture-pane 等 prompt 正则 → 发下一条 → 断言输出（循环）
- **判定：能**。wait_for + run 交替，tmux_compile 核心覆盖场景

### T5 — 重启后并行拉起多个 session
- **来源**：[tmuxinator/tmuxinator#314](https://github.com/tmuxinator/tmuxinator/issues/314)（closed）
- **场景**：重启后顺序拉起 project1/2/3，一次只能起一个；希望多项目并行启动
- **tmux 交互**：依次建三个项目的 session + 窗口/pane；理想是并行
- **判定：能**。一层 parallel 正好覆盖；退化为顺序 run 也能表达

### T6 — 输入命令但等人按回车才执行
- **来源**：[tmuxinator/tmuxinator#469](https://github.com/tmuxinator/tmuxinator/issues/469)（closed）
- **场景**：命令打进 pane 不执行，由人走到对应 pane 手动按回车确认
- **tmux 交互**：send-keys 输入（不带 Enter）→ 等人类交互 → 人按回车执行
- **判定：不能**。human-in-the-loop，不支持人工介入节点

### T7 — setup 命令屏障：全部跑完才起 pane 命令
- **来源**：[remi/teamocil#130](https://github.com/remi/teamocil/issues/130)（open）
- **场景**：多 pane 依赖一组前置命令，同时跑会冲突；想要 setup 段串行跑完再起 pane
- **tmux 交互**：串行执行 setup 1→2→3（各等完成）→ 屏障 → 各 pane 并行发命令
- **判定：能**。顺序 run 天然是屏障，之后再 parallel

### T8 — before_script 启动守护进程导致 loader 挂死
- **来源**：[tmux-python/tmuxp#692](https://github.com/tmux-python/tmuxp/issues/692)（open）
- **场景**：`before_script: kak -s -d` 启动 headless 守护进程；命令已完成但 tmuxp 认为没结束，加载 hang
- **tmux 交互**：启动 daemon（fire-and-forget）→ 判定"就绪" → 继续建 session
- **判定：部分能**。`run "cmd &"` 可表达 fire-and-forget，wait_for 轮询就绪；但无显式后台原语，daemon 语义靠 shell `&` 隐含

### T9 — 等全部 pre_window 跑完再搬窗口
- **来源**：[tmuxinator/tmuxinator#886](https://github.com/tmuxinator/tmuxinator/issues/886)（closed）
- **场景**：pre_window 给每项目设状态栏颜色；搬窗口进已有 session 要求所有 pre_window 先执行完
- **tmux 交互**：每 window 注入 `tmux set` → 屏障：全完成 → move-window 搬进 session
- **判定：部分能**。简单串行用顺序 run 即得屏障；"往各 pane 异步注入 + 跨 pane 完成屏障"需改写为串行（无 pane 级 join 原语）

### T10 — 配置变更后只重建变化的 pane
- **来源**：[remi/teamocil#126](https://github.com/remi/teamocil/issues/126)（open）
- **场景**：`--replace` 重跑配置时只重建命令变了的 pane，保持其余不动
- **tmux 交互**：diff 新配置 vs 存活状态 → kill 变化 pane → 按新命令重建
- **判定：不能**。需要"配置 vs 实时状态"diff + 选择性回滚；one-shot 编译不支持

---

## 三、DevOps（9）

### D1 — Capistrano 蓝绿部署 + 健康检查
- **来源**：[feedbin/capistrano-bluey](https://github.com/feedbin/capistrano-bluey)
- **场景**：idle 颜色上启动新版本，健康检查通过后原子切换 nginx 流量
- **tmux 交互**：params(host,color) → run(启动 idle) → wait_for(/up 返回 2xx，timeout 90s) → branch（全健康→翻 symlink+reload；任一失败→stop+fail）
- **判定：能**。纯 run/wait_for/branch；失败时旧颜色从未停机，直接 abort 即可（无需回滚）

### D2 — Argo Rollouts 金丝雀发布
- **来源**：[argoproj/argo-rollouts docs/features/analysis.md](https://github.com/argoproj/argo-rollouts/blob/master/docs/features/analysis.md)
- **场景**：按 setWeight 阶梯放量，每步 pause 后跑 AnalysisTemplate 查成功率
- **tmux 交互**：run(apply) → wait_for(AnalysisRun 成功) → retry(failureLimit=3) → branch（失败→fail；成功→下一步放量）；背景分析与放量并发 = 一层 parallel
- **判定：部分能**。等待/判断/重试可编译；分析失败后自动降权回 0 是失败回滚语义，只能编译到 fail

### D3 — helm upgrade --wait 超时判定
- **来源**：[helm/helm#32214](https://github.com/helm/helm/issues/32214)
- **场景**：CI 部署 `helm upgrade --install --wait --timeout 10m`；issue 是 --wait 静默吞超时的回归 bug
- **tmux 交互**：run(helm upgrade --wait) → wait_for(ready) → branch（超时→fail；成功→继续）
- **判定：能**。单 wait_for + 超时分支；该 issue 恰好验证 wait_for 语义边界（静默吞超时必须判失败）

### D4 — CI 多阶段流水线（helm + smoke）
- **来源**：[kubestellar/console#20481](https://github.com/kubestellar/console/issues/20481)
- **场景**：Kind 集群里 helm install → 升级 → smoke；PVC Pending 导致 --wait 超时
- **tmux 交互**：run(install --wait) → wait_for(ready) → branch（超时→诊断+fail；成功→upgrade→smoke）
- **判定：能**。多阶段串行 + 超时分支，无嵌套无回滚

### D5 — on-call 故障排查 runbook
- **来源**：[cyber-minds runbook-terminal-outage.md](https://github.com/cyber-minds/cyber-minds.github.io/blob/HEAD/docs/runbook-terminal-outage.md)
- **场景**：6 步 triage 定位故障层级，重启服务并 curl /health 验证，3 次连续探针通过才算恢复
- **tmux 交互**：run(探针) → branch（按 checklist 定位层级，各走修复分支）→ run(restart) → wait_for(/health 200) → retry（失败→诊断→有界重试）→ branch（仍失败→fail 人工升级）
- **判定：部分能**。triage+重启+健康检查完全可编译；"git switch 到已知好提交"是回滚语义，45 分钟跨 workflow 确认超出单会话模型

### D6 — on-call 标准重启流程
- **来源**：[tim-dickey service-restart-runbook.md](https://github.com/tim-dickey/my-playbook-runbook-and-other-artifacts-repo/blob/HEAD/runbooks/service-restart-runbook.md)
- **场景**：查状态 → 抓日志 → 重启 → 验证 active
- **tmux 交互**：run(status) → branch（failed→继续；running→结束）→ run(导出日志) → run(restart) → wait_for(active) → retry → fail
- **判定：部分能**。"确认重启安全"是人工判断，需用 params 预置审批；其余可编译

### D7 — gh-ost 在线 schema 迁移
- **来源**：[github/gh-ost doc/cheatsheet.md](https://github.com/github/gh-ost/blob/HEAD/doc/cheatsheet.md)
- **场景**：MySQL 在线迁移：复制延迟超阈值自动 throttle，有界重试，flag 文件控制 cutover
- **tmux 交互**：run(gh-ost --execute) → wait_for(延迟降至阈值下) → retry（有界）→ branch（postpone flag→继续等；panic flag→fail）→ run(行数校验)
- **判定：能**。等待/判断/有界重试齐备；gh-ost 内部 throttle 是其自有逻辑，编译的是外层编排

### D8 — helm --atomic 部署+迁移一体
- **来源**：[imaustink/glyph@edc8da3](https://github.com/imaustink/glyph/commit/edc8da3b8f06a01b3c52e9b1416af16a7c5cee99)
- **场景**：migrate Job 做 pre-upgrade hook，init 容器阻塞等 schema，`helm upgrade --atomic --wait` 失败自动回滚
- **tmux 交互**：run(upgrade --wait) → wait_for(migrate Job 完成 + pods ready) → branch（migrate 失败→fail）
- **判定：部分能**。等待/判断可编译；--atomic 自动回滚由 Helm 执行，是明确不支持的失败回滚

### D9 — 条件发布门（测试矩阵全绿才发版）
- **来源**：[factusconsulting/whisper-dictate#695](https://github.com/factusconsulting/whisper-dictate/issues/695)
- **场景**：release workflow 重跑全量测试矩阵（unit/rust×2/…），全绿才发版；已绿提交跳过重复矩阵
- **tmux 交互**：parallel（测试矩阵各 leg，结果写文件）→ branch（全绿→release create；有失败→fail）→ branch（已绿→跳过矩阵）
- **判定：能**。单层 parallel + 文件通信正中约束；条件发布 = branch

---

## 四、覆盖度汇总

| 类别 | 能 | 部分能 | 不能 | 合计 |
|------|----|--------|------|------|
| 多 agent 编排 | 2 | 6 | 2 | 10 |
| tmux 自动化工具 | 6 | 2 | 2 | 10 |
| DevOps | 5 | 4 | 0 | 9 |
| **合计** | **13** | **12** | **4** | **29** |

### 甜蜜区

"静态 DAG + 文件通信 + 一层并行 + 有界重试"——13/29 全覆盖，
12/29 主干可覆盖。真实高频需求"等条件再发命令"（T4/T1/T8、D3/D4）
和"条件分支"（T2/T3、D1/D9）都在原语内。

### 三条最常超出的线

1. **无界循环**：review 收敛循环（M1）、/loop tick（M10）——retry 有界不支持
2. **人机交互门**：人工审批（M5/M6/D6）、人工确认节点（T6）——不支持交互式
3. **失败回滚 / 运行时干预**：自动降权（D2）、--atomic 回滚（D8）、
   send 纠偏（M8）、增量重建（T10）——明确不支持回滚

### 已实现为 example 的

| example | 对应 case |
|---------|----------|
| bug-hunt | 通用 bisect 模式（D5 triage 思想） |
| pr-review | M2（三路并行 review） |
| parallel-dev | M3（串行 staged）+ T5（并行拉起） |
| deploy-healthcheck（新增） | D1（蓝绿+健康检查） |
| retry-until-ready（新增） | D7（gh-ost 等待+重试） |
| conditional-setup（新增） | T2（按探测条件分支） |
