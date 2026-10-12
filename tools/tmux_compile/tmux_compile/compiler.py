"""tmux_compile compiler: YAML DSL -> readable bash product.

DSL:
    name: <string>            # required; {{param}} allowed
    params:                   # optional
      branch: {required: true}
      base: {default: "main"}
      mode: "fast"            # scalar = default value
    steps:                    # required, non-empty list
      - run: <shell, single or multi-line>
        timeout_s: 60         # optional, >0
        assert_exit: 0        # optional; checks LAST line's exit code
      - wait_for: <ERE pattern>
        timeout_s: 60         # optional, >0
      - branch:
          if_output_contains: <ERE pattern>
          then: [<steps>]
          else: [<steps>]     # optional
      - parallel:             # one level only (no nesting); legs get own panes
          timeout_s: 900      # optional: whole-block cap
          legs:
            - name: security  # required, unique per block
              timeout_s: 300  # optional: per-leg cap
              steps: [...]    # run/wait_for/branch/fail/retry (no parallel)
      - retry:                # bounded repeat-until; no nesting
          attempts: 3         # required, >= 1
          delay_s: 5          # optional, >= 0; sleep between attempts
          until_output_contains: "READY"  # ERE on fresh pane output
          until_exit_zero: false          # or: stop when last run's rc == 0
          steps: [...]        # run/wait_for/branch/fail/parallel (no retry)
                              # at least one stop condition required;
                              # inner step failure aborts immediately
      - fail: <reason>

{{param}} substitution is compile-time (from --param K=V). Values must be
single-line. Unknown/unprovided-required params are compile errors (exit 20).

Product contract:
    exit 0  -> stdout ends with "COMPILE-OK steps=N"
    exit 10 -> single-step timeout:      stderr "COMPILE-FAIL [leg=L ]step=N reason=timeout"
    exit 11 -> pattern wait timeout:     stderr "COMPILE-FAIL [leg=L ]step=N reason=pattern-timeout"
    exit 12 -> assert_exit mismatch:     stderr "COMPILE-FAIL [leg=L ]step=N reason=nonzero-exit rc=R"
    exit 13 -> fail step:                stderr "COMPILE-FAIL [leg=L ]step=N reason=..."
    exit 14 -> parallel leg failed:      stderr "COMPILE-FAIL step=N reason=parallel-leg-failed legs=\"a b\""
              pane alloc failed:         stderr "COMPILE-FAIL step=N reason=pane-alloc-failed leg=L"
    exit 15 -> retry exhausted:          stderr "COMPILE-FAIL step=N reason=retry-exhausted attempts=K"
    exit 20 -> compile error (compiler side)

All COMPILE-FAIL lines also carry dsl_line=L (the YAML line of the step).

Env contract (product runtime):
    PANE            target pane id (e.g. %0)                 [required]
    TSOCK           tmux -L socket name                       [unless TMUX_SOCK_PATH]
    TMUX_SOCK_PATH  tmux -S socket path (agent_sock driver)   [wins over TSOCK]
"""

import os
import re
import shlex

import yaml

from . import __version__

EXIT_OK = 0
EXIT_COMPILE_ERROR = 20

ACTION_KEYS = ("run", "wait_for", "branch", "parallel", "fail", "retry")
MODIFIER_KEYS = ("timeout_s", "assert_exit")
TOP_KEYS = ("name", "params", "steps")
DEFAULT_TIMEOUT_S = 60

PARAM_RE = re.compile(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}")
PARAM_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


class CompileError(Exception):
    def __init__(self, message, line=None):
        self.message = message
        self.line = line
        super().__init__(message)


def _line(node):
    return node.start_mark.line + 1  # 1-based


def _err(node, msg):
    return CompileError(msg, _line(node))


def _as_str(node, what, declared=None):
    if not isinstance(node, yaml.ScalarNode):
        raise _err(node, "%s must be a string" % what)
    if declared is not None:
        for m in PARAM_RE.finditer(node.value):
            if m.group(1) not in declared:
                raise _err(
                    node,
                    "unknown param '{{%s}}' in %s (not declared in params:)"
                    % (m.group(1), what),
                )
    return node.value


def _as_int(node, what):
    if isinstance(node, yaml.ScalarNode):
        try:
            return int(node.value)
        except (TypeError, ValueError):
            pass
    raise _err(node, "%s must be an integer" % what)


