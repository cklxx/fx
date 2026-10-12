------------------------------ MODULE ReqReply ------------------------------
(***************************************************************************)
(* Agent Sock 请求/应答关联模型 (REVIEW.md R-01 修复):                         *)
(*   - 请求带客户端分配的单调 seq                                          *)
(*   - 应答带 in_reply_to = 原请求 seq (R-01 修复: ack 只做传输确认,        *)
(*     不做请求关联)                                                        *)
(*   - 覆盖流水线 (多请求在途) 与乱序应答 —— 正是 R-01 反例的场景            *)
(*     (register seq=1, card seq=2; server 先回 card 应答)                   *)
(*                                                                           *)
(* 验证: ReplyCorrelates —— 应答的 in_reply_to 必对应一个已发送的请求 seq    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANT NReqs

ASSUME NReqs \in Nat /\ NReqs > 0

VARIABLES
    sent,       \* 客户端已发送的请求 seq 集合
    nextSeq,    \* 下一个待分配的请求 seq
    inbox,      \* server 侧待处理请求 seq 集合 (在途, 支持乱序处理)
    replies     \* 客户端已收到的应答: [in_reply_to |-> seq] 记录集合

vars == <<sent, nextSeq, inbox, replies>>

TypeOK ==
    /\ sent \subseteq 1..NReqs
    /\ nextSeq \in 1..NReqs+1
    /\ inbox \subseteq sent
    /\ replies \subseteq [in_reply_to : 1..NReqs]

Init ==
    /\ sent = {}
    /\ nextSeq = 1
    /\ inbox = {}
    /\ replies = {}

(* 客户端发请求: 分配新 seq, 进入在途集合 *)
SendReq ==
    /\ nextSeq <= NReqs
    /\ sent' = sent \cup {nextSeq}
    /\ inbox' = inbox \cup {nextSeq}
    /\ nextSeq' = nextSeq + 1
    /\ UNCHANGED replies

(* server 处理请求 s, 应答携带 in_reply_to = s —— R-01 修复的核心。          *)
(* 可任选在途请求, 故允许乱序应答 (先回 seq=2 再回 seq=1)。                 *)
Reply(s) ==
    /\ s \in inbox
    /\ inbox' = inbox \ {s}
    /\ replies' = replies \cup {[in_reply_to |-> s]}
    /\ UNCHANGED <<sent, nextSeq>>

(* 终态自循环, 避免 TLC 报 deadlock *)
Done ==
    /\ sent = 1..NReqs
    /\ inbox = {}
    /\ UNCHANGED vars

Next ==
    \/ SendReq
    \/ \E s \in 1..NReqs : Reply(s)
    \/ Done

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* R-01 性质: 应答的 in_reply_to 必对应一个已发送的请求 seq。                *)
(* 旧设计 (累计 ack 关联) 下此性质无法表述: ack=2 不标识对应 seq=1 或 seq=2。*)
(***************************************************************************)
ReplyCorrelates ==
    \A r \in replies : r.in_reply_to \in sent

Safety == ReplyCorrelates

=============================================================================
