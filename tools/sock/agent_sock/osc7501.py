"""OSC 7501 Program Status Protocol: parser, record store, emitter.

Spec: https://www.superlogical.com/rex/docs/build/program-status (rev 0.4).

Wire format:  ESC ] 7501 ; key=value:key=value ... ST
ST is ESC \\ (0x1B 0x5C) or BEL (0x07).

This module implements both sides:
- terminal side: find sequences in a byte stream, parse reports, keep records
- program side: build sequences (emit), POSIX sh helper

It is transport-agnostic. Feed it pty bytes, or lines from the agent-sock
sidecar file (see TmuxTool.agent_status). Limits follow the spec exactly;
a report that breaks a limit is discarded whole, and every pair is checked
before any stored record is touched.
"""
from __future__ import annotations

import base64
import binascii
import re
from collections import OrderedDict
from dataclasses import dataclass

__all__ = [
    "STATES", "KINDS",
    "Report", "Record", "RecordStore",
    "find_bodies", "parse_body", "emit", "shell_helper",
    "MAX_SEQUENCE_BYTES", "MAX_RECORDS",
]

# ---- spec limits -------------------------------------------------------
MAX_SEQUENCE_BYTES = 4096   # whole sequence, OSC through ST
MAX_KEY_BYTES = 16
MAX_MSG_ENCODED = 2732      # msg: 2732 encoded, 2048 decoded
MAX_MSG_DECODED = 2048
MAX_TITLE_ENCODED = 256     # title: 256 encoded, 192 decoded
MAX_TITLE_DECODED = 192
MAX_ID_BYTES = 128          # id: 128 total, 32 per segment, 8 deep
MAX_ID_SEGMENT = 32
MAX_ID_DEPTH = 8
MAX_RECORDS = 256           # records per terminal; LRU eviction past cap

STATES = frozenset({"idle", "working", "done", "blocked", "error", "clear"})
KINDS = frozenset({"permission", "question", "auth"})

_KEY_RE = re.compile(r"[a-z]+")
_VALUE_RE = re.compile(r"[A-Za-z0-9_.,+/=-]*")
_SEGMENT_RE = re.compile(r"[A-Za-z0-9_.+-]{1,32}")
_APP_RE = re.compile(r"[A-Za-z0-9_.+-]{1,32}")

_OSC_PREFIX = b"\x1b]7501"
_BEL = b"\x07"
_ESC_BS = b"\x1b\\"


# ---- data --------------------------------------------------------------

@dataclass
class Report:
    """One parsed OSC 7501 report. ``id`` None means the root record."""
    state: str
    id: str | None = None
    kind: str | None = None
    progress: int | None = None   # None = indeterminate / absent
    app: str | None = None
    title: str | None = None       # decoded UTF-8
    msg: str | None = None         # decoded UTF-8


@dataclass
class Record:
    """What the terminal stores per id: exactly the last report's keys."""
    id: str | None
    state: str
    kind: str | None = None
    progress: int | None = None
    app: str | None = None
    title: str | None = None
    msg: str | None = None


# ---- sequence scanning ---------------------------------------------------

def find_bodies(data: bytes) -> list[bytes]:
    """Extract raw OSC 7501 bodies from a byte stream.

    Finds ``ESC ] 7501 ;`` ... ST (ESC \\ or BEL). Unterminated sequences
    and sequences longer than 4096 bytes are skipped. Never raises.
    """
    bodies: list[bytes] = []
    i = 0
    n = len(data)
    while True:
        j = data.find(_OSC_PREFIX, i)
        if j < 0:
            break
        k = j + len(_OSC_PREFIX)
        while k < n and data[k:k + 1] in b" \t":
            k += 1
        if k >= n or data[k:k + 1] != b";":
            i = j + 1
            continue
        k += 1
        # whole sequence (OSC through ST) must fit in 4096 bytes
        cap = j + MAX_SEQUENCE_BYTES
        end = -1
        st_len = 0
        p = k
        while p < cap and p < n:
            b = data[p:p + 1]
            if b == _BEL:
                end, st_len = p, 1
                break
            if b == b"\x1b" and data[p + 1:p + 2] == b"\\":
                end, st_len = p, 2
                break
            p += 1
        if end < 0 or end + st_len - j > MAX_SEQUENCE_BYTES:
            i = j + 1
            continue
        bodies.append(data[k:end])
        i = end + st_len
    return bodies


# ---- report parsing ------------------------------------------------------

def _has_control_char(text: str) -> bool:
    for ch in text:
        o = ord(ch)
        if o <= 0x1F or o == 0x7F or 0x80 <= o <= 0x9F:
            return True
    return False