def _as_bool(node, what):
    if isinstance(node, yaml.ScalarNode) and node.value.lower() in (
        "true",
        "false",
    ):
        return node.value.lower() == "true"
    raise _err(node, "%s must be true/false" % what)


def _check_balanced_quotes(cmd, node):
    """Heuristic: reject commands whose quotes are unbalanced.

    With unbalanced quotes the pane shell would swallow the wait-for
    signal line into a continuation prompt. Fail fast at compile time.
    Checked over the whole (possibly multi-line) command.
    """
    sq = dq = bt = False
    esc = False
    for ch in cmd:
        if esc:
            esc = False
            continue
        if ch == "\\" and not sq:
            esc = True
            continue
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif ch == "`" and not sq and not dq:
            bt = not bt
    if sq or dq or bt:
        raise _err(node, "run command has unbalanced quotes")


def _get_timeout(mods):
    if "timeout_s" not in mods:
        return None
    knode, vnode = mods["timeout_s"]
    t = _as_int(vnode, "timeout_s")
    if t <= 0:
        raise _err(vnode, "timeout_s must be > 0")
    return t


# ---------------------------------------------------------------- parsing


def _parse_params(node):
    """params: {name: {required: true} | {default: "x"} | "x"}"""
    if not isinstance(node, yaml.MappingNode):
        raise _err(node, "params must be a mapping")
    declared = {}
    for k, v in node.value:
        pname = k.value
        if not PARAM_NAME_RE.match(pname):
            raise _err(k, "bad param name '%s'" % pname)
        if pname in declared:
            raise _err(k, "duplicate param '%s'" % pname)
        if isinstance(v, yaml.MappingNode):
            required = False
            default = None
            has_default = False
            for sk, sv in v.value:
                sks = sk.value
                if sks == "required":
                    required = _as_bool(sv, "required")
                elif sks == "default":
                    default = _as_str(sv, "param default")
                    has_default = True
                else:
                    raise _err(sk, "unknown param spec key '%s'" % sks)
            if not required and not has_default:
                raise _err(v, "param '%s' must declare required or default" % pname)
            declared[pname] = {"required": required, "default": default}
        elif isinstance(v, yaml.ScalarNode):
            declared[pname] = {"required": False, "default": v.value}
        else:
            raise _err(v, "param '%s' spec must be a mapping or scalar" % pname)
    return declared


def _parse_top(node, path):
    seen = {}
    for k, v in node.value:
        ks = k.value
        if ks not in TOP_KEYS:
            raise _err(
                k, "unknown top-level key '%s' (expected: %s)" % (ks, ", ".join(TOP_KEYS))
            )
        if ks in seen:
            raise _err(k, "duplicate top-level key '%s'" % ks)
        seen[ks] = v
    if "name" not in seen:
        raise _err(node, "missing required key 'name'")
    if "steps" not in seen:
        raise _err(node, "missing required key 'steps'")
    declared = _parse_params(seen["params"]) if "params" in seen else {}
    name = _as_str(seen["name"], "name", declared)
    if not name.strip():
        raise _err(seen["name"], "name must not be empty")
    steps = _parse_steps(seen["steps"], declared, True)
    return name, steps, declared


def _parse_steps(node, declared, allow_parallel, allow_retry=True, allow_empty=False):
    if not isinstance(node, yaml.SequenceNode):
        raise _err(node, "steps must be a list")
    if not node.value and not allow_empty:
        raise _err(node, "steps must not be empty")
    return [_parse_step(sn, declared, allow_parallel, allow_retry) for sn in node.value]


