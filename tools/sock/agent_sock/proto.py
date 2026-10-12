"""Wire 协议：XML 编解码、成帧、11 原语。

DESIGN.md §2。TLA+ 对应：tla/ReqReply.tla（in_reply_to）、tla/SeqAck.tla（seq/ack）。
"""
from __future__ import annotations

import struct
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

PROTOCOL_VERSION = "1"

# §2.1 传输约束
MAX_FRAME_BYTES = 16 * 1024 * 1024
MAX_PAYLOAD_BYTES = 8 * 1024 * 1024
MAX_XML_DEPTH = 32
MAX_XML_ELEMENTS = 100000
FRAME_HEADER = struct.Struct(">I")  # 4 字节大端长度前缀

# §2.3 原语（11 个）
REGISTER = "agent.register"
HEARTBEAT = "agent.heartbeat"
DEREGISTER = "agent.deregister"
CARD = "agent.card"
Q_DECLARE = "queue.declare"
Q_PUBLISH = "queue.publish"
Q_CONSUME = "queue.consume"
Q_UNCONSUME = "queue.unconsume"
Q_DELIVER = "queue.deliver"
Q_ACK = "queue.ack"
ERROR = "error"

PRIMITIVES = frozenset({
    REGISTER, HEARTBEAT, DEREGISTER, CARD,
    Q_DECLARE, Q_PUBLISH, Q_CONSUME, Q_UNCONSUME,
    Q_DELIVER, Q_ACK, ERROR,
})

# 信封属性（§2.2）
ENVELOPE_ATTRS = ("v", "type", "seq", "ack", "ts", "from", "in_reply_to")


class ProtoError(Exception):
    """协议层错误。调用方转为 ASOCK-* 错误码。"""
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def cdata_escape(text: str) -> str:
    """R-03：]]> 转义为 ]]]]><![CDATA[>。"""
    return text.replace("]]>", "]]]]><![CDATA[>")


@dataclass
class Message:
    """一条 wire 消息。"""
    type: str
    seq: int
    ack: int = 0
    ts: float = field(default_factory=time.time)
    from_: str = ""
    in_reply_to: int | None = None
    body: dict = field(default_factory=dict)  # 子元素名 -> 文本或嵌套 dict
    raw_xml: str = ""  # CDATA 载荷等需原文保留的场景

    def __post_init__(self):
        if self.type not in PRIMITIVES:
            raise ProtoError("ASOCK-2002", f"unknown primitive: {self.type}")


def _build_body(parent: ET.Element, body: dict) -> None:
    for key, val in body.items():
        el = ET.SubElement(parent, key)
        if isinstance(val, dict):
            _build_body(el, val)
        elif isinstance(val, list):
            for item in val:
                sub = ET.SubElement(el, key.rstrip("s") if key.endswith("s") else "item")
                if isinstance(item, dict):
                    _build_body(sub, item)
                else:
                    sub.text = str(item)
        else:
            el.text = str(val)


def encode(msg: Message) -> bytes:
    """Message -> 带长度前缀的帧。"""
    if msg.type not in PRIMITIVES:
        raise ProtoError("ASOCK-2002", f"unknown primitive: {msg.type}")
    root = ET.Element("msg")
    root.set("v", PROTOCOL_VERSION)
    root.set("type", msg.type)
    root.set("seq", str(msg.seq))
    root.set("ack", str(msg.ack))
    root.set("ts", repr(msg.ts))
    root.set("from", msg.from_)
    if msg.in_reply_to is not None:
        root.set("in_reply_to", str(msg.in_reply_to))
    _build_body(root, msg.body)
    xml_text = ET.tostring(root, encoding="unicode")
    # CDATA 载荷：调用方在 body 中用 ("__cdata__", text) 标记
    data = xml_text.encode("utf-8")
    if len(data) > MAX_FRAME_BYTES:
        raise ProtoError("ASOCK-2004", f"frame {len(data)} exceeds {MAX_FRAME_BYTES}")
    return FRAME_HEADER.pack(len(data)) + data


