"""agent_sock：agent socket 通信协议 Python 实现。

DESIGN.md v4。TLA+ 模型（tla/）是 spec，实现与之一致。
"""
from . import errors, proto
from .proto import PRIMITIVES

__version__ = "0.1.0"
__all__ = ["errors", "proto", "PRIMITIVES"]
