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
import random
import time
from dataclasses import dataclass, field

from . import errors
from .durable import AppendLog, GroupCommit, atomic_write, makedirs_durable

# 消息状态（TLA+ States）
ABSENT = "absent"
QUEUED = "queued"
PENDING = "pending"
ACKED = "acked"
DEAD = "dead"

DEFAULT_ACK_WAIT_S = 30
DEFAULT_MAX_DELIVER = 5
DEFAULT_MAX_DEPTH = 10000
# 重投退避（DESIGN §2.6）：第 n 次投递失败后等 min(max, base*2^(n-1))，
# 再乘 [0.5, 1.0) 的随机因子（equal jitter）。base=0 关闭退避。
DEFAULT_BACKOFF_BASE_S = 1.0
DEFAULT_BACKOFF_MAX_S = 60.0

# 死信原因
DEAD_REJECTED = "rejected"        # 消费者 ack+<reject/>：不重投
DEAD_EXHAUSTED = "max_deliver"    # 投递次数用完


@dataclass
class QMessage:
    mid: int               # server 分配的单调序号（FIFO 键）
    message_id: str        # 幂等键（去重）
    payload: bytes
    state: str = QUEUED
    pend_count: int = 0    # 已投递次数（TLA+ pendCount）
    pend_consumer: str = ""  # 持有者（TLA+ pendCons）
    deliver_at: float = 0.0  # 本次投递时间（ack 超时用）
    not_before: float = 0.0  # 退避：此时刻之前不投递（wall clock）
    reason: str = ""         # 死信原因（DEAD_*）
    dead_at: float = 0.0


@dataclass
class ConsumerGroup:
    name: str
    members: set[str] = field(default_factory=set)
    cursor: int = 0            # 已消费到的最大 mid（compaction 用）
    pending: dict[int, str] = field(default_factory=dict)  # mid -> consumer（PEL）
    ack_wait_s: int = DEFAULT_ACK_WAIT_S
    max_deliver: int = DEFAULT_MAX_DELIVER
    backoff_base_s: float = DEFAULT_BACKOFF_BASE_S
    backoff_max_s: float = DEFAULT_BACKOFF_MAX_S


@dataclass
class QueueDeclare:
    name: str
    semantics: str             # workqueue | topic
    max_depth: int = DEFAULT_MAX_DEPTH
    overflow: str = "block"    # block | drop_oldest


def load_decl(data_dir: str, name: str) -> QueueDeclare:
    """读 decl.json。旧数据目录没有它：按 workqueue/10000/block 处理。"""
    try:
        with open(os.path.join(data_dir, "decl.json")) as f:
            d = json.load(f)
        return QueueDeclare(name=name, semantics=d["semantics"],
                            max_depth=int(d["max_depth"]),
                            overflow=d["overflow"])
    except (OSError, ValueError, KeyError):
        return QueueDeclare(name=name, semantics="workqueue")


