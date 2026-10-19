---------------------------- MODULE TaskLease ----------------------------
(* §11 任务层：一个任务的租约 + fencing token。
   未经 TLC 检查（本机没有 Java）。只用于说明安全性质。
   时间抽象为 Expire 动作：租约随时可能过期。 *)
EXTENDS Naturals

CONSTANTS Workers, MaxToken

VARIABLES state,      \* "pending" | "claimed" | "completed"
          token,      \* 当前 fencing token
          holder,     \* 当前持有者，或 "none"
          held,       \* held[w] = w 认为自己持有的 token（0 = 不持有）
          doneToken   \* 完成时的 token（0 = 未完成）

vars == <<state, token, holder, held, doneToken>>

Init == /\ state = "pending" /\ token = 0 /\ holder = "none"
        /\ held = [w \in Workers |-> 0] /\ doneToken = 0

Claim(w) == /\ state = "pending" /\ token < MaxToken
            /\ token' = token + 1 /\ state' = "claimed" /\ holder' = w
            /\ held' = [held EXCEPT ![w] = token + 1]
            /\ UNCHANGED doneToken

\* 租约过期：server 侧回 pending。worker 不知道，仍保留旧 token。
Expire == /\ state = "claimed" /\ state' = "pending" /\ holder' = "none"
          /\ UNCHANGED <<token, held, doneToken>>

\* complete：server 只接受当前 token 且仍在 claimed 的请求。
Complete(w) == /\ held[w] # 0
               /\ IF held[w] = token /\ state = "claimed"
                  THEN /\ state' = "completed" /\ doneToken' = held[w]
                       /\ holder' = "none"
                  ELSE UNCHANGED <<state, doneToken, holder>>  \* AEVT-4101
               /\ held' = [held EXCEPT ![w] = 0]
               /\ UNCHANGED token

Next == \/ \E w \in Workers : Claim(w) \/ Complete(w)
        \/ Expire

Spec == Init /\ [][Next]_vars

\* 性质
TypeOK == token \in 0..MaxToken
\* 完成者的 token 一定是最后一次认领的 token
CompletedByCurrent == state = "completed" => doneToken = token
\* 最多一个 worker 持有当前有效 token
SingleValidHolder == \A w1, w2 \in Workers :
    (held[w1] = token /\ held[w2] = token /\ token > 0 /\ state = "claimed")
        => w1 = w2
\* token 单调（动作性质）
TokenMonotonic == [][token' >= token]_vars
=============================================================================
