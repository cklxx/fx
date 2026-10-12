------------------------------- MODULE SeqAck -------------------------------
(***************************************************************************)
(* Agent Sock 传输层模型 (DESIGN.md §2.2):                                     *)
(*   - 发送方为每条消息分配单调 seq                                          *)
(*   - 接收方累计 ack (TCP 式: ackedUpTo = 已收到的最大连续 seq)               *)
(*   - 网络可丢包、可重包 (用 lossBudget 界定, 公平性假设下验证收敛)          *)
(*   - 发送方对未 ack 消息重传; 接收方用 received 集合去重 (幂等)             *)
(*                                                                           *)
(* 验证目标: at-least-once + 接收方去重  ==>  恰好一次副作用                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANT NMSGS      \* 发送的消息总数 (有界模型)
CONSTANT LOSS       \* 网络最多丢弃的数据包总数 (有界丢包假设)

VARIABLES
    sent,       \* 已交给传输层的 seq 集合
    unacked,    \* 已发送但未被 ack 的 seq 集合
    nextSeq,    \* 下一个待分配的 seq
    chanS2R,    \* S->R 信道: bag, [seq |-> 在途份数]
    chanR2S,    \* R->S 信道: bag, [ack值 |-> 在途份数]
    received,   \* 接收方已接受的 seq 集合 (去重后)
    ackedUpTo,  \* 接收方累计 ack 点: 1..ackedUpTo 全部已收到
    ackSent,    \* 已发送过的最大 ack 值 (避免 ack 无限增发)
    effects,    \* [seq |-> 副作用执行次数], 验证幂等
    budget      \* 剩余可丢包预算

vars == <<sent, unacked, nextSeq, chanS2R, chanR2S,
          received, ackedUpTo, ackSent, effects, budget>>

TypeOK ==
    /\ sent \subseteq 1..NMSGS
    /\ unacked \subseteq sent
    /\ nextSeq \in 1..NMSGS+1
    /\ chanS2R \in [1..NMSGS -> 0..NMSGS+LOSS]
    /\ chanR2S \in [0..NMSGS -> 0..NMSGS+LOSS]
    /\ received \subseteq sent
    /\ ackedUpTo \in 0..NMSGS
    /\ ackSent \in 0..NMSGS
    /\ ackSent <= ackedUpTo
    /\ effects \in [1..NMSGS -> 0..1]
    /\ budget \in 0..LOSS

Init ==
    /\ sent = {}
    /\ unacked = {}
    /\ nextSeq = 1
    /\ chanS2R = [s \in 1..NMSGS |-> 0]
    /\ chanR2S = [a \in 0..NMSGS |-> 0]
    /\ received = {}
    /\ ackedUpTo = 0
    /\ ackSent = 0
    /\ effects = [s \in 1..NMSGS |-> 0]
    /\ budget = LOSS

(***************************************************************************)
(* 发送方动作                                                              *)
(***************************************************************************)
Send ==
    /\ nextSeq <= NMSGS
    /\ sent' = sent \cup {nextSeq}
    /\ unacked' = unacked \cup {nextSeq}
    /\ chanS2R' = [chanS2R EXCEPT ![nextSeq] = @ + 1]
    /\ nextSeq' = nextSeq + 1
    /\ UNCHANGED <<chanR2S, received, ackedUpTo, ackSent, effects, budget>>

Retransmit(s) ==
    /\ s \in unacked
    /\ chanS2R[s] < NMSGS + LOSS   \* 信道有界, 防无限重传撑爆状态空间
    /\ chanS2R' = [chanS2R EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<sent, unacked, nextSeq, chanR2S, received,
                   ackedUpTo, ackSent, effects, budget>>

ReceiveAck(a) ==
    /\ a \in 0..NMSGS
    /\ chanR2S[a] > 0
    /\ chanR2S' = [chanR2S EXCEPT ![a] = @ - 1]
    /\ unacked' = {s \in unacked : s > a}
    /\ UNCHANGED <<sent, nextSeq, chanS2R, received, ackedUpTo,
                   ackSent, effects, budget>>

(***************************************************************************)
(* 接收方动作                                                              *)
(***************************************************************************)
Receive(s) ==
    /\ s \in 1..NMSGS
    /\ chanS2R[s] > 0
    /\ chanS2R' = [chanS2R EXCEPT ![s] = @ - 1]
    /\ received' = received \cup {s}
    /\ effects' = IF s \in received THEN effects
                  ELSE [effects EXCEPT ![s] = 1]  \* 幂等: 只执行一次
    /\ ackedUpTo' = CHOOSE n \in 0..NMSGS :
                        /\ \A k \in 1..n : k \in received'
                        /\ n = NMSGS \/ (n+1) \notin received'
    /\ UNCHANGED <<sent, unacked, nextSeq, chanR2S,
                   ackSent, budget>>

SendAck ==
    /\ ackedUpTo > ackSent
    /\ ackedUpTo > 0
    /\ chanR2S' = [chanR2S EXCEPT ![ackedUpTo] = @ + 1]
    /\ ackSent' = ackedUpTo
    /\ UNCHANGED <<sent, unacked, nextSeq, chanS2R, received,
                   ackedUpTo, effects, budget>>

ResendAck ==
    /\ ackSent > 0
    /\ chanR2S[ackSent] < NMSGS + LOSS   \* 信道有界
    /\ chanR2S' = [chanR2S EXCEPT ![ackSent] = @ + 1]
    /\ UNCHANGED <<sent, unacked, nextSeq, chanS2R, received,
                   ackedUpTo, ackSent, effects, budget>>

(***************************************************************************)
(* 网络动作: 丢包 (受预算限制) / ack 丢包                                   *)
(***************************************************************************)
DropData(s) ==
    /\ s \in 1..NMSGS
    /\ chanS2R[s] > 0
    /\ budget > 0
    /\ chanS2R' = [chanS2R EXCEPT ![s] = @ - 1]
    /\ budget' = budget - 1
    /\ UNCHANGED <<sent, unacked, nextSeq, chanR2S, received,
                   ackedUpTo, ackSent, effects>>

DropAck(a) ==
    /\ a \in 0..NMSGS
    /\ chanR2S[a] > 0
    /\ budget > 0
    /\ chanR2S' = [chanR2S EXCEPT ![a] = @ - 1]
    /\ budget' = budget - 1
    /\ UNCHANGED <<sent, unacked, nextSeq, chanS2R, received,
                   ackedUpTo, ackSent, effects>>

Next ==
    \/ Send
    \/ \E s \in 1..NMSGS : Retransmit(s)
    \/ \E a \in 0..NMSGS : ReceiveAck(a)
    \/ \E s \in 1..NMSGS : Receive(s)
    \/ SendAck
    \/ ResendAck
    \/ \E s \in 1..NMSGS : DropData(s)
    \/ \E a \in 0..NMSGS : DropAck(a)

RecvAck == \E a \in 0..NMSGS : ReceiveAck(a)

SpecSafe == Init /\ [][Next]_vars

SpecLive == Init /\ [][Next]_vars
    /\ \A s \in 1..NMSGS : SF_vars(Receive(s))   \* 数据包: 逐包强公平, 防饿死
    /\ \A t \in 1..NMSGS : WF_vars(Retransmit(t))
    /\ WF_vars(SendAck)
    /\ WF_vars(ResendAck)
    /\ SF_vars(RecvAck)   \* ack 累计语义: 按值饿死无害, 存在量词足够

(***************************************************************************)
(* 安全性质                                                                *)
(***************************************************************************)
NoPhantomRecv == received \subseteq sent
AckSound == \A s \in sent : s \notin unacked => s \in received
AtMostOnceEffect == \A s \in 1..NMSGS : effects[s] <= 1
AckContiguous == \A k \in 1..ackedUpTo : k \in received

Safety == NoPhantomRecv /\ AckSound /\ AtMostOnceEffect /\ AckContiguous

(***************************************************************************)
(* 活性: 有界丢包 + 重传公平 ==> 每条消息最终被收到且被 ack                  *)
(***************************************************************************)
Liveness == /\ \A s \in 1..NMSGS : (s \in sent) ~> (s \in received)
            /\ (sent = 1..NMSGS) ~> (unacked = {})

=============================================================================
