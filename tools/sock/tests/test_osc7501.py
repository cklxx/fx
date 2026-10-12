"""OSC 7501 parser tests. Pure unit tests; no tmux needed.

Spec: https://www.superlogical.com/rex/docs/build/program-status
"""
import base64
import shutil
import unittest

from agent_sock import osc7501
from agent_sock.osc7501 import RecordStore, find_bodies, parse_body


def b64(s: str) -> str:
    return base64.b64encode(s.encode()).decode()


def seq(body: str, st: str = "\x1b\\") -> bytes:
    return f"\x1b]7501;{body}{st}".encode("latin-1")


class TestFindBodies(unittest.TestCase):
    def test_basic(self):
        data = b"noise" + seq("state=working") + b"tail"
        self.assertEqual(find_bodies(data), [b"state=working"])

    def test_bel_terminator(self):
        data = b"\x1b]7501;state=idle\x07"
        self.assertEqual(find_bodies(data), [b"state=idle"])

    def test_multiple(self):
        data = seq("state=working") + seq("state=done")
        self.assertEqual(len(find_bodies(data)), 2)

    def test_unterminated_skipped(self):
        self.assertEqual(find_bodies(b"\x1b]7501;state=working"), [])

    def test_over_4096_skipped(self):
        body = b"state=working" + b"x" * 5000
        self.assertEqual(find_bodies(b"\x1b]7501;" + body + b"\x1b\\"), [])

    def test_other_osc_ignored(self):
        # OSC 0 (window title) must not match
        data = b"\x1b]0;mytitle\x07" + seq("state=idle")
        self.assertEqual(find_bodies(data), [b"state=idle"])

    def test_75010_not_7501(self):
        self.assertEqual(find_bodies(b"\x1b]75010;state=idle\x07"), [])

    def test_never_raises(self):
        find_bodies(b"\x1b]7501;\xff\xfe\x1b\\")
        find_bodies(b"\x1b]")


class TestParseBasics(unittest.TestCase):
    def test_spec_example_working(self):
        r = parse_body(f"state=working:app=brew:msg={b64('Installing updates')}")
        self.assertEqual((r.state, r.app, r.msg),
                         ("working", "brew", "Installing updates"))

    def test_spec_example_blocked(self):
        r = parse_body(
            f"state=blocked:kind=auth:app=brew:msg={b64('Password required')}")
        self.assertEqual((r.state, r.kind, r.msg),
                         ("blocked", "auth", "Password required"))

    def test_missing_state_ignored(self):
        self.assertIsNone(parse_body("app=brew"))

    def test_unknown_state_ignored(self):
        self.assertIsNone(parse_body("state=spinning"))

    def test_unknown_keys_ignored(self):
        r = parse_body("state=idle:foo=bar:answer=42")
        self.assertEqual(r.state, "idle")

    def test_repeat_last_wins(self):
        r = parse_body("state=working:state=done:app=x")
        self.assertEqual(r.state, "done")

    def test_malformed_pair_skipped(self):
        # no '=', empty key, byte outside value set
        r = parse_body("state=working:broken:app-ok=x:msg=bad value!")
        self.assertEqual(r.state, "working")

    def test_whitespace_stripped(self):
        r = parse_body("state = working : app = brew")
        self.assertEqual((r.state, r.app), ("working", "brew"))

    def test_feature_query_ignored(self):
        self.assertIsNone(parse_body("?"))

    def test_empty_body_ignored(self):
        self.assertIsNone(parse_body(""))

    def test_key_too_long_discards_whole(self):
        r = parse_body("state=working:" + "k" * 17 + "=x")
        self.assertIsNone(r)

    def test_value_with_equals(self):
        # '=' is in the value set; split on first '='
        r = parse_body(f"state=idle:msg={b64('a=b')}")
        self.assertEqual(r.msg, "a=b")