def encode_with_cdata(msg: Message, cdata_fields: dict[str, str]) -> bytes:
    """带 CDATA 载荷的编码。cdata_fields: 元素名 -> 原文（自动转义）。"""
    root = ET.Element("msg")
    root.set("v", PROTOCOL_VERSION)
    root.set("type", msg.type)
    root.set("seq", str(msg.seq))
    root.set("ack", str(msg.ack))
    root.set("ts", repr(msg.ts))
    root.set("from", msg.from_)
    if msg.in_reply_to is not None:
        root.set("in_reply_to", str(msg.in_reply_to))
    _build_body(root, msg.body)
    parts = [ET.tostring(root, encoding="unicode")]
    # 手工拼接 CDATA（ElementTree 不直接支持 CDATA 写出）
    out = []
    for chunk in parts:
        out.append(chunk)
    xml_text = "".join(out)
    # 把占位元素替换为 CDATA
    for name, text in cdata_fields.items():
        placeholder = f"<{name} />"
        cdata = f"<{name}><![CDATA[{cdata_escape(text)}]]></{name}>"
        xml_text = xml_text.replace(placeholder, cdata)
    data = xml_text.encode("utf-8")
    if len(data) > MAX_FRAME_BYTES:
        raise ProtoError("ASOCK-2004", f"frame {len(data)} exceeds {MAX_FRAME_BYTES}")
    return FRAME_HEADER.pack(len(data)) + data


class _DepthLimiter:
    """R-13：解析时限制嵌套深度与元素数。"""

    def __init__(self):
        self.depth = 0
        self.count = 0


def _check_element(el: ET.Element, limiter: _DepthLimiter) -> None:
    limiter.count += 1
    if limiter.count > MAX_XML_ELEMENTS:
        raise ProtoError("ASOCK-2005", "xml element count exceeded")
    limiter.depth += 1
    if limiter.depth > MAX_XML_DEPTH:
        raise ProtoError("ASOCK-2005", "xml nesting depth exceeded")
    for child in el:
        _check_element(child, limiter)
    limiter.depth -= 1


def decode_frame(data: bytes) -> Message:
    """不带长度前缀的 XML -> Message。R-13：拒绝 DOCTYPE，限制深度/元素数。"""
    text = data.decode("utf-8")
    # R-13：拒绝 DOCTYPE（防二次展开）；ElementTree 默认不处理外部实体，
    # 这里显式拒绝 DOCTYPE 声明。
    if "<!DOCTYPE" in text.upper():
        raise ProtoError("ASOCK-2005", "DOCTYPE not allowed")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        raise ProtoError("ASOCK-2006", f"xml parse error: {e}")
    if root.tag != "msg":
        raise ProtoError("ASOCK-2006", f"root must be <msg>, got <{root.tag}>")
    _check_element(root, _DepthLimiter())
    v = root.get("v")
    if v != PROTOCOL_VERSION:
        raise ProtoError("ASOCK-2002", f"unsupported protocol version: {v}")
    mtype = root.get("type", "")
    if mtype not in PRIMITIVES:
        raise ProtoError("ASOCK-2002", f"unknown primitive: {mtype}")
    try:
        seq = int(root.get("seq", "0"))
        ack = int(root.get("ack", "0"))
        ts = float(root.get("ts", "0"))
    except ValueError:
        raise ProtoError("ASOCK-2006", "bad envelope numeric attribute")
    in_reply_to = root.get("in_reply_to")
    body: dict = {}
    for child in root:
        if len(child):
            body[child.tag] = {c.tag: (c.text or "") for c in child}
        else:
            body[child.tag] = child.text or ""
    return Message(
        type=mtype, seq=seq, ack=ack, ts=ts,
        from_=root.get("from", ""),
        in_reply_to=int(in_reply_to) if in_reply_to is not None else None,
        body=body, raw_xml=text,
    )


class FrameReader:
    """从字节流中按长度前缀切帧。R-04：超限直接拒收。"""

    def __init__(self):
        self._buf = bytearray()

    def feed(self, data: bytes) -> list[Message]:
        self._buf.extend(data)
        out = []
        while True:
            if len(self._buf) < FRAME_HEADER.size:
                return out
            (length,) = FRAME_HEADER.unpack_from(self._buf)
            if length > MAX_FRAME_BYTES:
                raise ProtoError("ASOCK-2004",
                                 f"frame length {length} exceeds {MAX_FRAME_BYTES}")
            if len(self._buf) < FRAME_HEADER.size + length:
                return out
            payload = bytes(self._buf[FRAME_HEADER.size:FRAME_HEADER.size + length])
            del self._buf[:FRAME_HEADER.size + length]
            out.append(decode_frame(payload))
        return out


def check_payload_size(payload: bytes) -> None:
    """R-04：queue.publish 载荷上限 8MB，超限回 error（AEVT-4007 参数错误）。"""
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ProtoError("AEVT-4007", f"payload {len(payload)} exceeds {MAX_PAYLOAD_BYTES}")
