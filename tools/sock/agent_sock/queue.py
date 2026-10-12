"""队列引擎：workqueue/topic 双语义、消费者组、PEL、tombstone、背压。

DESIGN.md §2.4/§2.6/§3。TLA+ 对应：tla/WorkQueue.tla。
关键一致点：
  - requeue_or_dead(m)：唯一重入原语（S2）
  - Deliver 取 queued 且未取消中的最小 mid（tombstone 不占队头）
  - Cancel 只对 queued 任务记 tombstone；P7 已取消永不投递
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field

from . import errors

# 消息状态（TLA+ States）
ABSENT = "absent"
QUEUED = "queued"
PENDING = "pending"
ACKED = "acked"
DEAD = "dead"

DEFAULT_ACK_WAIT_S = 30
DEFAULT_MAX_DELIVER = 5
DEFAULT_MAX_DEPTH = 10000


@dataclass
class QMessage:
    mid: int               # server 分配的单调序号（FIFO 键）
    message_id: str        # 幂等键（去重）
    payload: bytes
    state: str = QUEUED
    pend_count: int = 0    # 已投递次数（TLA+ pendCount）
    pend_consumer: str = ""  # 持有者（TLA+ pendCons）
    deliver_at: float = 0.0  # 本次投递时间（ack 超时用）


@dataclass
class ConsumerGroup:
    name: str
    members: set[str] = field(default_factory=set)
    cursor: int = 0            # 已消费到的最大 mid（compaction 用）
    pending: dict[int, str] = field(default_factory=dict)  # mid -> consumer（PEL）
    ack_wait_s: int = DEFAULT_ACK_WAIT_S
    max_deliver: int = DEFAULT_MAX_DELIVER


@dataclass
class QueueDeclare:
    name: str
    semantics: str             # workqueue | topic
    max_depth: int = DEFAULT_MAX_DEPTH
    overflow: str = "block"    # block | drop_oldest


class Queue:
    """单个队列。单线程使用（server asyncio 事件循环内）。"""

    def __init__(self, decl: QueueDeclare, data_dir: str):
        self.decl = decl
        self.data_dir = data_dir
        self.messages: dict[int, QMessage] = {}
        self.message_ids: set[str] = set()  # 幂等去重
        self.groups: dict[str, ConsumerGroup] = {}
        self.cancelled: set[str] = set()     # tombstone：已取消 task_id
        self._next_mid = 1
        self._dropped = 0
        os.makedirs(data_dir, exist_ok=True)
        self._load()

    # ---- 持久化（WAL 批量刷盘由 server 驱动，这里只提供 snapshot/restore）

    def _paths(self):
        return (os.path.join(self.data_dir, "log.jsonl"),
                os.path.join(self.data_dir, "state.json"),
                os.path.join(self.data_dir, "cancelled.json"))

    def _load(self):
        log_p, state_p, cancel_p = self._paths()
        if os.path.exists(cancel_p):
            with open(cancel_p) as f:
                self.cancelled = set(json.load(f))
        if os.path.exists(log_p):
            with open(log_p) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    rec = json.loads(line)
                    m = QMessage(
                        mid=rec["mid"], message_id=rec["message_id"],
                        payload=rec["payload"].encode("latin1"),
                        state=rec.get("state", QUEUED),
                        pend_count=rec.get("pend_count", 0),
                    )
                    self.messages[m.mid] = m
                    self.message_ids.add(m.message_id)
                    self._next_mid = max(self._next_mid, m.mid + 1)
        if os.path.exists(state_p):
            with open(state_p) as f:
                st = json.load(f)
            for gname, g in st.get("groups", {}).items():
                self.groups[gname] = ConsumerGroup(
                    name=gname, members=set(g.get("members", [])),
                    cursor=g.get("cursor", 0),
                    pending={int(k): v for k, v in g.get("pending", {}).items()},
                    ack_wait_s=g.get("ack_wait_s", DEFAULT_ACK_WAIT_S),
                    max_deliver=g.get("max_deliver", DEFAULT_MAX_DELIVER),
                )

    def snapshot(self):
        """WAL 批量刷盘：写 state.json + cancelled.json。log.jsonl append-only 即时写。"""
        _, state_p, cancel_p = self._paths()
        st = {"groups": {
            gname: {"members": sorted(g.members), "cursor": g.cursor,
                    "pending": {str(k): v for k, v in g.pending.items()},
                    "ack_wait_s": g.ack_wait_s, "max_deliver": g.max_deliver}
            for gname, g in self.groups.items()}}
        tmp = state_p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, state_p)
        tmp = cancel_p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sorted(self.cancelled), f)
        os.replace(tmp, cancel_p)

    def _append_log(self, rec: dict):
        log_p, _, _ = self._paths()
        with open(log_p, "a") as f:
            f.write(json.dumps(rec) + "\n")

    # ---- publish

    def depth(self) -> int:
        return sum(1 for m in self.messages.values() if m.state == QUEUED)

    def publish(self, message_id: str, payload: bytes) -> tuple[int, str | None]:
        """返回 (mid, 告警事件code|None)。幂等：重复 message_id 返回原 mid。"""
        for m in self.messages.values():
            if m.message_id == message_id and m.state in (QUEUED, PENDING):
                return m.mid, None  # 幂等键去重
        alert = None
        if self.depth() >= self.decl.max_depth:
            if self.decl.overflow == "block":
                raise errors.make("AEVT-4001", f"queue {self.decl.name} full",
                                  context={"retry_after_s": 1})
            # drop_oldest：挤掉最旧未消费
            oldest = min((m.mid for m in self.messages.values()
                          if m.state == QUEUED), default=None)
            if oldest is not None:
                del self.messages[oldest]
                self._dropped += 1
                alert = "queue.dropped"
        mid = self._next_mid
        self._next_mid += 1
        m = QMessage(mid=mid, message_id=message_id, payload=payload)
        self.messages[mid] = m
        self.message_ids.add(message_id)
        self._append_log({"mid": mid, "message_id": message_id,
                          "payload": payload.decode("latin1"),
                          "state": QUEUED, "pend_count": 0})
        # 空组告警（R-02：不阻塞，只告警）
        if self.decl.semantics == "workqueue":
            if not any(g.members for g in self.groups.values()):
                alert = alert or "AEVT-4005"
        return mid, alert

    # ---- consume / unconsume

    def consume(self, consumer: str, group: str | None,
                ack_wait_s: int = DEFAULT_ACK_WAIT_S,
                max_deliver: int = DEFAULT_MAX_DELIVER) -> ConsumerGroup:
        if self.decl.semantics == "workqueue":
            if not group:
                raise errors.make("AEVT-4007", "workqueue consume requires group")
            if self.decl.name.endswith(".inbox") and group != "inbox":
                raise errors.make("AEVT-4007",
                                  f"inbox group must be 'inbox', got {group}")
        else:  # topic
            if group:
                raise errors.make("AEVT-4007", "topic consume forbids group")
            group = f"topic:{consumer}"  # 每个订阅者独立组，全量接收
        g = self.groups.get(group)
        if g is None:
            g = ConsumerGroup(name=group, ack_wait_s=ack_wait_s,
                              max_deliver=max_deliver)
            self.groups[group] = g
        g.members.add(consumer)
        return g

    def unconsume(self, consumer: str, group: str | None) -> None:
        gname = group or f"topic:{consumer}"
        g = self.groups.get(gname)
        if g is None:
            return  # 幂等成功
        g.members.discard(consumer)
        # 该成员的 in-flight 经 requeue_or_dead 回池（TLA+ Leave）
        for mid, holder in list(g.pending.items()):
            if holder == consumer:
                self._requeue_or_dead(mid, g)
        if not g.members and gname.startswith("topic:"):
            del self.groups[gname]

    # ---- S2：唯一重入原语

    def _requeue_or_dead(self, mid: int, group: ConsumerGroup) -> str:
        """返回 'dead' 或 'queued'。超时/离开回收/ack+requeue 三处共用。"""
        m = self.messages.get(mid)
        if m is None:
            return "gone"
        if m.pend_count >= group.max_deliver:
            m.state = DEAD
            m.pend_consumer = ""
            group.pending.pop(mid, None)
            return "dead"
        m.state = QUEUED
        m.pend_consumer = ""
        group.pending.pop(mid, None)
        return "queued"

    # ---- deliver / ack

    def deliver(self, group_name: str) -> QMessage | None:
        """FIFO：取 queued 且未取消中的最小 mid。tombstone 不占队头。

        对应 TLA+ Deliver：
          state[m]="queued" /\\ m \\notin cancelled
          /\\ \\A n: queued /\\ 未取消 => m <= n
        """
        g = self.groups.get(group_name)
        if g is None or not g.members:
            return None
        best: QMessage | None = None
        for m in self.messages.values():
            if m.state != QUEUED:
                continue
            if m.message_id in self.cancelled:  # R-05：tombstone 过滤
                continue
            if best is None or m.mid < best.mid:
                best = m
        if best is None:
            return None
        # topic：每个订阅者独立组，全量投递；workqueue：组内轮询成员
        if self.decl.semantics == "topic":
            # topic 下每个 consumer 有自己的 group，这里按组投递给其成员
            consumer = next(iter(g.members))
        else:
            # 简单轮询：选 pending 最少的成员
            consumer = min(g.members, key=lambda c: sum(
                1 for h in g.pending.values() if h == c))
        best.state = PENDING
        best.pend_consumer = consumer
        best.pend_count += 1
        best.deliver_at = time.time()
        g.pending[best.mid] = consumer
        return best

    def ack(self, group_name: str, delivery_mid: int,
            consumer: str, requeue: bool = False) -> str:
        """返回 'acked' | 'requeued' | 'dead'。"""
        g = self.groups.get(group_name)
        if g is None:
            raise errors.make("AEVT-4007", f"unknown group {group_name}")
        m = self.messages.get(delivery_mid)
        if m is None or m.state != PENDING or m.pend_consumer != consumer:
            raise errors.make("AEVT-4007", "ack on non-pending delivery")
        if requeue:
            # S3：ack+<requeue/> = 消费者触发的提前 Timeout
            return self._requeue_or_dead(delivery_mid, g)
        m.state = ACKED
        m.pend_consumer = ""
        g.pending.pop(delivery_mid, None)
        if delivery_mid > g.cursor:
            g.cursor = delivery_mid
        return "acked"

    def sweep_timeouts(self, now: float | None = None) -> list[tuple[int, str]]:
        """ack_wait 超时扫描。返回 [(mid, 'dead'|'queued')]。"""
        now = now or time.time()
        out = []
        for gname, g in self.groups.items():
            for mid, holder in list(g.pending.items()):
                m = self.messages.get(mid)
                if m is None or m.state != PENDING:
                    continue
                if now - m.deliver_at >= g.ack_wait_s:
                    out.append((mid, self._requeue_or_dead(mid, g)))
        return out

    # ---- R-05：取消

    def cancel(self, task_id: str) -> bool:
        """只对 queued 任务记 tombstone。返回是否记入。"""
        if task_id in self.cancelled:
            return False
        # 只有 queued 任务可取消（pending 已投递，取消是 no-op）
        for m in self.messages.values():
            if m.message_id == task_id and m.state == QUEUED:
                self.cancelled.add(task_id)
                return True
        return False

    def is_cancelled(self, task_id: str) -> bool:
        return task_id in self.cancelled

    # ---- compaction

    def compact(self, force_days: float = 7.0) -> int:
        """截断 log。返回删除条数。"""
        if not self.messages:
            return 0
        if self.groups:
            min_cursor = min(g.cursor for g in self.groups.values())
        else:
            min_cursor = 0
        # 7 天强制推进由 server 定时触发，这里只做截断
        cutoff = min_cursor
        doomed = [mid for mid, m in self.messages.items()
                  if m.mid <= cutoff and m.state in (ACKED, DEAD)]
        # 保留最近 1000 条
        doomed = sorted(doomed)[:max(0, len(doomed))]
        keep_from = max([mid for mid in self.messages], default=0) - 1000
        doomed = [mid for mid in doomed if mid <= keep_from]
        for mid in doomed:
            del self.messages[mid]
        return len(doomed)