class TestIds(unittest.TestCase):
    def test_root(self):
        r = parse_body("state=idle")
        self.assertIsNone(r.id)

    def test_hierarchy(self):
        r = parse_body("state=working:id=deploy/us-east")
        self.assertEqual(r.id, "deploy/us-east")

    def test_bad_id_ignored_not_root(self):
        # id that passes pair charset but fails id grammar -> whole ignored
        self.assertIsNone(parse_body("state=working:id=" + "a" * 33))
        self.assertIsNone(parse_body(
            "state=working:id=" + "/".join(["a"] * 9)))
        self.assertIsNone(parse_body("state=working:id="))
        # value charset violation -> pair skipped, id absent -> root report
        r = parse_body("state=working:id=has space")
        self.assertIsNotNone(r)
        self.assertIsNone(r.id)

    def test_clear_child(self):
        s = RecordStore()
        s.ingest(seq("state=working:id=deploy"))
        s.ingest(seq("state=working:id=deploy/us-east"))
        s.ingest(seq("state=clear:id=deploy/us-east"))
        self.assertIsNotNone(s.get("deploy"))
        self.assertIsNone(s.get("deploy/us-east"))

    def test_clear_all(self):
        s = RecordStore()
        s.ingest(seq("state=working:id=a") + seq("state=working"))
        s.ingest(seq("state=clear"))
        self.assertEqual(len(s), 0)

    def test_report_replaces_record(self):
        s = RecordStore()
        s.ingest(seq(f"state=working:app=x:msg={b64('one')}"))
        s.ingest(seq("state=idle:app=x"))
        rec = s.get(None)
        self.assertEqual(rec.state, "idle")
        self.assertIsNone(rec.msg)   # missing key is gone afterwards

    def test_app_inheritance(self):
        s = RecordStore()
        s.ingest(seq("state=working:app=deploy"))
        s.ingest(seq("state=working:id=us-east"))
        self.assertEqual(s.effective_app("us-east"), "deploy")
        # every id is transitively a child of root per spec hierarchy
        self.assertEqual(s.effective_app("nowhere"), "deploy")


class TestKindProgress(unittest.TestCase):
    def test_kind_only_with_blocked(self):
        r = parse_body("state=working:kind=permission")
        self.assertIsNone(r.kind)

    def test_bad_kind_absent(self):
        r = parse_body("state=blocked:kind=maybe")
        self.assertIsNone(r.kind)

    def test_progress_range(self):
        r = parse_body("state=working:progress=40")
        self.assertEqual(r.progress, 40)
        self.assertIsNone(parse_body("state=working:progress=101").progress)
        self.assertIsNone(parse_body("state=working:progress=x").progress)

    def test_progress_absent_means_indeterminate(self):
        self.assertIsNone(parse_body("state=working").progress)

    def test_progress_ignored_with_done(self):
        r = parse_body("state=done:progress=100")
        self.assertIsNone(r.progress)


class TestTextLimits(unittest.TestCase):
    def test_optional_padding(self):
        r = parse_body("state=idle:msg=YWJj")   # "abc", no padding needed
        self.assertEqual(r.msg, "abc")
        r2 = parse_body("state=idle:msg=YWI")   # "ab", padding omitted
        self.assertEqual(r2.msg, "ab")

    def test_bad_base64_discards_whole(self):
        # '.' passes the pair value charset but is not standard base64
        self.assertIsNone(parse_body("state=idle:msg=a.b"))
        # '!' fails the value charset -> pair skipped, msg absent (spec)
        r = parse_body("state=idle:msg=!!!")
        self.assertIsNotNone(r)
        self.assertIsNone(r.msg)

    def test_control_char_discards_whole(self):
        bad = b64("line1\nline2")
        self.assertIsNone(parse_body(f"state=idle:msg={bad}"))

    def test_msg_too_long_discards_whole(self):
        # encoded limit 2732; build a value that passes pair charset
        self.assertIsNone(parse_body("state=idle:msg=" + "A" * 2733))

    def test_title_limits(self):
        ok = b64("t" * 100)
        r = parse_body(f"state=idle:title={ok}")
        self.assertEqual(r.title, "t" * 100)
        self.assertIsNone(parse_body("state=idle:title=" + "A" * 257))

    def test_bad_app_absent(self):
        r = parse_body("state=idle:app=has space")
        # 'has space' fails pair charset -> pair skipped -> app absent
        self.assertIsNone(r.app)
        r2 = parse_body("state=idle:app=" + "a" * 33)
        self.assertIsNone(r2.app)


