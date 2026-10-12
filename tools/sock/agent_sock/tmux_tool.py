"""Tmux 工具封装：agent 的"物理机房"。

DESIGN.md §4。直接调 tmux CLI，零第三方依赖。
资源模型：Session(1:1 agent) → Window(1:1 task) → Pane(1:1 worker)。
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import time
import uuid

from . import errors
from . import osc7501

TMUX_SOCK = os.path.expanduser("~/.agent-sock/tmux.sock")
SNAPSHOT_DIR = os.path.expanduser("~/.agent-sock/snapshots")
STATUS_DIR = os.path.expanduser("~/.agent-sock/status")
HELPER_PATH = os.path.expanduser("~/.agent-sock/osc7501.sh")
STATUS_ENV = "ASOCK_7501_FILE"


def _tmux(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    cmd = ["tmux", "-S", TMUX_SOCK, *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=30, check=check)
    except FileNotFoundError:
        raise errors.make("ATMUX-1001", "tmux not installed")
    except subprocess.TimeoutExpired:
        raise errors.make("ATMUX-2001", f"tmux timeout: {' '.join(args)}")


def _session_name(agent_id: str) -> str:
    return f"asock-{agent_id}"


class TmuxTool:
    def __init__(self, sock: str = TMUX_SOCK):
        self.sock = sock
        os.makedirs(SNAPSHOT_DIR, exist_ok=True)

    def _run(self, *args: str, check: bool = True):
        cmd = ["tmux", "-S", self.sock, *args]
        try:
            return subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=30, check=check)
        except FileNotFoundError:
            raise errors.make("ATMUX-1001", "tmux not installed")

    def _run_raw(self, *args: str, check: bool = True) -> bytes:
        """Bytes variant: preserves escape sequences (no text decoding)."""
        cmd = ["tmux", "-S", self.sock, *args]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=30,
                               check=check)
        except FileNotFoundError:
            raise errors.make("ATMUX-1001", "tmux not installed")
        return r.stdout

    def _ensure_server(self):
        r = self._run("start-server", check=False)
        if r.returncode != 0 and "no server" not in r.stderr.lower():
            pass

    # ---- agent 生命周期

    def spawn_agent(self, agent_id: str, cmd: str,
                    status: bool = False) -> str:
        """建 session，起 agent 进程。返回 session 名。

        status=True 时启用 OSC 7501 状态通道：建 sidecar 文件并把
        ASOCK_7501_FILE 注入 pane 环境（见 agent_status）。
        """
        self._ensure_server()
        session = _session_name(agent_id)
        # 已存在则先杀
        self._run("kill-session", "-t", session, check=False)
        self._run("new-session", "-d", "-s", session, "-x", "200", "-y", "50")
        # 记录恢复元数据
        meta = {"agent_id": agent_id, "session": session,
                "launch_cmd": cmd, "created_at": time.time()}
        with open(os.path.join(SNAPSHOT_DIR, f"{agent_id}.meta"), "w") as f:
            json.dump(meta, f)
        if status:
            path = self.status_file(agent_id)
            open(path, "w").close()  # truncate/create
            cmd = f"{STATUS_ENV}={shlex.quote(path)} {cmd}"
        # 在首个 window 跑命令（确定性同步由调用方 run 保证）
        self._run("send-keys", "-t", f"{session}:0", cmd, "Enter")
        return session

    def agent_alive(self, agent_id: str) -> bool:
        r = self._run("has-session", "-t", _session_name(agent_id),
                      check=False)
        return r.returncode == 0

    # ---- task window

    def run_in(self, agent_id: str, task_id: str, cmd: str) -> str:
        """在 agent session 内新 window 跑命令。返回 window id。"""
        session = _session_name(agent_id)
        r = self._run("new-window", "-t", session, "-n", task_id,
                      "-P", "-F", "#{window_id}")
        wid = r.stdout.strip()
        self._run("send-keys", "-t", wid, cmd, "Enter")
        return wid

    def run(self, target: str, cmd: str, timeout: float = 60.0) -> str:
        """确定性同步：注入 cmd; tmux wait-for -S <uuid> 并阻塞等待。

        R-06 相关：send-keys 返回 ≠ 命令执行，用 wait-for 同步。
        """
        token = f"asock-{uuid.uuid4().hex[:12]}"
        wrapped = f"{cmd}; tmux -S {self.sock} wait-for -S {token}"
        self._run("send-keys", "-t", target, wrapped, "Enter")
        r = self._run("wait-for", token, check=False)
        # wait-for 超时用 shell timeout 包装
        return r.stdout

    # ---- 捕获

    def capture(self, target: str, lines: int = 200) -> str:
        r = self._run("capture-pane", "-p", "-t", target,
                      "-S", f"-{lines}")
        return r.stdout

    def capture_raw(self, target: str, lines: int = 200) -> bytes:
        """原始捕获：保留转义序列（含 OSC）。bytes 返回，不做文本解码。"""
        return self._run_raw("capture-pane", "-e", "-p", "-t", target,
                             "-S", f"-{lines}")

    # ---- OSC 7501 程序状态（Program Status Protocol）

    def status_file(self, agent_id: str) -> str:
        """sidecar 文件路径。tmux 吞掉未知 OSC（实测），pane 缓冲区里
        看不到 OSC 7501；可靠通道是 emitter 双写的文件。"""
        os.makedirs(STATUS_DIR, exist_ok=True)
        return os.path.join(STATUS_DIR, f"{agent_id}.osc7501")

    @staticmethod
    def install_shell_helper() -> str:
        """写 ~/.agent-sock/osc7501.sh（asock_emit_status 函数）。返回路径。"""
        os.makedirs(os.path.dirname(HELPER_PATH), exist_ok=True)
        with open(HELPER_PATH, "w") as f:
            f.write(osc7501.shell_helper())
        return HELPER_PATH

    def _agent_id_from_target(self, target: str) -> str | None:
        """从 target 反推 agent_id。session 名形如 asock-<agent_id>。"""
        if target.startswith("asock-"):
            rest = target[len("asock-"):]
            return rest.split(":")[0].split(".")[0] or None
        if target.startswith("@") or target.startswith("%"):
            r = self._run("display-message", "-p", "-t", target,
                          "#{session_name}", check=False)
            if r.returncode == 0:
                return self._agent_id_from_target(r.stdout.strip())
        return None

    def agent_status(self, target: str) -> dict | None:
        """读 agent 的 OSC 7501 状态。返回结构化状态或 None（无记录）。

        两路合并：pane 输出解析（pty 保留序列时有效）+ sidecar 文件
        （tmux 下的可靠通道）。后读到的报告覆盖同 id 记录。
        返回 {"records": [{"id","state","kind","progress","app","title","msg"}]}，
        root 在前，app 已按层级继承解析。
        """
        store = osc7501.RecordStore()
        try:
            store.ingest(self.capture_raw(target))
        except Exception:
            pass
        agent_id = self._agent_id_from_target(target)
        if agent_id is not None:
            path = os.path.join(STATUS_DIR, f"{agent_id}.osc7501")
            if os.path.exists(path):
                try:
                    with open(path, "rb") as f:
                        store.ingest(f.read())
                except OSError:
                    pass
        if len(store) == 0:
            return None
        return store.snapshot()

    def capture_since(self, target: str, cursor: int = 0,
                      lines: int = 500) -> tuple[str, int, bool]:
        """游标式增量读取。返回 (text, new_cursor, missed)。

        cursor 是行号游标；落后太多返回 missed=True 提示重建。
        """
        text = self.capture(target, lines=lines)
        text_lines = text.splitlines()
        new_cursor = cursor + len(text_lines)
        # 简化游标：用内容 hash 检测是否错过（首版近似）
        missed = len(text_lines) >= lines  # 顶满说明可能丢了头部
        return text, new_cursor, missed

    # ---- 快照（恢复意图，不含进程内存）

    def snapshot(self, agent_id: str) -> dict:
        """快照"恢复意图"：cwd/layout/launch_cmd/handle。"""
        session = _session_name(agent_id)
        snap = {"agent_id": agent_id, "ts": time.time(), "windows": []}
        r = self._run("list-windows", "-t", session, "-F",
                      "#{window_id} #{window_name} #{pane_current_path}",
                      check=False)
        if r.returncode != 0:
            raise errors.make("ATMUX-1002", f"session {session} not found")
        for line in r.stdout.strip().splitlines():
            parts = line.split(" ", 2)
            if len(parts) == 3:
                snap["windows"].append({
                    "window_id": parts[0], "name": parts[1], "cwd": parts[2]})
        meta_path = os.path.join(SNAPSHOT_DIR, f"{agent_id}.meta")
        if os.path.exists(meta_path):
            with open(meta_path) as f:
                snap["meta"] = json.load(f)
        snap_path = os.path.join(SNAPSHOT_DIR, f"{agent_id}.snapshot.json")
        with open(snap_path, "w") as f:
            json.dump(snap, f, indent=2)
        return snap

    def restore(self, agent_id: str) -> str:
        """重建现场 + 执行 launch_cmd。"""
        snap_path = os.path.join(SNAPSHOT_DIR, f"{agent_id}.snapshot.json")
        if not os.path.exists(snap_path):
            raise errors.make("ATMUX-1002", f"no snapshot for {agent_id}")
        with open(snap_path) as f:
            snap = json.load(f)
        launch_cmd = snap.get("meta", {}).get("launch_cmd", "bash")
        session = self.spawn_agent(agent_id, launch_cmd)
        for w in snap.get("windows", [])[1:]:  # 首个 window 已由 spawn 建
            self._run("new-window", "-t", session, "-n", w["name"],
                      "-c", w["cwd"])
        return session

    # ---- 排布

    def tile(self, agent_ids: list[str]) -> None:
        """多 agent 网格排布（在主 tmux 里平铺各 agent session 的首 window）。"""
        # 简化实现：在一个总览 session 里用 join-pane 聚合
        overview = "asock-overview"
        self._run("kill-session", "-t", overview, check=False)
        self._run("new-session", "-d", "-s", overview)
        first = True
        for aid in agent_ids:
            src = f"{_session_name(aid)}:0"
            if first:
                self._run("join-pane", "-s", src, "-t", f"{overview}:0",
                          check=False)
                first = False
            else:
                self._run("join-pane", "-s", src, "-t", overview, check=False)
        self._run("select-layout", "-t", overview, "tiled", check=False)

    # ---- 终止（有审计的两段式）

    def terminate(self, agent_id: str,
                  graceful_timeout: float = 10.0) -> dict:
        """两段式终止：SIGINT → 确认 → 超时 kill-pane + 进程树收尸。全程记审计。"""
        session = _session_name(agent_id)
        audit = {"agent_id": agent_id, "ts": time.time(), "steps": []}
        # 1. SIGINT
        self._run("send-keys", "-t", session, "C-c", check=False)
        audit["steps"].append({"action": "sigint", "ts": time.time()})
        deadline = time.time() + graceful_timeout
        while time.time() < deadline:
            if not self.agent_alive(agent_id):
                audit["steps"].append({"action": "exited_gracefully",
                                       "ts": time.time()})
                break
            time.sleep(0.5)
        else:
            # 2. kill-pane + 进程树
            self._run("kill-session", "-t", session, check=False)
            audit["steps"].append({"action": "kill_session",
                                   "ts": time.time()})
        audit_path = os.path.join(SNAPSHOT_DIR, f"{agent_id}.terminate.json")
        with open(audit_path, "w") as f:
            json.dump(audit, f, indent=2)
        return audit

    def pane_dead(self, target: str) -> bool:
        r = self._run("display-message", "-p", "-t", target,
                      "#{pane_dead}", check=False)
        return r.stdout.strip() == "1"
