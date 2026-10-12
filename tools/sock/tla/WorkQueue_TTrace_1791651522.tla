---- MODULE WorkQueue_TTrace_1791651522 ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, WorkQueue

_expression ==
    LET WorkQueue_TEExpression == INSTANCE WorkQueue_TEExpression
    IN WorkQueue_TEExpression!expression
----

_trace ==
    LET WorkQueue_TETrace == INSTANCE WorkQueue_TETrace
    IN WorkQueue_TETrace!trace
----

_prop ==
    ~<>[](
        pendCons = (<<0, 0, 0>>)
        /\
        members = (1..2)
        /\
        cancelled = ({1, 2, 3})
        /\
        pendCount = (<<0, 0, 0>>)
        /\
        state = (<<"queued", "queued", "queued">>)
        /\
        published = ({1, 2, 3})
        /\
        effectCnt = (<<<<0, 0, 0>>, <<0, 0, 0>>>>)
        /\
        seen = (<<{}, {}>>)
    )
----

_init ==
    /\ state = _TETrace[1].state
    /\ cancelled = _TETrace[1].cancelled
    /\ seen = _TETrace[1].seen
    /\ pendCount = _TETrace[1].pendCount
    /\ published = _TETrace[1].published
    /\ pendCons = _TETrace[1].pendCons
    /\ effectCnt = _TETrace[1].effectCnt
    /\ members = _TETrace[1].members
----

_next ==
    /\ \E i,j \in DOMAIN _TETrace:
        /\ \/ /\ j = i + 1
              /\ i = TLCGet("level")
        /\ state  = _TETrace[i].state
        /\ state' = _TETrace[j].state
        /\ cancelled  = _TETrace[i].cancelled
        /\ cancelled' = _TETrace[j].cancelled
        /\ seen  = _TETrace[i].seen
        /\ seen' = _TETrace[j].seen
        /\ pendCount  = _TETrace[i].pendCount
        /\ pendCount' = _TETrace[j].pendCount
        /\ published  = _TETrace[i].published
        /\ published' = _TETrace[j].published
        /\ pendCons  = _TETrace[i].pendCons
        /\ pendCons' = _TETrace[j].pendCons
        /\ effectCnt  = _TETrace[i].effectCnt
        /\ effectCnt' = _TETrace[j].effectCnt
        /\ members  = _TETrace[i].members
        /\ members' = _TETrace[j].members

\* Uncomment the ASSUME below to write the states of the error trace
\* to the given file in Json format. Note that you can pass any tuple
\* to `JsonSerialize`. For example, a sub-sequence of _TETrace.
    \* ASSUME
    \*     LET J == INSTANCE Json
    \*         IN J!JsonSerialize("WorkQueue_TTrace_1791651522.json", _TETrace)

=============================================================================

 Note that you can extract this module `WorkQueue_TEExpression`
  to a dedicated file to reuse `expression` (the module in the 
  dedicated `WorkQueue_TEExpression.tla` file takes precedence 
  over the module `WorkQueue_TEExpression` below).

---- MODULE WorkQueue_TEExpression ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, WorkQueue

expression == 
    [
        \* To hide variables of the `WorkQueue` spec from the error trace,
        \* remove the variables below.  The trace will be written in the order
        \* of the fields of this record.
        state |-> state
        ,cancelled |-> cancelled
        ,seen |-> seen
        ,pendCount |-> pendCount
        ,published |-> published
        ,pendCons |-> pendCons
        ,effectCnt |-> effectCnt
        ,members |-> members
        
        \* Put additional constant-, state-, and action-level expressions here:
        \* ,_stateNumber |-> _TEPosition
        \* ,_stateUnchanged |-> state = state'
        
        \* Format the `state` variable as Json value.
        \* ,_stateJson |->
        \*     LET J == INSTANCE Json
        \*     IN J!ToJson(state)
        
        \* Lastly, you may build expressions over arbitrary sets of states by
        \* leveraging the _TETrace operator.  For example, this is how to
        \* count the number of times a spec variable changed up to the current
        \* state in the trace.
        \* ,_stateModCount |->
        \*     LET F[s \in DOMAIN _TETrace] ==
        \*         IF s = 1 THEN 0
        \*         ELSE IF _TETrace[s].state # _TETrace[s-1].state
        \*             THEN 1 + F[s-1] ELSE F[s-1]
        \*     IN F[_TEPosition - 1]
    ]

