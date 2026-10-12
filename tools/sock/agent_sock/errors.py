"""错误码体系与自动分类器。DESIGN.md §6。

前缀：ASOCK（协议/传输）/ AEVT（事件/队列）/ ATMUX（tmux）/ APIPE（流水线）。
分类：可重试 / 需人工 / 致命。分类器规则见 §6.3。
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field

# 分类常量
RETRYABLE = "retryable"
NEEDS_HUMAN = "needs_human"
FATAL = "fatal"
WATCH = "watch"  # 观察（AEVT-4005 专用）

# 错误码表（§6.2）。(code, 场景, 缺省分类)
_ERROR_TABLE: list[tuple[str, str, str]] = [
    ("ASOCK-1001", "socket 不存在/权限拒绝", NEEDS_HUMAN),
    ("ASOCK-2001", "连接拒绝", RETRYABLE),
    ("ASOCK-2002", "版本不匹配/未知原语", NEEDS_HUMAN),
    ("ASOCK-2003", "心跳超时", RETRYABLE),
    ("ASOCK-2004", "帧超限（max_frame_bytes）", NEEDS_HUMAN),
    ("ASOCK-2005", "XML 安全违规（DOCTYPE/深度/元素数）", NEEDS_HUMAN),
    ("ASOCK-2006", "XML 解析失败/信封非法", NEEDS_HUMAN),
    ("AEVT-3001", "事件落盘失败", FATAL),
    ("AEVT-4001", "队列满（overflow=block）", RETRYABLE),
    ("AEVT-4003", "消息进死信", NEEDS_HUMAN),
    ("AEVT-4005", "空消费者组 publish（告警，不阻塞）", WATCH),
    ("AEVT-4006", "队列未声明", NEEDS_HUMAN),
    ("AEVT-4007", "参数错误", NEEDS_HUMAN),
    ("AEVT-4008", "resume 时会话已标 lost", RETRYABLE),
    ("ATMUX-1001", "tmux 未安装", NEEDS_HUMAN),
    ("ATMUX-1002", "tmux server 失联", NEEDS_HUMAN),
    ("ATMUX-2001", "pane 命令超时", RETRYABLE),
    ("APIPE-1001", "编译期错误", FATAL),
    ("APIPE-2001", "步骤失败且无 on_fail", NEEDS_HUMAN),
    ("APIPE-3001", "checkpoint 损坏", NEEDS_HUMAN),
    ("ACOM-1001", "tmux_compile 编译期错误", FATAL),
    ("ACOM-2001", "tmux_compile 产物执行失败", NEEDS_HUMAN),
]

CODE_TO_DEFAULT: dict[str, str] = {c: (s, d) for c, s, d in _ERROR_TABLE}
KNOWN_CODES = frozenset(CODE_TO_DEFAULT)


@dataclass
class ErrorPacket(Exception):
    """§6.1 错误包。也是异常：raise errors.make(...) / except ErrorPacket 均可用。"""
    code: str
    message: str
    severity: str = "error"  # error | fatal
    retryable: bool = False
    agent_id: str = ""
    task_id: str = ""
    ts: float = field(default_factory=time.time)
    context: dict = field(default_factory=dict)
    caused_by: dict | None = None  # 只一层：{code, message}

    def __post_init__(self):
        if self.code not in KNOWN_CODES:
            raise ValueError(f"unknown error code: {self.code}")
        # 让 str(e) / traceback 打印出 code: message；否则 except 后日志为空。
        super().__init__(f"{self.code}: {self.message}")

    def to_dict(self) -> dict:
        d = {
            "code": self.code, "message": self.message,
            "severity": self.severity, "retryable": self.retryable,
            "agent_id": self.agent_id, "task_id": self.task_id,
            "ts": self.ts, "context": self.context,
        }
        if self.caused_by:
            d["caused_by"] = self.caused_by
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "ErrorPacket":
        return cls(
            code=d["code"], message=d.get("message", ""),
            severity=d.get("severity", "error"),
            retryable=d.get("retryable", False),
            agent_id=d.get("agent_id", ""), task_id=d.get("task_id", ""),
            ts=d.get("ts", time.time()),
            context=d.get("context", {}),
            caused_by=d.get("caused_by"),
        )


def make(code: str, message: str = "", **kw) -> ErrorPacket:
    """按码表缺省分类构造错误包。"""
    if code not in KNOWN_CODES:
        raise ValueError(f"unknown error code: {code}")
    _, default_class = CODE_TO_DEFAULT[code]
    severity = "fatal" if default_class == FATAL else "error"
    retryable = default_class == RETRYABLE
    if "severity" not in kw:
        kw["severity"] = severity
    if "retryable" not in kw:
        kw["retryable"] = retryable
    return ErrorPacket(code=code, message=message or CODE_TO_DEFAULT[code][0], **kw)


class Classifier:
    """§6.3 自动分类器。

    可重试 = retryable 且 同一 task 5 分钟内重试 < 3 次
    需人工 = 不可重试 或 重试耗尽
    致命   = severity=fatal
    """

    MAX_RETRIES = 3
    WINDOW_S = 300.0

    def __init__(self):
        self._attempts: dict[str, list[float]] = {}  # task_id -> [ts]

    def classify(self, pkt: ErrorPacket) -> str:
        if pkt.severity == "fatal":
            return FATAL
        if not pkt.retryable:
            return NEEDS_HUMAN
        key = pkt.task_id or pkt.code
        now = time.time()
        hist = [t for t in self._attempts.get(key, []) if now - t < self.WINDOW_S]
        if len(hist) >= self.MAX_RETRIES:
            return NEEDS_HUMAN
        hist.append(now)
        self._attempts[key] = hist
        return RETRYABLE

    def reset(self, task_id: str) -> None:
        self._attempts.pop(task_id, None)
