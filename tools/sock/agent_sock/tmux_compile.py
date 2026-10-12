"""tmux_compile driver: compile a YAML interaction, run it on an agent's pane.

The tmux_compile compiler lives in this repo at tools/tmux_compile/
(part of the fx performance project). Put that directory on PYTHONPATH
so `tmux_compile.compiler` is importable.

Relationship with tmux_tool (one-directional):
  - tmux_compile products are standalone bash. They call the tmux CLI
    directly and never import agent_sock. Zero dependencies by design.
  - This module is the driver side: compile the DSL, then run the product
    with TMUX_SOCK_PATH pointed at the agent's tmux server and PANE at the
    agent's pane. The product's -S path mode exists for exactly this.

When to use this vs TmuxTool directly (see the guide in cklxx/fx
tools/tmux_compile/docs/TMUX_COMPILE_GUIDE.md):
  - compile_and_run: deterministic multi-step flows (deploy checks, bisect,
    review loops). Compile once, run many times; failures name the step.
  - TmuxTool.run/capture: ad-hoc commands, or steps needing LLM judgment
    mid-flow (compile only handles deterministic flows).
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import time

from . import errors
from .tmux_tool import TmuxTool, _session_name

_OK_RE = re.compile(r"^COMPILE-OK steps=(\d+)\s*$")
_FAIL_RE = re.compile(r"COMPILE-FAIL\b(.*)$")


def _load_compiler():
    try:
        from tmux_compile.compiler import compile_dsl, CompileError
    except ImportError as e:
        raise errors.make(
            "ACOM-1001",
            f"tmux_compile package not importable: {e}. "
            "It lives in this repo at tools/tmux_compile/; add that to PYTHONPATH.",
        )
    return compile_dsl, CompileError


def compile_and_run(
    tool: TmuxTool,
    agent_id: str,
    dsl_path: str,
    params: dict | None = None,
    target: str | None = None,
    timeout_s: float = 3600,
) -> dict:
    """Compile dsl_path and run the product against the agent's pane.

    - Spawns the agent session (bash) if not alive.
    - target: tmux pane address; default "<asock-agent_id>:0.0".
    - Returns a dict (never raises for product outcomes):
        {ok, exit_code, steps, stdout, stderr, fail_reason, timeout,
         agent_id, pane}
    - Raises ErrorPacket (ACOM-1001) on compile errors, (ACOM-2001) on
      driver timeout.
    """
    compile_dsl, CompileError = _load_compiler()
    session = _session_name(agent_id)
    if not tool.agent_alive(agent_id):
        tool.spawn_agent(agent_id, "bash")
        time.sleep(1.0)
    pane = target or f"{session}:0.0"

    tmpd = tempfile.mkdtemp(prefix="asock-tc-")
    product = os.path.join(tmpd, "product.sh")
    try:
        compile_dsl(dsl_path, product, params=params)
    except CompileError as e:
        loc = f"{dsl_path}:{e.line}" if e.line else dsl_path
        raise errors.make("ACOM-1001", f"compile failed: {loc}: {e.message}",
                          agent_id=agent_id)

    env = dict(os.environ, TMUX_SOCK_PATH=tool.sock, PANE=pane)
    try:
        r = subprocess.run(
            ["bash", product],
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        # Nudge the pane out of whatever it was doing; the product is dead.
        tool._run("send-keys", "-t", pane, "C-c", check=False)
        raise errors.make(
            "ACOM-2001",
            f"product timed out after {timeout_s}s "
            f"(partial stdout: {(e.stdout or '')[-500:]})",
            agent_id=agent_id,
        )

    steps = None
    fail_reason = None
    for line in r.stdout.splitlines():
        m = _OK_RE.match(line.strip())
        if m:
            steps = int(m.group(1))
    for line in r.stderr.splitlines():
        m = _FAIL_RE.search(line.strip())
        if m:
            fail_reason = m.group(1).strip()
    return {
        "ok": r.returncode == 0,
        "exit_code": r.returncode,
        "steps": steps,
        "stdout": r.stdout,
        "stderr": r.stderr,
        "fail_reason": fail_reason,
        "timeout": False,
        "agent_id": agent_id,
        "pane": pane,
    }
