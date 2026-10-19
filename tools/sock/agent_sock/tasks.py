"""共享任务列表：依赖、原子认领、租约、fencing token。DESIGN.md §11。

单线程使用（server asyncio 事件循环内），所以每个方法本身是原子的。

状态机：
  pending --claim--> claimed --complete--> completed
                        |-----fail------> failed（或 retry 时回 pending）
                        |--lease 过期--> pending（attempts 用尽时 failed）
  pending/claimed --cancel--> cancelled

fencing：每次新认领，任务的 token 加 1。renew/complete/fail 必须携带当前
token，否则回 AEVT-4101。token 写入日志，重启后从不回退。

持久化：每次状态变化先 append 一条记录到 tasks/log.jsonl（_append_log），
再回应答。重启时按顺序重放日志。记录类型见 RECORD_TYPES。
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field, asdict

from . import errors

PENDING = "pending"
CLAIMED = "claimed"      # 即 in_progress
COMPLETED = "completed"
FAILED = "failed"
CANCELLED = "cancelled"
TERMINAL = frozenset({COMPLETED, FAILED, CANCELLED})

DEFAULT_LEASE_S = 30.0
MIN_LEASE_S = 0.05
MAX_LEASE_S = 3600.0
DEFAULT_MAX_ATTEMPTS = 3

# 日志记录类型（字段 "rec"）。fix 的持久化工作要覆盖这些记录。
# task.fail 也用于依赖失败级联（附加字段 reason=dep_failed、dep）。
RECORD_TYPES = ("task.create", "task.claim", "task.renew", "task.complete",
                "task.fail", "task.expire", "task.cancel")


@dataclass
class Task:
    task_id: str
    payload: str = ""
    deps: list[str] = field(default_factory=list)
    idem_key: str = ""
    max_attempts: int = DEFAULT_MAX_ATTEMPTS
    state: str = PENDING
    token: int = 0            # 最近一次认领的 fencing token（单调）
    holder: str = ""          # 当前持有者 agent_id
    lease_expires_at: float = 0.0
    attempts: int = 0         # 认领次数
    result: str = ""
    error: str = ""
    completed_token: int = 0  # 哪个 token 完成了任务（merge gate 用）
    workdir: str = ""
    created_seq: int = 0

    def view(self) -> dict:
        d = asdict(self)
        d["claimable"] = False
        return d


class TaskList:
    def __init__(self, data_dir: str, now=time.time):
        self.data_dir = data_dir
        self.now = now
        self.tasks: dict[str, Task] = {}
        self.idem: dict[str, str] = {}             # idem_key -> task_id
        self.dependents: dict[str, set[str]] = {}  # dep -> {task_id}
        self._seq = 0
        # 钩子：attempts 用尽时调用 hook(task)。fix 的死信路径接在这里。
        self.on_exhausted = None
        # 钩子：依赖失败级联时调用 hook(task, dep_id)。server 用它发事件。
        self.on_dep_failed = None
        os.makedirs(data_dir, exist_ok=True)
        self._load()

    # ---- 持久化

    def _log_path(self) -> str:
        return os.path.join(self.data_dir, "log.jsonl")

    def _append_log(self, rec: dict) -> None:
        """单一写盘入口。和 Queue._append_log 同一风格（append-only jsonl）。"""
        with open(self._log_path(), "a") as f:
            f.write(json.dumps(rec) + "\n")

    def flush(self) -> None:
        """刷盘点。server 的 WAL 批量刷盘（_wal_flush）会调用它。
        现在为空操作：持久化保证（fsync）由持久化工作统一补上。"""

    def _load(self) -> None:
        p = self._log_path()
        if not os.path.exists(p):
            return
        with open(p) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    break  # 崩溃写了半行：截断在此（只可能是最后一行）
                self._apply(rec)
        self._recover_cascades()

    def _recover_cascades(self) -> None:
        """崩溃可能发生在级联中途。重放后，对每个 failed/cancelled 任务重跑
        同一个 _cascade，补写缺失的 dep_failed 记录。幂等：已 failed 的依赖方
        被跳过，不写重复记录。此时钩子还没设置，所以恢复不发事件。"""
        for t in sorted(self.tasks.values(), key=lambda x: x.created_seq):
            if t.state in (FAILED, CANCELLED):
                self._cascade(t.task_id)

    def _apply(self, rec: dict) -> None:
        """重放一条记录。运行时也走这里，保证运行和恢复是同一份逻辑。"""
        kind = rec["rec"]
        if kind == "task.create":
            self._seq += 1
            t = Task(task_id=rec["task_id"], payload=rec.get("payload", ""),
                     deps=list(rec.get("deps", [])),
                     idem_key=rec.get("idem_key", ""),
                     max_attempts=rec.get("max_attempts", DEFAULT_MAX_ATTEMPTS),
                     created_seq=self._seq)
            self.tasks[t.task_id] = t
            if t.idem_key:
                self.idem[t.idem_key] = t.task_id
            for d in t.deps:
                self.dependents.setdefault(d, set()).add(t.task_id)
            return
        t = self.tasks[rec["task_id"]]
        if kind == "task.claim":
            t.state = CLAIMED
            t.token = max(t.token, rec["token"])
            t.holder = rec["holder"]
            t.lease_expires_at = rec["lease_expires_at"]
            t.attempts = rec["attempts"]
            t.workdir = rec.get("workdir", "")
        elif kind == "task.renew":
            t.lease_expires_at = rec["lease_expires_at"]
        elif kind == "task.complete":
            t.state = COMPLETED
            t.result = rec.get("result", "")
            t.completed_token = rec["token"]
            t.holder = ""
            t.lease_expires_at = 0.0
        elif kind in ("task.fail", "task.expire"):
            t.state = rec["to"]
            t.error = rec.get("error", "")
            t.holder = ""
            t.lease_expires_at = 0.0
        elif kind == "task.cancel":
            t.state = CANCELLED
            t.holder = ""
            t.lease_expires_at = 0.0

    def _commit(self, rec: dict) -> None:
        self._append_log(rec)   # 先写盘
        self._apply(rec)        # 再改内存

    # ---- 查询

    def claimable(self, t: Task) -> bool:
        return t.state == PENDING and all(
            self.tasks[d].state == COMPLETED for d in t.deps)

    def view(self, t: Task) -> dict:
        d = t.view()
        d["claimable"] = self.claimable(t)
        return d

    def get(self, task_id: str) -> Task:
        t = self.tasks.get(task_id)
        if t is None:
            raise errors.make("AEVT-4102", f"task not found: {task_id}")
        return t

    def list(self, state: str = "") -> list[Task]:
        out = sorted(self.tasks.values(), key=lambda t: t.created_seq)
        return [t for t in out if not state or t.state == state]

    # ---- 创建（单个或批量，原子）

    def create(self, specs: list[dict]) -> list[tuple[Task, bool]]:
        """specs: [{task_id, payload, deps, idem_key, max_attempts}]。
        全部校验通过才写入。返回 [(task, created)]；created=False 表示幂等命中。
        批内任务可以互相依赖；环回 AEVT-4103。"""
        out: list[tuple[Task, bool]] = []
        new: list[dict] = []
        batch_ids: set[str] = set()
        for s in specs:
            key = s.get("idem_key", "") or ""
            if key and key in self.idem:
                out.append((self.tasks[self.idem[key]], False))
                continue
            tid = s.get("task_id") or ""
            if not tid:
                tid = f"t-{self._seq + len(new) + 1}"
                while tid in self.tasks or tid in batch_ids:
                    tid += "x"
            if tid in self.tasks or tid in batch_ids:
                raise errors.make("AEVT-4107", f"duplicate task_id: {tid}")
            deps = [d for d in (s.get("deps") or []) if d]
            try:
                ma = int(s.get("max_attempts") or DEFAULT_MAX_ATTEMPTS)
            except (TypeError, ValueError):
                raise errors.make("AEVT-4007", "bad max_attempts")
            if ma < 1:
                raise errors.make("AEVT-4007", "max_attempts must be >= 1")
            batch_ids.add(tid)
            new.append({"rec": "task.create", "task_id": tid,
                        "payload": s.get("payload", "") or "",
                        "deps": deps, "idem_key": key, "max_attempts": ma})
            out.append((None, True))  # 占位
        # 依赖必须已存在或在本批中
        graph = {r["task_id"]: r["deps"] for r in new}
        for tid, deps in graph.items():
            for d in deps:
                if d not in self.tasks and d not in graph:
                    raise errors.make("AEVT-4103", f"unknown dependency {d} of {tid}")
        self._check_acyclic(graph)
        for r in new:
            self._commit(r)
        it = iter(new)
        res = []
        for t, created in out:
            res.append((self.tasks[next(it)["task_id"]], True) if created
                       else (t, False))
        return res

    def _check_acyclic(self, graph: dict[str, list[str]]) -> None:
        """只看新任务构成的子图即可：已有任务的依赖只指向更早的任务，
        不会指回新任务，所以环只可能全在新任务内。"""
        WHITE, GREY, BLACK = 0, 1, 2
        color = {k: WHITE for k in graph}

        def visit(n: str, path: list[str]):
            color[n] = GREY
            for d in graph[n]:
                if d not in graph:
                    continue
                if color[d] == GREY:
                    cyc = path[path.index(d):] + [d] if d in path else [n, d]
                    raise errors.make("AEVT-4103",
                                      "dependency cycle: " + " -> ".join(cyc))
                if color[d] == WHITE:
                    visit(d, path + [d])
            color[n] = BLACK

        for k in graph:
            if color[k] == WHITE:
                visit(k, [k])

    # ---- 认领

    def claim(self, holder: str, task_id: str = "",
              lease_s: float = DEFAULT_LEASE_S,
              workroot: str = "") -> Task | None:
        """原子认领。task_id 为空时取最早创建的可认领任务；没有则返回 None。"""
        self.sweep()
        lease_s = self._check_lease(lease_s)
        if task_id:
            t = self.get(task_id)
            if not self.claimable(t):
                raise errors.make(
                    "AEVT-4104",
                    f"task {task_id} not claimable (state={t.state})")
        else:
            t = next((x for x in self.list() if self.claimable(x)), None)
            if t is None:
                return None
        token = t.token + 1
        workdir = (os.path.join(workroot, f"{t.task_id}-t{token}")
                   if workroot else "")
        self._commit({"rec": "task.claim", "task_id": t.task_id,
                      "token": token, "holder": holder,
                      "lease_expires_at": self.now() + lease_s,
                      "attempts": t.attempts + 1, "workdir": workdir})
        return t

    @staticmethod
    def _check_lease(lease_s) -> float:
        try:
            v = float(lease_s)
        except (TypeError, ValueError):
            raise errors.make("AEVT-4007", "bad lease_s")
        if not (MIN_LEASE_S <= v <= MAX_LEASE_S):
            raise errors.make("AEVT-4007",
                              f"lease_s must be in [{MIN_LEASE_S}, {MAX_LEASE_S}]")
        return v

    def _fence(self, task_id: str, token: int) -> Task:
        """fencing 检查。顺序：先过期扫描，再比 token，再比状态。"""
        self.sweep()
        t = self.get(task_id)
        if token != t.token:
            raise errors.make(
                "AEVT-4101",
                f"stale fencing token {token} for {task_id} (current {t.token})",
                task_id=task_id, context={"current_token": t.token})
        if t.state != CLAIMED:
            # token 对但租约已过期回 pending / 已终态：也是失效持有
            raise errors.make(
                "AEVT-4101" if t.state == PENDING else "AEVT-4105",
                f"task {task_id} is {t.state}, lease not held",
                task_id=task_id, context={"current_token": t.token})
        return t

    def renew(self, task_id: str, token: int,
              lease_s: float = DEFAULT_LEASE_S) -> Task:
        lease_s = self._check_lease(lease_s)
        t = self._fence(task_id, token)
        self._commit({"rec": "task.renew", "task_id": task_id, "token": token,
                      "lease_expires_at": self.now() + lease_s})
        return t

    def complete(self, task_id: str, token: int,
                 result: str = "") -> tuple[Task, list[Task]]:
        """返回 (task, 新解锁的依赖方列表)。"""
        t = self._fence(task_id, token)
        self._commit({"rec": "task.complete", "task_id": task_id,
                      "token": token, "result": result})
        unblocked = [self.tasks[d] for d in
                     sorted(self.dependents.get(task_id, ()),
                            key=lambda x: self.tasks[x].created_seq)
                     if self.claimable(self.tasks[d])]
        return t, unblocked

    def fail(self, task_id: str, token: int, error: str = "",
             retry: bool = False) -> Task:
        t = self._fence(task_id, token)
        to = PENDING if retry and t.attempts < t.max_attempts else FAILED
        self._commit({"rec": "task.fail", "task_id": task_id, "token": token,
                      "to": to, "error": error})
        if to == FAILED:
            if retry:
                self._exhausted(t)
            self._cascade(task_id)
        return t

    def cancel(self, task_id: str) -> Task:
        """基础取消：pending/claimed -> cancelled。持有者的 token 随之失效
        （后续 complete 回 AEVT-4105）。两档取消由上层在此之上实现。"""
        t = self.get(task_id)
        if t.state in TERMINAL:
            raise errors.make("AEVT-4105", f"task {task_id} already {t.state}")
        self._commit({"rec": "task.cancel", "task_id": task_id,
                      "token": t.token})
        self._cascade(task_id)
        return t

    # ---- 租约过期

    def sweep(self, now: float | None = None) -> list[Task]:
        """过期租约回 pending；attempts 用尽转 failed。返回变化的任务。"""
        now = self.now() if now is None else now
        changed = []
        for t in list(self.tasks.values()):
            if t.state == CLAIMED and t.lease_expires_at <= now:
                to = PENDING if t.attempts < t.max_attempts else FAILED
                self._commit({"rec": "task.expire", "task_id": t.task_id,
                              "token": t.token, "to": to,
                              "error": "lease expired" if to == PENDING
                              else "lease expired; max attempts reached"})
                if to == FAILED:
                    self._exhausted(t)
                    self._cascade(t.task_id)
                changed.append(t)
        return changed

    def _cascade(self, root_id: str) -> list[tuple[Task, str]]:
        """root 到了 failed/cancelled：所有仍 pending 的传递依赖方转 failed，
        error=dep_failed:<直接依赖 id>。每个变化的任务一条 task.fail 记录，
        先写盘再改内存。重放时这些记录照原样重现状态。"""
        out: list[tuple[Task, str]] = []
        frontier = [root_id]
        while frontier:
            dep = frontier.pop(0)
            for did in sorted(self.dependents.get(dep, ()),
                              key=lambda x: self.tasks[x].created_seq):
                d = self.tasks[did]
                assert d.state != CLAIMED, \
                    f"dependent {did} claimed while dep {dep} not completed"
                if d.state != PENDING:
                    continue
                self._commit({"rec": "task.fail", "task_id": did,
                              "token": d.token, "to": FAILED,
                              "error": f"dep_failed:{dep}",
                              "reason": "dep_failed", "dep": dep})
                out.append((d, dep))
                if self.on_dep_failed is not None:
                    self.on_dep_failed(d, dep)
                frontier.append(did)
        return out

    def _exhausted(self, t: Task) -> None:
        """死信钩子（不实现死信本身）。"""
        if self.on_exhausted is not None:
            self.on_exhausted(t)