def _parse_step(node, declared, allow_parallel, allow_retry=True):
    line = _line(node)
    if not isinstance(node, yaml.MappingNode):
        raise CompileError("each step must be a mapping", line)
    actions = []
    mods = {}
    for k, v in node.value:
        ks = k.value
        if ks in ACTION_KEYS:
            actions.append((ks, v))
        elif ks in MODIFIER_KEYS:
            if ks in mods:
                raise _err(k, "duplicate key '%s'" % ks)
            mods[ks] = (k, v)
        else:
            raise _err(k, "unknown step key '%s'" % ks)
    if len(actions) != 1:
        raise CompileError(
            "step must have exactly one action %s" % (list(ACTION_KEYS),), line
        )
    kind, vnode = actions[0]
    if kind == "run":
        return _parse_run(vnode, mods, line, declared)
    if kind == "wait_for":
        return _parse_wait(vnode, mods, line, declared)
    if kind == "branch":
        if mods:
            badk = mods[next(iter(mods))][0]
            raise _err(badk, "branch does not accept timeout_s/assert_exit")
        return _parse_branch(vnode, line, declared, allow_retry)
    if kind == "parallel":
        if not allow_parallel:
            raise CompileError("parallel may not be nested inside parallel", line)
        return _parse_parallel(vnode, mods, line, declared)
    if kind == "retry":
        if not allow_retry:
            raise CompileError("retry may not be nested inside retry", line)
        return _parse_retry(vnode, mods, line, declared)
    # fail
    if mods:
        badk = mods[next(iter(mods))][0]
        raise _err(badk, "fail does not accept timeout_s/assert_exit")
    reason = _as_str(vnode, "fail reason", declared)
    if not reason.strip():
        raise _err(vnode, "fail reason must not be empty")
    return {"kind": "fail", "reason": reason, "line": line}


def _parse_run(vnode, mods, line, declared):
    cmd = _as_str(vnode, "run command", declared)
    if not cmd.strip():
        raise _err(vnode, "run command must not be empty")
    lines = [ln for ln in cmd.split("\n") if ln.strip() != ""]
    if not lines:
        raise _err(vnode, "run command has no non-blank lines")
    _check_balanced_quotes(cmd, vnode)
    timeout = _get_timeout(mods)
    if timeout is None:
        timeout = DEFAULT_TIMEOUT_S
    assert_exit = None
    if "assert_exit" in mods:
        _, anode = mods["assert_exit"]
        assert_exit = _as_int(anode, "assert_exit")
    return {
        "kind": "run",
        "cmd": cmd,
        "timeout_s": timeout,
        "assert_exit": assert_exit,
        "line": line,
    }


def _parse_wait(vnode, mods, line, declared):
    pattern = _as_str(vnode, "wait_for pattern", declared)
    if not pattern:
        raise _err(vnode, "wait_for pattern must not be empty")
    timeout = _get_timeout(mods)
    if timeout is None:
        timeout = DEFAULT_TIMEOUT_S
    if "assert_exit" in mods:
        _, anode = mods["assert_exit"]
        raise _err(anode, "wait_for does not accept assert_exit")
    return {"kind": "wait_for", "pattern": pattern, "timeout_s": timeout, "line": line}


def _parse_branch(vnode, line, declared, allow_retry=True):
    if not isinstance(vnode, yaml.MappingNode):
        raise _err(vnode, "branch must be a mapping")
    seen = {}
    for k, v in vnode.value:
        ks = k.value
        if ks not in ("if_output_contains", "then", "else"):
            raise _err(k, "unknown branch key '%s'" % ks)
        if ks in seen:
            raise _err(k, "duplicate branch key '%s'" % ks)
        seen[ks] = v
    if "if_output_contains" not in seen:
        raise _err(vnode, "branch missing 'if_output_contains'")
    if "then" not in seen:
        raise _err(vnode, "branch missing 'then'")
    pattern = _as_str(seen["if_output_contains"], "if_output_contains", declared)
    if not pattern:
        raise _err(seen["if_output_contains"], "if_output_contains must not be empty")
    then_steps = _parse_steps(seen["then"], declared, True, allow_retry, allow_empty=True)
    else_steps = (
        _parse_steps(seen["else"], declared, True, allow_retry, allow_empty=True)
        if "else" in seen
        else []
    )
    return {
        "kind": "branch",
        "pattern": pattern,
        "then": then_steps,
        "else": else_steps,
        "line": line,
    }


