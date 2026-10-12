------------------------------ MODULE WorkQueue ------------------------------
(***************************************************************************)
(* Agent Sock 消息队列模型 v4 (DESIGN.md §3):                                  *)
(*                                                                           *)
(* v4 相对 v3 的变更 (REVIEW.md R-05 修复):                                    *)
(*   - 加 cancelled 集合 (server 侧 tombstone)                                 *)
(*   - 加 Cancel 动作: queue.cancel(task_id) 把 queued 任务记入 tombstone      *)
(*   - Deliver 投递前检查 cancelled, 已取消的不投递                           *)
(*   - 加安全性质 P7 CancelledNeverDelivered                                   *)
(*                                                                           *)
(* v3 相对 v2.1 的删减 (全部经 S1-S4 论证, 见 SIMPLIFICATION.md):              *)
(*   - 删 partition_key / sticky 分配 / assign 表 / clean / firstOrder        *)
(*   - 删 Rebalance 动作 (无 sticky 状态可重算; Leave 回收即全部)              *)
(*   - 删 Nack 独立动作 (S3: ack+requeue 与 Timeout 字面相同的状态转移)       *)
(*   - 加 RequeueOrDead 单个重入原语 (S2: 修复 Issue #1/#2, 三处归一)         *)
(*                                                                           *)
(* 保留: Publish / Deliver / Ack / Timeout / Join / Leave / Done / Cancel    *)
(* 验证: P1-P4, P7 安全 + 活性 (成员非空假设 A1; 取消任务终态见 Done 注)      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANT NMsgs, NConsumers, MaxDeliver

ASSUME NMsgs \in Nat /\ NMsgs > 0
ASSUME NConsumers \in Nat /\ NConsumers > 0
ASSUME MaxDeliver \in Nat /\ MaxDeliver > 0

Msgs == 1..NMsgs
Consumers == 1..NConsumers

States == {"absent", "queued", "pending", "acked", "dead"}

VARIABLES
    published,    \* 已 publish 的 mid 集合
    state,        \* [mid |-> States]
    pendCons,     \* [mid |-> 持有该消息的消费者, 0=无]
    pendCount,    \* [mid |-> 已投递次数]
    seen,         \* [c |-> 该消费者见过的 mid 集合] (message_id 去重)
    effectCnt,    \* [c |-> [mid |-> 0..1]] 副作用执行次数
    members,      \* 当前 group 成员集合
    cancelled     \* R-05: server 侧 tombstone, 已取消的 mid 集合

vars == <<published, state, pendCons, pendCount, seen, effectCnt, members,
          cancelled>>

TypeOK ==
    /\ published \subseteq Msgs
    /\ state \in [Msgs -> States]
    /\ pendCons \in [Msgs -> 0..NConsumers]
    /\ pendCount \in [Msgs -> 0..MaxDeliver]
    /\ seen \in [Consumers -> SUBSET Msgs]
    /\ effectCnt \in [Consumers -> [Msgs -> 0..1]]
    /\ members \subseteq Consumers
    /\ cancelled \subseteq Msgs

Init ==
    /\ published = {}
    /\ state = [m \in Msgs |-> "absent"]
    /\ pendCons = [m \in Msgs |-> 0]
    /\ pendCount = [m \in Msgs |-> 0]
    /\ seen = [c \in Consumers |-> {}]
    /\ effectCnt = [c \in Consumers |-> [m \in Msgs |-> 0]]
    /\ members = Consumers        \* 初始全体成员在线 (Join/Leave 可动态变化)
    /\ cancelled = {}

(***************************************************************************)
(* S2: requeue_or_dead —— 唯一重入原语                                      *)
(*   Timeout / Leave / ack+requeue(原nack) 三处都归约到它。                  *)
(*   返回 [st, pc]: 重入后的 state 与 pendCons。                             *)
(***************************************************************************)
RequeueOrDead(m) ==
    IF pendCount[m] >= MaxDeliver
    THEN [st |-> "dead", pc |-> 0]
    ELSE [st |-> "queued", pc |-> 0]

(***************************************************************************)
(* 生产者 / 成员管理                                                       *)
(***************************************************************************)
Publish(m) ==
    /\ m \in Msgs
    /\ state[m] = "absent"
    /\ published' = published \cup {m}
    /\ state' = [state EXCEPT ![m] = "queued"]
    /\ UNCHANGED <<pendCons, pendCount, seen, effectCnt, members, cancelled>>

Join(c) ==
    /\ c \in Consumers
    /\ c \notin members
    /\ members' = members \cup {c}
    (* v3: 无 sticky 状态, 新成员直接参与投递, 无需 rebalance *)
    /\ UNCHANGED <<published, state, pendCons, pendCount, seen, effectCnt,
                   cancelled>>

Leave(c) ==
    /\ c \in members
    /\ members' = members \ {c}
    (* S2: 离场成员的 in-flight 经 requeue_or_dead 回池；打满进死信 *)
    /\ state' = [m \in Msgs |-> IF state[m] = "pending" /\ pendCons[m] = c
                                 THEN RequeueOrDead(m).st ELSE state[m]]
    /\ pendCons' = [m \in Msgs |-> IF state[m] = "pending" /\ pendCons[m] = c
                                 THEN RequeueOrDead(m).pc ELSE pendCons[m]]
    /\ UNCHANGED <<published, pendCount, seen, effectCnt, cancelled>>

(***************************************************************************)
(* R-05: queue.cancel(task_id) —— server 把任务记入 tombstone                 *)
(*   - 只针对 queued 任务: 在途 (pending) 任务已投递, 取消是 no-op             *)
(*     (worker 侧取消超出本模型范围); acked/dead/absent 任务取消无意义       *)
(*   - tombstone 持久: Timeout/Leave 重入后 Deliver 仍会过滤 (P7 的关键)      *)
(***************************************************************************)
Cancel(m) ==
    /\ m \in Msgs
    /\ state[m] = "queued"
    /\ m \notin cancelled
    /\ cancelled' = cancelled \cup {m}
    /\ UNCHANGED <<published, state, pendCons, pendCount, seen, effectCnt,
                   members>>

(***************************************************************************)
(* 投递: 取 queued 中最小 mid (FIFO)。任选在线成员 (v3: 无 sticky)。        *)
(* R-05: 投递前检查 cancelled, 已取消的不投递。                              *)
(***************************************************************************)
Deliver ==
    /\ members # {}
    /\ \E m \in Msgs, t \in Consumers :
        /\ state[m] = "queued"
        /\ m \notin cancelled              \* R-05: tombstone 过滤
        (* FIFO: 取 queued 且未取消中的最小 mid (tombstone 不占队头) *)
        /\ \A n \in Msgs : state[n] = "queued" /\ n \notin cancelled => m <= n
        /\ t \in members
        /\ state' = [state EXCEPT ![m] = "pending"]
        /\ pendCons' = [pendCons EXCEPT ![m] = t]
        /\ pendCount' = [pendCount EXCEPT ![m] = @ + 1]
        (* 消费者侧幂等: message_id 去重, 副作用至多一次 *)
        /\ seen' = [seen EXCEPT ![t] = @ \cup {m}]
        /\ effectCnt' = IF m \in seen[t] THEN effectCnt
                        ELSE [effectCnt EXCEPT ![t] =
                                [mm \in Msgs |-> IF mm = m THEN 1
                                                 ELSE effectCnt[t][mm]]]
    /\ UNCHANGED <<published, members, cancelled>>

Ack(c, m) ==
    /\ m \in Msgs /\ c \in Consumers
    /\ state[m] = "pending"
    /\ pendCons[m] = c
    /\ state' = [state EXCEPT ![m] = "acked"]
    /\ pendCons' = [pendCons EXCEPT ![m] = 0]
    /\ UNCHANGED <<published, pendCount, seen, effectCnt, members, cancelled>>

(***************************************************************************)
(* ack_wait 超时: 过近似为"pending 消息可随时超时"。                        *)
(* S3: 消费者请求的提前超时 (wire 层 ack+<requeue/>) 与它是同一转移,        *)
(*     模型中不单独建模。                                                  *)
(***************************************************************************)
Timeout(m) ==
    /\ m \in Msgs
    /\ state[m] = "pending"
    /\ LET r == RequeueOrDead(m) IN
       /\ state' = [state EXCEPT ![m] = r.st]
       /\ pendCons' = [pendCons EXCEPT ![m] = r.pc]
    /\ UNCHANGED <<published, pendCount, seen, effectCnt, members, cancelled>>

(***************************************************************************)
(* 终态自循环, 避免 TLC 报 deadlock。                                        *)
(* R-05: 已取消的 queued 任务是 tombstone 终态 (保留在 queued, 永不投递),    *)
(* 不计入 acked/dead。                                                       *)
(***************************************************************************)
Done ==
    /\ \A m \in Msgs : m \in published =>
           state[m] \in {"acked", "dead"} \/ m \in cancelled
    /\ UNCHANGED vars

Next ==
    \/ \E m \in Msgs : Publish(m)
    \/ \E c \in Consumers : Join(c)
    \/ \E c \in Consumers : Leave(c)
    \/ Deliver
    \/ \E c \in Consumers, m \in Msgs : Ack(c, m)
    \/ \E m \in Msgs : Timeout(m)
    \/ \E m \in Msgs : Cancel(m)
    \/ Done

SpecSafe == Init /\ [][Next]_vars

SpecLive == Init /\ [][Next]_vars
    /\ WF_vars(Deliver)
    /\ \A mm \in Msgs : WF_vars(Timeout(mm))
    /\ \A c \in Consumers, nn \in Msgs : WF_vars(Ack(c, nn))

Spec == SpecLive

(***************************************************************************)
(* 安全性质 (v4: P1-P4 + P7。P5/P6 随 partition_key 删除)                    *)
(***************************************************************************)
(* P1: pending 消息的持有者必在线 (Leave 原子回收, 无孤儿 in-flight) *)
PendingHolderActive ==
    \A m \in Msgs : state[m] = "pending" => pendCons[m] \in members

(* P2: 幂等 — 同一消费者对同一消息的副作用至多执行一次 *)
AtMostOnceEffect ==
    \A c \in Consumers, m \in Msgs : effectCnt[c][m] <= 1

(* P3: 死信只发生在投递次数打满 MaxDeliver 之后 *)
DeadOnlyAfterMaxDeliver ==
    \A m \in Msgs : state[m] = "dead" => pendCount[m] = MaxDeliver

(* P4: 无幻影 — queued/pending 的消息必已 publish *)
NoPhantom ==
    \A m \in Msgs : state[m] \in {"queued", "pending"} => m \in published

(* P7 (R-05): 已取消的任务永不被投递 — tombstone 生效后消息不再进 pending,  *)
(* 即使经 Timeout/Leave 重入再 Deliver 也被过滤 (tombstone 持久)             *)
CancelledNeverDelivered ==
    \A m \in Msgs : m \in cancelled => state[m] # "pending"

Safety == PendingHolderActive /\ AtMostOnceEffect /\
          DeadOnlyAfterMaxDeliver /\ NoPhantom /\
          CancelledNeverDelivered

(***************************************************************************)
(* 活性: 每条 publish 的消息最终到达终态: acked、死信, 或被取消               *)
(* (需成员存在, 见 A1)。取消是合法终态 (tombstone 持久保留), 与 v3 一致,     *)
(* "终态"即不再需要投递。                                                   *)
(***************************************************************************)
Liveness ==
    \A m \in Msgs : (m \in published)
                    ~> (state[m] \in {"acked", "dead"} \/ m \in cancelled)

\* 活性假设 A1 (供 cfg CONSTRAINT 用): group 内始终至少一个成员
NonEmptyMembers == members # {}

=============================================================================