def _decode_text(enc: str | None, max_enc: int, max_dec: int) -> str | None:
    """Decode a base64 free-text value. Returns None when absent.

    Raises _Discard when the report must be discarded whole.
    """
    if enc is None:
        return None
    if len(enc) > max_enc:          # byte length: value charset is ASCII-only
        raise _Discard()
    padded = enc + "=" * (-len(enc) % 4)   # padding is optional per spec
    try:
        raw = base64.b64decode(padded, validate=True)  # standard alphabet
    except (binascii.Error, ValueError):
        raise _Discard()
    if len(raw) > max_dec:
        raise _Discard()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise _Discard()
    if _has_control_char(text):
        raise _Discard()
    return text


class _Discard(Exception):
    """Internal: the whole report must be discarded."""


def _valid_id(raw: str) -> bool:
    if len(raw) > MAX_ID_BYTES or not raw:
        return False
    segments = raw.split("/")
    if len(segments) > MAX_ID_DEPTH:
        return False
    return all(_SEGMENT_RE.fullmatch(s) for s in segments)


def parse_body(body: str) -> Report | None:
    """Parse one OSC 7501 body (text between ``;`` and ST).

    Returns None when the report is discarded or ignored per spec.
    Never raises on malformed input.
    """
    pairs: dict[str, str] = {}
    try:
        for raw_pair in body.split(":"):
            eq = raw_pair.find("=")
            if eq <= 0:
                continue                       # no '=' or empty key: skip
            key = raw_pair[:eq].strip()
            value = raw_pair[eq + 1:].strip()   # value may contain '='
            if len(key) > MAX_KEY_BYTES:
                return None                    # breaks limit: discard whole
            if not _KEY_RE.fullmatch(key):
                continue                       # malformed key: skip pair
            if not _VALUE_RE.fullmatch(value):
                continue                       # bad byte: skip pair
            pairs[key] = value                 # unknown keys kept; last wins

        state = pairs.get("state")
        if state not in STATES:
            return None                        # missing/unknown state: ignore

        rec_id: str | None = None
        if "id" in pairs:
            if not _valid_id(pairs["id"]):
                return None                    # bad id: ignore, not root
            rec_id = pairs["id"]

        kind: str | None = None
        if state == "blocked":
            k = pairs.get("kind")
            kind = k if k in KINDS else None    # unrecognized -> absent

        progress: int | None = None
        if state in ("working", "blocked"):
            raw_p = pairs.get("progress")
            # "Anything else is treated as absent"; cap length before int()
            if raw_p is not None and len(raw_p) <= 3 and raw_p.isdigit():
                p = int(raw_p)
                if 0 <= p <= 100:
                    progress = p

        app = pairs.get("app")
        if app is not None and not _APP_RE.fullmatch(app):
            app = None                         # outside charset -> absent

        title = _decode_text(pairs.get("title"), MAX_TITLE_ENCODED,
                             MAX_TITLE_DECODED)
        msg = _decode_text(pairs.get("msg"), MAX_MSG_ENCODED, MAX_MSG_DECODED)

        return Report(state=state, id=rec_id, kind=kind, progress=progress,
                      app=app, title=title, msg=msg)
    except _Discard:
        return None


# ---- record store ----------------------------------------------------------

class RecordStore:
    """Per-terminal record set. One record per id; each report replaces
    its record completely. ``state=clear`` removes the addressed record
    and everything beneath it (no id: everything). Past 256 records the
    least-recently-updated record is evicted."""

    def __init__(self, max_records: int = MAX_RECORDS):
        self._records: OrderedDict[str, Record] = OrderedDict()
        self.max_records = max_records

    @staticmethod
    def _key(rec_id: str | None) -> str:
        return rec_id if rec_id is not None else ""

    def __len__(self) -> int:
        return len(self._records)

    def get(self, rec_id: str | None) -> Record | None:
        return self._records.get(self._key(rec_id))

    def apply(self, report: Report) -> None:
        if report.state == "clear":
            self.clear(report.id)
            return
        key = self._key(report.id)
        if key in self._records:
            del self._records[key]
        self._records[key] = Record(
            id=report.id, state=report.state, kind=report.kind,
            progress=report.progress, app=report.app,
            title=report.title, msg=report.msg)
        while len(self._records) > self.max_records:
            self._records.popitem(last=False)   # evict least recently updated

    def clear(self, rec_id: str | None) -> None:
        if rec_id is None:
            self._records.clear()
            return
        prefix = rec_id + "/"
        for key in [k for k in self._records
                    if k == rec_id or k.startswith(prefix)]:
            del self._records[key]

    def ingest(self, data: bytes) -> int:
        """Parse every OSC 7501 sequence in ``data`` and apply. Returns
        the number of reports applied (including clears)."""
        applied = 0
        for body in find_bodies(data):
            # latin-1: 1:1 byte mapping so byte-level checks stay exact
            report = parse_body(body.decode("latin-1"))
            if report is not None:
                self.apply(report)
                applied += 1
        return applied

    def effective_app(self, rec_id: str | None) -> str | None:
        """Nearest ancestor (or self) that has an app; None if none do."""
        cur = rec_id
        while True:
            rec = self.get(cur)
            if rec is not None and rec.app:
                return rec.app
            if cur is None:
                return None
            parent = cur.rpartition("/")[0]
            cur = parent if parent else None

    def snapshot(self) -> dict:
        """Structured status: flat id-path list, root first, app resolved."""
        out = []
        for key in sorted(self._records, key=lambda k: (k != "", k)):
            rec = self._records[key]
            out.append({
                "id": rec.id,
                "state": rec.state,
                "kind": rec.kind,
                "progress": rec.progress,
                "app": rec.app or self.effective_app(rec.id),
                "title": rec.title,
                "msg": rec.msg,
            })
        return {"records": out}