def _parse_parallel(vnode, mods, line, declared):
    timeout = _get_timeout(mods)
    if "assert_exit" in mods:
        _, anode = mods["assert_exit"]
        raise _err(anode, "parallel does not accept assert_exit")
    if not isinstance(vnode, yaml.MappingNode):
        raise _err(vnode, "parallel must be a mapping with 'legs'")
    legs_node = None
    for k, v in vnode.value:
        ks = k.value
        if ks == "legs":
            if legs_node is not None:
                raise _err(k, "duplicate parallel key 'legs'")
            legs_node = v
        else:
            raise _err(k, "unknown parallel key '%s' (expected: legs)" % ks)
    if legs_node is None:
        raise _err(vnode, "parallel missing 'legs'")
    if not isinstance(legs_node, yaml.SequenceNode) or not legs_node.value:
        raise _err(legs_node, "legs must be a non-empty list")
    legs = []
    seen_names = set()
    for ln in legs_node.value:
        if not isinstance(ln, yaml.MappingNode):
            raise _err(ln, "each leg must be a mapping")
        name = None
        steps_node = None
        leg_timeout = None
        for k, v in ln.value:
            ks = k.value
            if ks == "name":
                name = _as_str(v, "leg name", declared)
            elif ks == "steps":
                steps_node = v
            elif ks == "timeout_s":
                leg_timeout = _as_int(v, "leg timeout_s")
                if leg_timeout <= 0:
                    raise _err(v, "leg timeout_s must be > 0")
            else:
                raise _err(k, "unknown leg key '%s' (expected: name, steps, timeout_s)" % ks)
        if not name or not name.strip():
            raise _err(ln, "leg missing 'name'")
        if name in seen_names:
            raise _err(ln, "duplicate leg name '%s'" % name)
        seen_names.add(name)
        if steps_node is None:
            raise _err(ln, "leg '%s' missing 'steps'" % name)
        leg_steps = _parse_steps(steps_node, declared, False, True)
        legs.append(
            {
                "name": name,
                "steps": leg_steps,
                "timeout_s": leg_timeout,
                "line": _line(ln),
            }
        )
    return {"kind": "parallel", "legs": legs, "timeout_s": timeout, "line": line}


def _has_run(steps):
    """True if any step (recursively) is a run step."""
    for st in steps:
        kind = st["kind"]
        if kind == "run":
            return True
        if kind == "branch":
            if _has_run(st["then"]) or _has_run(st["else"]):
                return True
        elif kind == "parallel":
            if any(_has_run(leg["steps"]) for leg in st["legs"]):
                return True
        elif kind == "retry":
            if _has_run(st["steps"]):
                return True
    return False


def _parse_retry(vnode, mods, line, declared):
    """retry: bounded repeat-until. Not Turing-complete: no nesting, and an
    inner step failure aborts immediately (only 'condition unmet' retries)."""
    if "assert_exit" in mods:
        _, anode = mods["assert_exit"]
        raise _err(anode, "retry does not accept assert_exit")
    if "timeout_s" in mods:
        _, tnode = mods["timeout_s"]
        raise _err(
            tnode, "retry does not accept timeout_s (attempts bound the runtime)"
        )
    if not isinstance(vnode, yaml.MappingNode):
        raise _err(vnode, "retry must be a mapping")
    attempts = None
    delay_s = 0
    until_output_contains = None
    until_exit_zero = False
    steps_node = None
    seen = set()
    for k, v in vnode.value:
        ks = k.value
        if ks in seen:
            raise _err(k, "duplicate retry key '%s'" % ks)
        seen.add(ks)
        if ks == "attempts":
            attempts = _as_int(v, "attempts")
            if attempts < 1:
                raise _err(v, "attempts must be >= 1")
        elif ks == "delay_s":
            delay_s = _as_int(v, "delay_s")
            if delay_s < 0:
                raise _err(v, "delay_s must be >= 0")
        elif ks == "until_output_contains":
            until_output_contains = _as_str(v, "until_output_contains", declared)
            if not until_output_contains:
                raise _err(v, "until_output_contains must not be empty")
        elif ks == "until_exit_zero":
            until_exit_zero = _as_bool(v, "until_exit_zero")
        elif ks == "steps":
            steps_node = v
        else:
            raise _err(k, "unknown retry key '%s'" % ks)
    if attempts is None:
        raise _err(vnode, "retry missing 'attempts'")
    if steps_node is None:
        raise _err(vnode, "retry missing 'steps'")
    if until_output_contains is None and not until_exit_zero:
        raise _err(
            vnode,
            "retry needs at least one of until_output_contains / until_exit_zero",
        )
    # parallel allowed inside; nested retry forbidden (pointless: an inner
    # exhaustion aborts the outer immediately, it never triggers a re-try).
    inner = _parse_steps(steps_node, declared, True, False)
    if until_exit_zero and not _has_run(inner):
        raise _err(
            vnode, "until_exit_zero needs at least one run step in steps"
        )
    return {
        "kind": "retry",
        "attempts": attempts,
        "delay_s": delay_s,
        "until_output_contains": until_output_contains,
        "until_exit_zero": until_exit_zero,
        "steps": inner,
        "line": line,
    }


