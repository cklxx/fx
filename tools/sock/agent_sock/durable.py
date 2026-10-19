"""持久化原语：append-only 日志、组提交 fsync、原子替换。

DESIGN.md §3.1。规则：
  - 状态变化先 append 到日志，再改内存，再回复。
  - 回复（任何发往 socket 的帧）只在日志 fsync 之后发出。server 在
    `_send` 里等 `GroupCommit.commit()`。
  - 组提交：同一个批次的多次 append 只做一次 fsync。fsync 在线程池里
    运行，事件循环在这段时间继续收新请求；新请求进下一个批次。
  - 新建文件、原子替换、日志重写之后，fsync 父目录，使目录项落盘。
  - 重放时，末尾不完整的一行（crash 时写了一半）被截掉。

其他模块（例如任务层 tasks.py）用法：
    log = AppendLog(path, group=server.wal)
    log.append(json.dumps(rec))          # 代替 open(path, "a").write(...)
    for rec in log.replay(): ...         # 代替逐行 json.loads
"""
from __future__ import annotations

import asyncio
import json
import os
from typing import Iterator


def fsync_dir(path: str) -> None:
    """fsync 目录，使其中的新建/改名目录项落盘。"""
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def makedirs_durable(path: str) -> None:
    """建目录。新建的每一级目录都 fsync 其父目录。"""
    path = os.path.abspath(path)
    if os.path.isdir(path):
        return
    parent = os.path.dirname(path)
    makedirs_durable(parent)
    try:
        os.mkdir(path)
    except FileExistsError:
        return
    fsync_dir(parent)


def atomic_write(path: str, data: bytes, fsync: bool = True) -> None:
    """写 tmp，fsync，rename，fsync 目录。crash 后只看到旧文件或新文件。"""
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        _write_all(fd, data)
        if fsync:
            os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    if fsync:
        fsync_dir(os.path.dirname(os.path.abspath(path)))


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


