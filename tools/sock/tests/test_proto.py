"""proto 测试：成帧、CDATA 转义、in_reply_to、帧上限、XML 安全。"""
import unittest

from agent_sock import proto
from agent_sock.proto import Message, ProtoError


class TestFraming(unittest.TestCase):
    def test_roundtrip(self):
        m = Message(type="queue.publish", seq=61, ack=60, from_="orchestrator",
                    body={"queue": "task.dispatch", "message_id": "uuid"})
        frame = proto.encode(m)
        r = proto.FrameReader()
        out = r.feed(frame)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].type, "queue.publish")
        self.assertEqual(out[0].seq, 61)
        self.assertEqual(out[0].body["queue"], "task.dispatch")

    def test_in_reply_to(self):
        m = Message(type="agent.register", seq=9, from_="server",
                    in_reply_to=1, body={"lease_s": "15"})
        r = proto.FrameReader()
        out = r.feed(proto.encode(m))
        self.assertEqual(out[0].in_reply_to, 1)

    def test_split_feed(self):
        m = Message(type="agent.heartbeat", seq=2, from_="agent-7",
                    body={"load": "0.4"})
        frame = proto.encode(m)
        r = proto.FrameReader()
        self.assertEqual(r.feed(frame[:5]), [])
        out = r.feed(frame[5:])
        self.assertEqual(len(out), 1)

    def test_unknown_primitive(self):
        with self.assertRaises(ProtoError):
            Message(type="nope.nope", seq=1, from_="x")

    def test_frame_too_large(self):
        r = proto.FrameReader()
        import struct
        bad = struct.pack(">I", proto.MAX_FRAME_BYTES + 1) + b"x"
        with self.assertRaises(ProtoError) as ctx:
            r.feed(bad)
        self.assertEqual(ctx.exception.code, "ASOCK-2004")


class TestCdata(unittest.TestCase):
    def test_escape_roundtrip(self):
        # R-03：]]> -> ]]]]><![CDATA[>
        self.assertEqual(proto.cdata_escape("a]]>b"), "a]]]]><![CDATA[>b")

    def test_cdata_field(self):
        m = Message(type="queue.publish", seq=1, from_="o",
                    body={"queue": "q", "message_id": "m", "payload": ""})
        frame = proto.encode_with_cdata(m, {"payload": "echo ]]> hi"})
        self.assertIn(b"]]]]><![CDATA[>", frame)
        r = proto.FrameReader()
        out = r.feed(frame)
        self.assertIn("]]>", out[0].body["payload"])

    def test_payload_size_limit(self):
        with self.assertRaises(ProtoError) as ctx:
            proto.check_payload_size(b"x" * (proto.MAX_PAYLOAD_BYTES + 1))
        self.assertEqual(ctx.exception.code, "AEVT-4007")


class TestXmlSecurity(unittest.TestCase):
    def test_doctype_rejected(self):
        xml = b'<?xml version="1.0"?><!DOCTYPE x><msg v="1" type="agent.heartbeat" seq="1" ack="0" ts="1" from="a"/>'
        with self.assertRaises(ProtoError) as ctx:
            proto.decode_frame(xml)
        self.assertEqual(ctx.exception.code, "ASOCK-2005")

    def test_deep_nesting_rejected(self):
        inner = "<a>" * 40 + "x" + "</a>" * 40
        xml = (f'<msg v="1" type="agent.heartbeat" seq="1" ack="0" ts="1" from="a">'
               f"{inner}</msg>").encode()
        with self.assertRaises(ProtoError) as ctx:
            proto.decode_frame(xml)
        self.assertEqual(ctx.exception.code, "ASOCK-2005")


if __name__ == "__main__":
    unittest.main()