=============================================================================



Parsing and semantic processing can take forever if the trace below is long.
 In this case, it is advised to uncomment the module below to deserialize the
 trace from a generated binary file.

\*
\*---- MODULE WorkQueue_TETrace ----
\*EXTENDS IOUtils, TLC, WorkQueue
\*
\*trace == IODeserialize("WorkQueue_TTrace_1791651522.bin", TRUE)
\*
\*=============================================================================
\*

---- MODULE WorkQueue_TETrace ----
EXTENDS TLC, WorkQueue

trace == 
    <<
    ([pendCons |-> <<0, 0, 0>>,members |-> 1..2,cancelled |-> {},pendCount |-> <<0, 0, 0>>,state |-> <<"absent", "absent", "absent">>,published |-> {},effectCnt |-> <<<<0, 0, 0>>, <<0, 0, 0>>>>,seen |-> <<{}, {}>>]),
    ([pendCons |-> <<0, 0, 0>>,members |-> 1..2,cancelled |-> {},pendCount |-> <<0, 0, 0>>,state |-> <<"queued", "absent", "absent">>,published |-> {1},effectCnt |-> <<<<0, 0, 0>>, <<0, 0, 0>>>>,seen |-> <<{}, {}>>]),
    ([pendCons |-> <<0, 0, 0>>,members |-> 1..2,cancelled |-> {},pendCount |-> <<0, 0, 0>>,state |-> <<"queued", "absent", "queued">>,published |-> {1, 3},effectCnt |-> <<<<0, 0, 0>>, <<0, 0, 0>>>>,seen |-> <<{}, {}>>]),
    ([pendCons |-> <<0, 0, 0>>,members |-> 1..2,cancelled |-> {1},pendCount |-> <<0, 0, 0>>,state |-> <<"queued", "absent", "queued">>,published |-> {1, 3},effectCnt |-> <<<<0, 0, 0>>, <<0, 0, 0>>>>,seen |-> <<{}, {}>>]),
    ([pendCons |-> <<0, 0, 0>>,members |-> 1..2,cancelled |-> {1, 3},pendCount |-> <<0, 0, 0>>,state |-> <<"queued", "absent", "queued">>,published |-> {1, 3},effectCnt |-> <<<<0, 0, 0>>, <<0, 0, 0>>>>,seen |-> <<{}, {}>>]),
    ([pendCons |-> <<0, 0, 0>>,members |-> 1..2,cancelled |-> {1, 3},pendCount |-> <<0, 0, 0>>,state |-> <<"queued", "queued", "queued">>,published |-> {1, 2, 3},effectCnt |-> <<<<0, 0, 0>>, <<0, 0, 0>>>>,seen |-> <<{}, {}>>]),
    ([pendCons |-> <<0, 0, 0>>,members |-> 1..2,cancelled |-> {1, 2, 3},pendCount |-> <<0, 0, 0>>,state |-> <<"queued", "queued", "queued">>,published |-> {1, 2, 3},effectCnt |-> <<<<0, 0, 0>>, <<0, 0, 0>>>>,seen |-> <<{}, {}>>])
    >>
----


=============================================================================

---- CONFIG WorkQueue_TTrace_1791651522 ----
CONSTANTS
    NMsgs = 3
    NConsumers = 2
    MaxDeliver = 2

PROPERTY
    _prop

CHECK_DEADLOCK
    \* CHECK_DEADLOCK off because of PROPERTY or INVARIANT above.
    FALSE

INIT
    _init

NEXT
    _next

CONSTANT
    _TETrace <- _trace

ALIAS
    _expression
=============================================================================
\* Generated on Sat Oct 10 16:58:48 UTC 2026