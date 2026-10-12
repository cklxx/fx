# retry — 设计文档

## 1. 为什么这样设计

异构分解验证（`benchmarks/agent-bench/HETEROGENEOUS.md` §2）的结论：fx
缺"执行后验证 + 失败重试"——小模型犯错（漏写内容、写错路径、非法参数）
时全部硬失败。重试层是异构分解的前置条件：没有它，小模型每轮错误率 p
直接按 `(1-p)^N` 拖垮端到端成功率；有了它，transient 错误被吸收在执行层，
不向上传播。

设计抓三个区分，来自验证报告 §2.1 的三类退化：

| 失败类 | 例子 | 策略 |
|---|---|---|
| transient（可恢复） | missing-item：report 漏写 gamma，重跑能写对 | 重试 |
| permanent（重跑无用） | wrong-path 写死在命令里；invalid-arg 非法参数 | fail fast，不重试 |
| config（规则本身错） | 未知 validator 类型、坏正则 | 执行前抛 ConfigError，零次执行 |

关键决策：**引擎不猜类别，spec 作者声明**。`retryable: false`
标记 permanent 类。自动分类（比如"exit code 2 永不重试"）看起来聪明，
实则是启发式误判的来源——同一个 exit code 在不同工具里含义不同。
原型阶段显式声明比智能推断可靠。

第二个决策：**验证是后验的（post-hoc），不是内联的**。validator 只读
exit code / stdout / stderr / 文件存在，不 hook 工具内部。
代价是表达力有限（看不到工具的中间状态），收益是零侵入：
不碰 `src/`，任何命令都能套。

第三个决策：**config 错误在第一次执行前全部暴露**。
validator 在循环外一次编译，坏规则抛 ConfigError 且不计入重试。
否则"规则写错"会被当成"命令失败"重试 N 次，浪费且误导。

## 2. 判定：什么算失败

- 每个 validator 有 `severity`：`error`（默认）失败计入 verdict；
  `warn` 只记录，不影响成败。warn 用于"想看但不想卡"的信号
  （如输出里出现 deprecation 警告）。
- failure ⇔ 任一 severity=error 的 validator 未通过。
- fail fast ⇔ 失败集合里有 `retryable: false` 的 validator。
  第一个 fail-fast 的 attempt 即终止，不 sleep、不重试。
- 超时（timeout_s）视为一次失败的 attempt，可重试。
  spawn 失败（命令不存在）同样处理：环境抖动是 transient 的常见来源。

## 3. 重试策略

- `max_attempts`（默认 3），含第一次执行。
- backoff：`none` / `fixed` / `exponential`（默认），
  `delay = min(base * 2^(n-1), max_delay)`，jitter 默认开
  （`uniform(0, delay)`，防 thundering herd）。
- 退避只发生在 transient 失败之间；fail-fast 和 config 错误不退避。

## 4. 边界（不做什么）

1. **不做升级触发器**。验证报告假设的"小模型置信度低 → 转大模型"
   机制不存在，本原型也不造：重试的是同一命令。升级是调度层的事。
2. **不做跨 attempt 的状态修复**。重试 = 原样重跑命令。
   "清理半成品再重跑"需要 cleanup hook，这是下一步，不是这一步。
3. **validator 只有三种**。`exit_code` / `pattern` / `file_exists`
   覆盖验证报告的三类退化。JSON 输出断言、文件内容 diff、自定义
   Python predicate 都在范围外——原型先证明闭环，扩展点在
   `validators.py` 的 `_VALIDATORS` 注册表，加一种约 20 行。
4. **不进 `src/`**。fx 核心集成（tool 调用后自动套 retry、
   permission 系统交互）是后续提案事项，见 §6。
5. **单机、同步、单命令**。无并发、无分布式、无 DAG。
   tmux_compile 负责编排多步，retry 负责单步的韧性；两者正交可组合。
6. **输出截断**。每个 attempt 存 stdout/stderr 各前 4096 字符
   （`stdout_limit` 可配）。长输出不进内存，由调用方按需重定向到文件
   再用 `file_exists`/`pattern` 验证。

## 5. 与现有工具的关系

```
tool 调用 → [retry: 执行+验证+重试] → 成功/失败 verdict → agent
```

- `tools/sock`：agent 与外部进程的通信协议层。retry 消费它的执行结果，
  不替代它。未来 fx 集成时，retry verdict 可以经 OSC 7501 上报
 （`state=working` 重试中 / `state=done|error` 终态）。
- `tools/tmux_compile`：编译多步确定性流程。retry 是单步韧性，
  可以包在 tmux_compile 的某一步里（"这一步用 retry 跑"），
  也可以独立用。两者不重叠。

## 6. 后续提案（未动手，需评审）

- P1：fx `src/` 集成点。候选：`src/tools/` 的 shell 工具调用后接
  retry verdict；或 agent loop 层统一包装。涉及 permission 语义
  （重试是否重新走审批），需提案评审，不直接动手。
- P2：cleanup hook（attempt 间清理半成品）。
- P3：validator 扩展（JSON path 断言、文件内容正则）。
- P4：verdict 上报 OSC 7501，与 awb 看板打通。

## 7. dogfooding 发现

用自家工具链（sock 的 OSC 7501 emitter）时遇到的问题：

1. **emitter 在裸终端输出转义序列是不可见的**。`emit()` 返回
   `ESC ] 7501 ...` 序列，直接 `print` 到普通终端无任何可见反馈；
   只有接了 7501 解析器的终端（或 `agent_sock` 的 record store）才有意义。
   期望落差：初次使用以为"上报了"，实际石沉大海。建议 emitter 加一个
   `human=True` 模式，同时打印一行人类可读的 `state=... msg=...`。
2. **`id` 格式限制文档不足**。`_valid_id` 要求每段 32 字符、最多 8 段，
   违反时抛 ValueError；但什么算合法 id 只在正则里，没有一句话说明。
   试错一次才摸清。
3. **tmux_compile 未直接使用**。本任务是单命令重试，不需要多步编排；
   强行套用反而增加复杂度。结论：retry 与 tmux_compile 是互补关系，
   不是替代关系（§5 已记录）。

## 8. 测试

`python3 -m unittest discover -s tests`，17 个用例，全自动化：

- 成功一次过；flaky 第三次成功（重试 2 次）；重试耗尽（3 次全记）
- 配置错误 4 类：未知 validator 类型、坏正则、缺必填 key、
  非法 policy 值（max_attempts=0、非法 backoff）——全部抛 ConfigError
  且零次执行
- pattern 正/负向；file_exists 通过/失败；warn 不触发失败
- `retryable: false` fail fast（恰好 1 次 attempt，零 sleep）
- 指数退避 1/2/4s、上限截断；超时重试
- CLI 端到端：成功/耗尽/配置错误的 exit code（0/1/2）与 `--json` 输出