# ---------------------------------------------------------------- params


def _resolve_params(declared, provided, dsl_path):
    for k in provided:
        if k not in declared:
            raise CompileError(
                "%s: unknown param '%s' (not declared in params:)" % (dsl_path, k)
            )
    values = {}
    for pname, spec in declared.items():
        if pname in provided:
            v = provided[pname]
            if not isinstance(v, str):
                v = str(v)
            if "\n" in v:
                raise CompileError("param '%s' value must be single-line" % pname)
            values[pname] = v
        elif spec.get("required"):
            raise CompileError(
                "missing required param '%s' (pass --param %s=...)" % (pname, pname)
            )
        else:
            values[pname] = spec.get("default", "")
    return values


def _subst(value, values):
    return PARAM_RE.sub(lambda m: values[m.group(1)], value)


def _subst_steps(steps, values):
    """Substitute params and validate post-substitution content."""
    for st in steps:
        kind = st["kind"]
        if kind == "run":
            st["cmd"] = _subst(st["cmd"], values)
            lines = [ln for ln in st["cmd"].split("\n") if ln.strip() != ""]
            if not lines:
                raise CompileError(
                    "run command became empty after param substitution", st["line"]
                )
        elif kind == "wait_for":
            st["pattern"] = _subst(st["pattern"], values)
            if not st["pattern"]:
                raise CompileError(
                    "wait_for pattern became empty after param substitution", st["line"]
                )
        elif kind == "branch":
            st["pattern"] = _subst(st["pattern"], values)
            if not st["pattern"]:
                raise CompileError(
                    "branch pattern became empty after param substitution", st["line"]
                )
            _subst_steps(st["then"], values)
            _subst_steps(st["else"], values)
        elif kind == "fail":
            st["reason"] = _subst(st["reason"], values)
            if not st["reason"].strip():
                raise CompileError(
                    "fail reason became empty after param substitution", st["line"]
                )
        elif kind == "parallel":
            for leg in st["legs"]:
                _subst_steps(leg["steps"], values)
        elif kind == "retry":
            if st["until_output_contains"] is not None:
                st["until_output_contains"] = _subst(
                    st["until_output_contains"], values
                )
                if not st["until_output_contains"]:
                    raise CompileError(
                        "retry until_output_contains became empty"
                        " after param substitution",
                        st["line"],
                    )
            _subst_steps(st["steps"], values)


def _count_actions(steps):
    n = 0
    for st in steps:
        kind = st["kind"]
        if kind in ("run", "wait_for", "fail"):
            n += 1
        elif kind == "parallel":
            n += 1  # the block counts as one step
        elif kind == "retry":
            # block takes a number (for retry-exhausted); inner steps are
            # numbered inline in the main sequence (branch-style)
            n += 1 + _count_actions(st["steps"])
        elif kind == "branch":
            n += _count_actions(st["then"]) + _count_actions(st["else"])
    return n


# ---------------------------------------------------------------- entry


def compile_dsl(dsl_path, out_path, params=None):
    """Compile dsl_path -> out_path. params: dict of {{name}} values."""
    from .compiler_emit import emit_bash

    with open(dsl_path, "r") as f:
        text = f.read()
    try:
        root = yaml.compose(text)
    except yaml.YAMLError as e:
        raise CompileError("YAML syntax error: %s" % e)
    if root is None:
        raise CompileError("%s: empty document" % dsl_path)
    if not isinstance(root, yaml.MappingNode):
        raise CompileError("top level must be a mapping", _line(root))
    name, steps, declared = _parse_top(root, dsl_path)
    values = _resolve_params(declared, params or {}, dsl_path)
    name = _subst(name, values)
    _subst_steps(steps, values)
    bash = emit_bash(name, steps, dsl_path, _count_actions)
    with open(out_path, "w") as f:
        f.write(bash)
    os.chmod(out_path, 0o755)
    return _count_actions(steps)