# ---- emitter (program side) ----------------------------------------------------

def emit(state: str, *, id: str | None = None, kind: str | None = None,
         progress: int | None = None, app: str | None = None,
         title: str | None = None, msg: str | None = None) -> str:
    """Build one OSC 7501 sequence. Raises ValueError on invalid input.

    ``title``/``msg`` are plain strings; they are base64-encoded here.
    """
    if state not in STATES:
        raise ValueError(f"unknown state: {state!r}")
    if kind is not None:
        if state != "blocked":
            raise ValueError("kind is only valid with state=blocked")
        if kind not in KINDS:
            raise ValueError(f"unknown kind: {kind!r}")
    if progress is not None:
        if state not in ("working", "blocked"):
            raise ValueError("progress is only valid with working/blocked")
        if not isinstance(progress, int) or not 0 <= progress <= 100:
            raise ValueError(f"progress must be int 0..100: {progress!r}")
    if app is not None and not _APP_RE.fullmatch(app):
        raise ValueError(f"bad app: {app!r}")
    if id is not None and not _valid_id(id):
        raise ValueError(f"bad id: {id!r}")

    parts = [f"state={state}"]
    if id is not None:
        parts.append(f"id={id}")
    if kind is not None:
        parts.append(f"kind={kind}")
    if progress is not None:
        parts.append(f"progress={progress}")
    if app is not None:
        parts.append(f"app={app}")
    for name, text in (("title", title), ("msg", msg)):
        if text is not None:
            enc = base64.b64encode(text.encode("utf-8")).decode("ascii")
            parts.append(f"{name}={enc}")
    sequence = f"\x1b]7501;{':'.join(parts)}\x1b\\"
    if len(sequence.encode("utf-8")) > MAX_SEQUENCE_BYTES:
        raise ValueError("report exceeds 4096 bytes; terminal would discard it")
    return sequence


def shell_helper() -> str:
    """POSIX sh helper emitting OSC 7501. Source it, then call::

        asock_emit_status working msg="Deploying" app=deploy progress=40

    ``msg=``/``title=`` values are base64-encoded automatically. When
    ``$ASOCK_7501_FILE`` is set, the sequence is also appended there
    (agent-sock sidecar; tmux swallows unknown OSCs so the pane buffer
    cannot carry them — see TmuxTool.agent_status).
    """
    return r"""# asock_emit_status: emit OSC 7501 program status (POSIX sh).
# Usage: asock_emit_status <state> [key=value ...]
#   e.g. asock_emit_status working msg="Deploying" app=deploy progress=40
#        asock_emit_status blocked kind=permission msg="Approve?"
#        asock_emit_status done msg="All green"
# msg=/title= values are base64-encoded automatically.
# When $ASOCK_7501_FILE is set, the sequence is appended there too.
asock_emit_status() {
  _s7501_state=$1; shift
  _s7501_body="state=$_s7501_state"
  for _s7501_kv in "$@"; do
    case "$_s7501_kv" in
      msg=*|title=*)
        _s7501_k=${_s7501_kv%%=*}
        _s7501_v=${_s7501_kv#*=}
        _s7501_v=$(printf '%s' "$_s7501_v" | base64 | tr -d '\n')
        _s7501_body="$_s7501_body:$_s7501_k=$_s7501_v"
        ;;
      *)
        _s7501_body="$_s7501_body:$_s7501_kv"
        ;;
    esac
  done
  _s7501_seq=$(printf '\033]7501;%s\033\\' "$_s7501_body")
  printf '%s' "$_s7501_seq"
  if [ -n "$ASOCK_7501_FILE" ]; then
    printf '%s\n' "$_s7501_seq" >> "$ASOCK_7501_FILE"
  fi
  unset _s7501_state _s7501_body _s7501_kv _s7501_k _s7501_v _s7501_seq
}
"""