class TestRecordCap(unittest.TestCase):
    def test_lru_eviction(self):
        s = RecordStore(max_records=4)
        for i in range(6):
            s.ingest(seq(f"state=working:id=r{i}"))
        self.assertEqual(len(s), 4)
        self.assertIsNone(s.get("r0"))
        self.assertIsNotNone(s.get("r5"))


class TestEmitter(unittest.TestCase):
    def test_roundtrip(self):
        s = osc7501.emit("working", app="brew", msg="Installing",
                         progress=40, id="us-east")
        bodies = find_bodies(s.encode("latin-1"))
        self.assertEqual(len(bodies), 1)
        r = parse_body(bodies[0].decode("latin-1"))
        self.assertEqual((r.state, r.app, r.msg, r.progress, r.id),
                         ("working", "brew", "Installing", 40, "us-east"))

    def test_emit_validates(self):
        with self.assertRaises(ValueError):
            osc7501.emit("spinning")
        with self.assertRaises(ValueError):
            osc7501.emit("working", kind="permission")
        with self.assertRaises(ValueError):
            osc7501.emit("working", progress=101)

    def test_shell_helper_syntax(self):
        # helper must be valid sh; function defined, no syntax error
        import subprocess
        helper = osc7501.shell_helper()
        r = subprocess.run(["sh", "-n", "-c", helper],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_shell_helper_emits_and_sidecars(self):
        import os
        import subprocess
        import tempfile
        helper = osc7501.shell_helper()
        with tempfile.TemporaryDirectory() as d:
            sidecar = os.path.join(d, "status.osc")
            script = (helper +
                      f"ASOCK_7501_FILE={sidecar}\n"
                      "asock_emit_status working msg=\"hello world\" app=demo\n")
            r = subprocess.run(["sh", "-c", script],
                               capture_output=True)
            self.assertEqual(r.returncode, 0)
            # OSC sequence on stdout
            bodies = find_bodies(r.stdout)
            self.assertEqual(len(bodies), 1)
            rep = parse_body(bodies[0].decode("latin-1"))
            self.assertEqual((rep.state, rep.msg, rep.app),
                             ("working", "hello world", "demo"))
            # same bytes appended to sidecar
            with open(sidecar, "rb") as f:
                content = f.read()
            self.assertIn(bodies[0], content)


HAS_TMUX = shutil.which("tmux") is not None


@unittest.skipUnless(HAS_TMUX, "tmux not installed")
class TestTmuxIntegration(unittest.TestCase):
    """Real tmux: pane-emitted OSC is swallowed (documents the limit);
    the sidecar file is the reliable channel."""

    def test_pane_osc_swallowed_sidecar_works(self):
        from agent_sock.tmux_tool import TmuxTool
        tool = TmuxTool(sock="/tmp/asock-test-osc7501.sock")
        tool.install_shell_helper()
        tool.spawn_agent("osc1", "bash", status=True)
        try:
            pane = "asock-osc1:0"
            import time
            time.sleep(1)  # 等 shell prompt 就绪
            # 1. emit OSC straight to the pty: tmux swallows it
            tool._run("send-keys", "-t", pane,
                      "printf '\\e]7501;state=working:app=pty\\e\\\\'",
                      "Enter", check=False)
            time.sleep(1)
            raw = tool.capture_raw(pane)
            self.assertEqual(osc7501.find_bodies(raw), [],
                             "tmux unexpectedly preserved OSC 7501")
            # 2. sidecar path: source helper, emit -> file
            tool._run("send-keys", "-t", pane,
                      ". ~/.agent-sock/osc7501.sh", "Enter", check=False)
            time.sleep(0.5)
            tool._run("send-keys", "-t", pane,
                      "asock_emit_status working msg=\"via file\" app=demo",
                      "Enter", check=False)
            time.sleep(1)
            st = tool.agent_status(pane)
            self.assertIsNotNone(st)
            rec = st["records"][0]
            self.assertEqual((rec["state"], rec["msg"], rec["app"]),
                             ("working", "via file", "demo"))
        finally:
            tool.terminate("osc1")


if __name__ == "__main__":
    unittest.main()