class Queue:
    """单个队列。单线程使用（server asyncio 事件循环内）。

    持久化（DESIGN §3.1）：log.jsonl 是消息状态的唯一真相源。
      - 无 op 的记录：完整消息记录（publish 和压缩时写）。
      - {"op":"st"}：状态变化（deliver/ack/requeue/dead/replay）。
      - {"op":"drop"}：drop_oldest 挤掉的消息。
      - {"op":"cancel"}：tombstone。
    state.json 只存 group 元数据（cursor、参数），丢失不影响消息状态。
    """

    def __init__(self, decl: QueueDeclare, data_dir: str,
                 wal: GroupCommit | None = None, fsync: bool = True,
                 read_only: bool = False):
        self.decl = decl
        self.data_dir = data_dir
        self.messages: dict[int, QMessage] = {}
        self.message_ids: set[str] = set()  # 幂等去重
        self.groups: dict[str, ConsumerGroup] = {}
        self.cancelled: set[str] = set()     # tombstone：已取消 task_id
        self._next_mid = 1
        self._dropped = 0
        self._state_written = ""
        self.rand = random.random            # 测试可替换
        self.read_only = read_only
        if not read_only:
            makedirs_durable(data_dir)
            decl_p = os.path.join(data_dir, "decl.json")
            if not os.path.exists(decl_p):  # 声明落盘：重启后 server 重建队列
                atomic_write(decl_p, json.dumps({
                    "name": decl.name, "semantics": decl.semantics,
                    "max_depth": decl.max_depth,
                    "overflow": decl.overflow}).encode(),
                    fsync=wal.fsync if wal is not None else fsync)
        self.log = AppendLog(self._paths()[0], group=wal, fsync=fsync,
                             read_only=read_only)
        self._load()

    # ---- 持久化

    def _paths(self):
        return (os.path.join(self.data_dir, "log.jsonl"),
                os.path.join(self.data_dir, "state.json"),
                os.path.join(self.data_dir, "cancelled.json"))

    def _apply(self, rec: dict):
        op = rec.get("op")
        if op is None:  # 完整消息记录
            m = QMessage(
                mid=rec["mid"], message_id=rec["message_id"],
                payload=rec["payload"].encode("latin1"),
                state=rec.get("state", QUEUED),
                pend_count=rec.get("pend_count", 0),
                not_before=rec.get("not_before", 0.0),
                reason=rec.get("reason", ""),
                dead_at=rec.get("dead_at", 0.0),
            )
            self.messages[m.mid] = m
            self.message_ids.add(m.message_id)
            self._next_mid = max(self._next_mid, m.mid + 1)
        elif op == "st":
            m = self.messages.get(rec["mid"])
            if m is None:
                return  # 已被压缩或挤掉
            m.state = rec["state"]
            m.pend_count = rec.get("pend_count", m.pend_count)
            m.not_before = rec.get("not_before", 0.0)
            m.reason = rec.get("reason", "")
            m.dead_at = rec.get("dead_at", 0.0)
        elif op == "drop":
            self.messages.pop(rec["mid"], None)
            self._next_mid = max(self._next_mid, rec["mid"] + 1)
        elif op == "cancel":
            self.cancelled.add(rec["task_id"])

    def _load(self):
        log_p, state_p, cancel_p = self._paths()
        if os.path.exists(cancel_p):  # 旧格式兼容
            try:
                with open(cancel_p) as f:
                    self.cancelled = set(json.load(f))
            except ValueError:
                pass
        for rec in self.log.replay():
            self._apply(rec)
        # 重启后没有会话：crash 时 in-flight 的消息回到 queued 重投。
        # pend_count 保留，max_deliver 跨重启生效。
        for m in self.messages.values():
            if m.state == PENDING:
                m.state = QUEUED
                m.pend_consumer = ""
        if os.path.exists(state_p):
            try:
                with open(state_p) as f:
                    st = json.load(f)
            except ValueError:
                st = {}  # 只是元数据；消息状态在 log 里
            for gname, g in st.get("groups", {}).items():
                # 成员和 PEL 属于连接，重启后清空；消费者重新 consume。
                self.groups[gname] = ConsumerGroup(
                    name=gname, cursor=g.get("cursor", 0),
                    ack_wait_s=g.get("ack_wait_s", DEFAULT_ACK_WAIT_S),
                    max_deliver=g.get("max_deliver", DEFAULT_MAX_DELIVER),
                    backoff_base_s=g.get("backoff_base_s",
                                         DEFAULT_BACKOFF_BASE_S),
                    backoff_max_s=g.get("backoff_max_s",
                                        DEFAULT_BACKOFF_MAX_S),
                )

    def snapshot(self):
        """写 group 元数据 state.json（原子替换 + fsync）。没有变化时跳过。"""
        if self.read_only:
            return
        _, state_p, _ = self._paths()
        st = {"groups": {
            gname: {"members": sorted(g.members), "cursor": g.cursor,
                    "pending": {str(k): v for k, v in g.pending.items()},
                    "ack_wait_s": g.ack_wait_s, "max_deliver": g.max_deliver,
                    "backoff_base_s": g.backoff_base_s,
                    "backoff_max_s": g.backoff_max_s}
            for gname, g in self.groups.items()}}
        data = json.dumps(st, sort_keys=True)
        if data == self._state_written:
            return
        atomic_write(state_p, data.encode(), fsync=self.log.fsync)
        self._state_written = data

    def _append_log(self, rec: dict):
        self.log.append(rec)

    def _log_state(self, m: QMessage):
        rec = {"op": "st", "mid": m.mid, "state": m.state,
               "pend_count": m.pend_count}
        if m.not_before:
            rec["not_before"] = m.not_before
        if m.reason:
            rec["reason"] = m.reason
        if m.dead_at:
            rec["dead_at"] = m.dead_at
        self._append_log(rec)

    @staticmethod
    def _full_record(m: QMessage) -> dict:
        rec = {"mid": m.mid, "message_id": m.message_id,
               "payload": m.payload.decode("latin1"),
               "state": QUEUED if m.state == PENDING else m.state,
               "pend_count": m.pend_count}
        if m.not_before:
            rec["not_before"] = m.not_before
        if m.reason:
            rec["reason"] = m.reason
        if m.dead_at:
            rec["dead_at"] = m.dead_at
        return rec

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
                self._append_log({"op": "drop", "mid": oldest})
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
                max_deliver: int = DEFAULT_MAX_DELIVER,
                backoff_base_s: float | None = None,
                backoff_max_s: float | None = None) -> ConsumerGroup:
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
        if backoff_base_s is not None:
            g.backoff_base_s = max(0.0, float(backoff_base_s))
        if backoff_max_s is not None:
            g.backoff_max_s = max(0.0, float(backoff_max_s))
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

    def backoff_delay(self, attempts: int, group: ConsumerGroup) -> float:
        """第 attempts 次投递失败后的退避秒数。equal jitter：[d/2, d)。"""
        if group.backoff_base_s <= 0 or attempts <= 0:
            return 0.0
        d = min(group.backoff_max_s,
                group.backoff_base_s * (2 ** min(attempts - 1, 30)))
        return d * (0.5 + 0.5 * self.rand())

    def _dead(self, m: QMessage, group: ConsumerGroup, reason: str,
              now: float | None = None):
        m.state = DEAD
        m.pend_consumer = ""
        m.not_before = 0.0
        m.reason = reason
        m.dead_at = time.time() if now is None else now
        group.pending.pop(m.mid, None)
        self._log_state(m)

    def _requeue_or_dead(self, mid: int, group: ConsumerGroup,
                         now: float | None = None) -> str:
        """返回 'dead' 或 'queued'。超时/离开回收/ack+requeue 三处共用。

        回到 queued 时按退避设 not_before；投递次数用完进死信。
        """
        m = self.messages.get(mid)
        if m is None:
            return "gone"
        if m.pend_count >= group.max_deliver:
            self._dead(m, group, DEAD_EXHAUSTED, now)
            return "dead"
        m.state = QUEUED
        m.pend_consumer = ""
        group.pending.pop(mid, None)
        delay = self.backoff_delay(m.pend_count, group)
        m.not_before = ((time.time() if now is None else now) + delay
                        if delay else 0.0)
        self._log_state(m)
        return "queued"

    def next_retry_at(self, now: float | None = None) -> float | None:
        """退避中消息的最早可投递时刻；没有则 None。server 用它定时 pump。"""
        now = time.time() if now is None else now
        ts = [m.not_before for m in self.messages.values()
              if m.state == QUEUED and m.not_before > now
              and m.message_id not in self.cancelled]
        return min(ts) if ts else None

    # ---- deliver / ack

    def deliver(self, group_name: str,
                now: float | None = None) -> QMessage | None:
        """FIFO：取 queued 且未取消中的最小 mid。tombstone 不占队头。

        对应 TLA+ Deliver：
          state[m]="queued" /\\ m \\notin cancelled
          /\\ \\A n: queued /\\ 未取消 => m <= n
        """
        g = self.groups.get(group_name)
        if g is None or not g.members:
            return None
        now = time.time() if now is None else now
        best: QMessage | None = None
        for m in self.messages.values():
            if m.state != QUEUED:
                continue
            if m.not_before > now:  # 退避中：不占队头
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
        best.deliver_at = now
        best.not_before = 0.0
        g.pending[best.mid] = consumer
        self._log_state(best)  # pend_count 落盘：max_deliver 跨重启生效
        return best

    def ack(self, group_name: str, delivery_mid: int,
            consumer: str, requeue: bool = False,
            reject: bool = False) -> str:
        """返回 'acked' | 'queued' | 'dead'。

        reject=True：消费者判定消息不可处理，直接进死信，不重投。
        """
        g = self.groups.get(group_name)
        if g is None:
            raise errors.make("AEVT-4007", f"unknown group {group_name}")
        m = self.messages.get(delivery_mid)
        if m is None or m.state != PENDING or m.pend_consumer != consumer:
            raise errors.make("AEVT-4007", "ack on non-pending delivery")
        if reject:
            self._dead(m, g, DEAD_REJECTED)
            return "dead"
        if requeue:
            # S3：ack+<requeue/> = 消费者触发的提前 Timeout
            return self._requeue_or_dead(delivery_mid, g)
        m.state = ACKED
        m.pend_consumer = ""
        g.pending.pop(delivery_mid, None)
        self._log_state(m)
        if delivery_mid > g.cursor:
            g.cursor = delivery_mid
        return "acked"

    def sweep_timeouts(self, now: float | None = None) -> list[tuple[int, str]]:
        """ack_wait 超时扫描。返回 [(mid, 'dead'|'queued')]。"""
        now = time.time() if now is None else now
        out = []
        for gname, g in self.groups.items():
            for mid, holder in list(g.pending.items()):
                m = self.messages.get(mid)
                if m is None or m.state != PENDING:
                    continue
                if now - m.deliver_at >= g.ack_wait_s:
                    out.append((mid, self._requeue_or_dead(mid, g, now)))
        return out

    # ---- R-05：取消

    def cancel(self, task_id: str) -> bool:
        """只对 queued 任务记 tombstone。返回是否记入。"""
        if task_id in self.cancelled:
            return False
        # 只有 queued 任务可取消（pending 已投递，取消是 no-op）
        for m in self.messages.values():
            if m.message_id == task_id and m.state == QUEUED:
                self._append_log({"op": "cancel", "task_id": task_id})
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
        if doomed and not self.read_only:
            # 日志轮转：用内存状态重写 log.jsonl（原子替换 + fsync 目录）
            recs = [self._full_record(m) for _, m in
                    sorted(self.messages.items())]
            recs += [{"op": "cancel", "task_id": t}
                     for t in sorted(self.cancelled)]
            self.log.rewrite(recs)
        return len(doomed)

    # ---- 死信队列

    def dead_letters(self) -> list[dict]:
        return [{"mid": m.mid, "message_id": m.message_id,
                 "pend_count": m.pend_count, "reason": m.reason,
                 "dead_at": m.dead_at}
                for _, m in sorted(self.messages.items()) if m.state == DEAD]

    def replay_dead(self) -> int:
        """死信重放：重置为 queued，投递计数清零。返回重放数。"""
        n = 0
        for m in self.messages.values():
            if m.state == DEAD:
                m.state = QUEUED
                m.pend_count = 0
                m.pend_consumer = ""
                m.reason = ""
                m.dead_at = 0.0
                m.not_before = 0.0
                self._log_state(m)
                n += 1
        return n