class AppendLog:
    """append-only JSONL 日志。每条记录一行。

    group 为 None 时：每次 append 后立即 fsync（同步模式，给离线工具和
    单元测试用）。group 不为 None 时：append 只标记 dirty，由组提交统一
    fsync。fsync=False 关闭 fsync（只用于测量对照）。
    """

    def __init__(self, path: str, group: "GroupCommit | None" = None,
                 fsync: bool = True, read_only: bool = False):
        self.path = path
        self.group = group
        self.fsync = fsync if group is None else group.fsync
        self.read_only = read_only
        self.fd: int | None = None
        self.torn_bytes = 0   # 重放时截掉的不完整尾部字节数

    # ---- 打开 / 重放

    def _open(self) -> None:
        if self.fd is not None or self.read_only:
            return
        d = os.path.dirname(os.path.abspath(self.path))
        makedirs_durable(d)
        existed = os.path.exists(self.path)
        self.fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT,
                          0o600)
        if not existed and self.fsync:
            fsync_dir(d)

    def replay(self) -> Iterator[dict]:
        """逐条返回记录。末尾不完整或损坏的行被截掉（非只读模式）。

        中间行损坏说明不是 crash 撕裂，抛 ValueError，不静默丢数据。
        """
        if not os.path.exists(self.path):
            return
        with open(self.path, "rb") as f:
            data = f.read()
        good_end = 0
        pos = 0
        n = len(data)
        while pos < n:
            nl = data.find(b"\n", pos)
            if nl < 0:
                break  # 最后一行没有换行符：撕裂
            line = data[pos:nl].strip()
            if line:
                try:
                    rec = json.loads(line)
                except ValueError:
                    if data[nl + 1:].strip():
                        raise ValueError(
                            f"{self.path}: corrupt record at byte {pos}")
                    break  # 最后一行损坏：撕裂
                yield rec
            pos = nl + 1
            good_end = pos
        if good_end < n:
            self.torn_bytes = n - good_end
            if not self.read_only:
                os.truncate(self.path, good_end)
                if self.fsync:
                    fd = os.open(self.path, os.O_WRONLY)
                    try:
                        os.fsync(fd)
                    finally:
                        os.close(fd)

    # ---- 写

    def append(self, rec: dict | str) -> None:
        if self.read_only:
            raise RuntimeError(f"{self.path}: read-only log")
        line = rec if isinstance(rec, str) else json.dumps(rec)
        self._open()
        _write_all(self.fd, (line + "\n").encode("utf-8"))
        if self.group is not None:
            self.group.mark(self)
        elif self.fsync:
            os.fsync(self.fd)

    def rewrite(self, recs: list[dict]) -> None:
        """日志压缩/轮转：整体替换为 recs。原子替换并 fsync 目录。"""
        if self.read_only:
            raise RuntimeError(f"{self.path}: read-only log")
        if self.group is not None:
            self.group.forget(self)
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        data = "".join(json.dumps(r) + "\n" for r in recs).encode("utf-8")
        atomic_write(self.path, data, fsync=self.fsync)

    def sync(self) -> None:
        if self.fd is not None and self.fsync:
            os.fsync(self.fd)

    def close(self) -> None:
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class GroupCommit:
    """组提交。所有 AppendLog 共用一个实例。

    write_gen：append 次数（单调）。synced_gen：已 fsync 覆盖到的 write_gen。
    commit() 返回时，调用前的所有 append 都已落盘。
    """

    def __init__(self, fsync: bool = True):
        self.fsync = fsync
        self.write_gen = 0
        self.synced_gen = 0
        self._dirty: dict[int, AppendLog] = {}
        self._inflight: asyncio.Future | None = None
        self.failed: BaseException | None = None  # fsync 出错后 fail-stop
        self.batches = 0      # fsync 批次数（测量用）
        self.records = 0      # 被批次覆盖的记录数（测量用）

    def mark(self, log: AppendLog) -> None:
        self.write_gen += 1
        self._dirty[id(log)] = log

    def forget(self, log: AppendLog) -> None:
        self._dirty.pop(id(log), None)

    def _take_batch(self) -> tuple[int, list[int]]:
        gen = self.write_gen
        fds = [lg.fd for lg in self._dirty.values() if lg.fd is not None]
        self._dirty.clear()
        return gen, fds

    def sync_now(self) -> None:
        """同步 fsync 全部 dirty 日志（关停、定时器路径用）。"""
        gen, fds = self._take_batch()
        if self.fsync:
            for fd in fds:
                os.fsync(fd)
        if gen > self.synced_gen:
            self.batches += 1
            self.records += gen - self.synced_gen
            self.synced_gen = gen

    async def commit(self) -> None:
        """fsync 出错后不再确认任何写入（fail-stop）：Linux 在 fsync 报错后
        可能已丢弃脏页，再次 fsync 成功也不能证明数据在盘上。"""
        target = self.write_gen
        while self.synced_gen < target:
            if self.failed is not None:
                raise OSError(f"wal fsync failed earlier: {self.failed!r}")
            if self._inflight is None:
                self._inflight = asyncio.ensure_future(self._flush())
            fut = self._inflight
            await asyncio.shield(fut)

    async def _flush(self) -> None:
        try:
            gen, fds = self._take_batch()
            if self.fsync and fds:
                loop = asyncio.get_running_loop()
                try:
                    await loop.run_in_executor(None, _fsync_all, fds)
                except OSError as e:
                    self.failed = e
                    raise
            if gen > self.synced_gen:
                self.batches += 1
                self.records += gen - self.synced_gen
                self.synced_gen = gen
        finally:
            self._inflight = None


def _fsync_all(fds: list[int]) -> None:
    for fd in fds:
        try:
            os.fsync(fd)
        except OSError as e:
            # EBADF：日志在 fsync 前被 rewrite 关闭；rewrite 自己已 fsync。
            if e.errno != 9:
                raise
