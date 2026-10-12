"""Bash product emission for tmux_compile. (Split out for reviewability.)"""

import shlex

from . import __version__


def _emit_run(st, out, counter, tag, ind):
    counter[0] += 1
    n = counter[0]
    out.append("%s# --- step %d: run (line %d) ---" % (ind, n, st["line"]))
    # Freshness anchor FIRST (while echo is still on): matchers see pane
    # text after this marker. The product expands $TOKEN now; the pane
    # prints the literal anchor text.
    out.append(ind + '_psend "echo \\"TC-BEGIN-$TOKEN\\""')
    # Echo suppression: the pane's command echo is what made branch/wait_for
    # patterns match the command text itself (the marker problem). stty -echo
    # is per-terminal, queued in order, so it takes effect exactly for the
    # lines below and nothing else.
    out.append(ind + '_tmux send-keys -l -t "$PANE" "stty -echo"')
    out.append(ind + '_tmux send-keys -t "$PANE" Enter')
    lines = [ln for ln in st["cmd"].split("\n") if ln.strip() != ""]
    for ln in lines:
        out.append("%s_psend %s" % (ind, shlex.quote(ln)))
    # Signal line: product expands RCFILE/_sig_addr/TOKEN now; the pane's
    # shell expands $? at its runtime. Values are baked in literally so the
    # pane needs no product env vars. Sent while echo is off, so the command
    # text never pollutes the pane.
    out.append(
        ind + '_psend "echo \\$? > \\"$RCFILE\\"; $_sig_addr wait-for -S \\"$TOKEN\\""'
    )
    # NOTE: timeout(1) cannot run a shell function, so _tmux is NOT used here;
    # tmux is invoked directly with the "${_TADDR[@]}" address array.
    out.append(
        ind + 'if ! timeout %d tmux "${_TADDR[@]}" wait-for "$TOKEN"; then'
        % st["timeout_s"]
    )
    out.append(ind + '  _tmux send-keys -t "$PANE" C-c')
    # Best effort: leave the terminal's echo on for whoever uses the pane next.
    out.append(ind + '  _tmux send-keys -l -t "$PANE" "stty echo"')
    out.append(ind + '  _tmux send-keys -t "$PANE" Enter')
    out.append(
        ind + '  echo "COMPILE-FAIL %sstep=%d reason=timeout dsl_line=%d" >&2'
        % (tag, n, st["line"])
    )
    out.append(ind + "  exit 10")
    out.append(ind + "fi")
    # Restore echo (now the pane is back at a prompt) and record the
    # freshness anchor for subsequent branch/wait_for steps.
    out.append(ind + '_tmux send-keys -l -t "$PANE" "stty echo"')
    out.append(ind + '_tmux send-keys -t "$PANE" Enter')
    out.append(ind + '_tc_anchor="TC-BEGIN-$TOKEN"')
    if st["assert_exit"] is not None:
        out.append(ind + '_rc="$(cat "$RCFILE")"')
        out.append(ind + 'if [ "$_rc" != "%d" ]; then' % st["assert_exit"])
        out.append(
            ind + '  echo "COMPILE-FAIL %sstep=%d reason=nonzero-exit rc=$_rc dsl_line=%d" >&2'
            % (tag, n, st["line"])
        )
        out.append(ind + "  exit 12")
        out.append(ind + "fi")


def _emit_wait(st, out, counter, tag, ind):
    counter[0] += 1
    n = counter[0]
    out.append("%s# --- step %d: wait_for (line %d) ---" % (ind, n, st["line"]))
    out.append(ind + "_deadline=$((SECONDS + %d))" % st["timeout_s"])
    out.append(ind + "_found=0")
    out.append(ind + "while [ $SECONDS -lt $_deadline ]; do")
    # _tc_fresh: pane text since the last run step (or whole pane if none).
    out.append(
        ind + "  if _tc_fresh | grep -qE -- %s; then" % shlex.quote(st["pattern"])
    )
    out.append(ind + "    _found=1")
    out.append(ind + "    break")
    out.append(ind + "  fi")
    out.append(ind + "  sleep 0.5")
    out.append(ind + "done")
    out.append(ind + 'if [ "$_found" -ne 1 ]; then')
    out.append(
        ind + '  echo "COMPILE-FAIL %sstep=%d reason=pattern-timeout dsl_line=%d" >&2'
        % (tag, n, st["line"])
    )
    out.append(ind + "  exit 11")
    out.append(ind + "fi")


def _emit_branch(st, out, counter, tag, ind):
    out.append("%s# --- branch (line %d) ---" % (ind, st["line"]))
    out.append(ind + '_branch_out="$(_tc_fresh)"')
    out.append(
        ind + "if printf '%%s' \"$_branch_out\" | grep -qE -- %s; then"
        % shlex.quote(st["pattern"])
    )
    if st["then"]:
        for s in st["then"]:
            _emit_step(s, out, counter, tag, ind + "  ")
    else:
        out.append(ind + "  : # empty then-branch (no-op)")
    if st["else"]:
        out.append(ind + "else")
        for s in st["else"]:
            _emit_step(s, out, counter, tag, ind + "  ")
    out.append(ind + "fi")


def _emit_fail(st, out, counter, tag, ind):
    counter[0] += 1
    n = counter[0]
    out.append("%s# --- step %d: fail (line %d) ---" % (ind, n, st["line"]))
    # reason is compiler-controlled text; quote defensively anyway
    safe_reason = st["reason"].replace('"', "'")
    out.append(
        ind + 'echo "COMPILE-FAIL %sstep=%d reason=%s dsl_line=%d" >&2'
        % (tag, n, safe_reason, st["line"])
    )
    out.append(ind + "exit 13")


def _emit_parallel(st, out, counter, tag, ind):
    # tag is always "" here: parallel is top-level only (nesting rejected).
    counter[0] += 1
    n = counter[0]
    legs = st["legs"]
    nl = len(legs)
    out.append(
        "%s# --- step %d: parallel (%d legs, line %d) ---" % (ind, n, nl, st["line"])
    )
    # 1. allocate one pane per leg, tiled for visibility
    out.append(
        ind + '_pwin="$(_tmux display-message -p -t "$PANE" \'#{window_id}\' 2>/dev/null)"'
    )
    for i, leg in enumerate(legs):
        out.append(
            ind + '_pleg%d="$(_tmux split-window -h -t "$PANE" -P -F \'#{pane_id}\' 2>/dev/null)"' % i
        )
        out.append(ind + 'if [ -z "$_pleg%d" ]; then' % i)
        out.append(
            ind + '  echo "COMPILE-FAIL step=%d reason=pane-alloc-failed leg=%s dsl_line=%d" >&2'
            % (n, leg["name"], st["line"])
        )
        out.append(ind + "  exit 14")
        out.append(ind + "fi")
    out.append(
        ind + '[ -n "$_pwin" ] && _tmux select-layout -t "$_pwin" tiled 2>/dev/null; true'
    )
    # 2. per-leg log dir (master EXIT trap cleans it up)
    out.append(ind + '_leglog="$(mktemp -d /tmp/tmux-compile-legs-XXXXXX)"')
    # 3. leg bodies as subshell functions: `exit N` inside == return N.
    #    An EXIT trap records the rc into $_leglog/<i>.rc (file-based, so the
    #    watchdog never has to deal with zombie/pid races).
    for i, leg in enumerate(legs):
        out.append(ind + "_leg_%d() (" % i)
        out.append(ind + '  PANE="$_pleg%d"' % i)
        out.append(ind + '  TOKEN="ctok-${_rid}-leg%d"' % i)
        out.append(ind + '  RCFILE="$(mktemp /tmp/tmux-compile-rc-XXXXXX)"')
        # At definition time the main shell expands $_leglog and %d; the
        # subshell expands $? and $RCFILE when the trap fires.
        out.append(
            ind + '  trap "echo \\$? > \\"$_leglog/%d.rc\\"; rm -f \\"\\$RCFILE\\"" EXIT' % i
        )
        lc = [0]
        ltag = "leg=%s " % leg["name"]
        for s in leg["steps"]:
            _emit_step(s, out, lc, ltag, ind + "  ")
        out.append(ind + "  exit 0")
        out.append(ind + ")")
    # 4. launch legs in background, logs per leg
    out.append(ind + "_legpid=(); _legname=(); _legpane=(); _legdeadline=()")
    for i, leg in enumerate(legs):
        out.append(
            ind + '_leg_%d >"$_leglog/%d.log" 2>&1 & _legpid+=( $! )' % (i, i)
        )
        out.append(ind + "_legname+=( %s )" % shlex.quote(leg["name"]))
        out.append(ind + '_legpane+=( "$_pleg%d" )' % i)
        if leg["timeout_s"] is not None:
            out.append(ind + "_legdeadline+=( $((SECONDS + %d)) )" % leg["timeout_s"])
        else:
            out.append(ind + '_legdeadline+=( "" )')
    if st["timeout_s"] is not None:
        out.append(ind + "_pblock_deadline=$((SECONDS + %d))" % st["timeout_s"])
    else:
        out.append(ind + '_pblock_deadline=""')
    # 5. watchdog: poll rc files; enforce per-leg and block deadlines
    out.append(ind + '_premaining="%s"' % " ".join(str(i) for i in range(nl)))
    out.append(ind + '_pfail_idx=""; _pfail=""')
    out.append(ind + 'while [ -n "$_premaining" ]; do')
    out.append(ind + '  _pnext=""')
    out.append(ind + "  for _i in $_premaining; do")
    out.append(ind + '    if [ -f "$_leglog/$_i.rc" ]; then')
    out.append(ind + '      _rc="$(cat "$_leglog/$_i.rc")"')
    out.append(ind + '      case "$_rc" in ""|*[!0-9]*) _rc=999;; esac')
    out.append(ind + '      if [ "$_rc" -ne 0 ]; then')
    out.append(
        ind + '        _pfail_idx="$_pfail_idx $_i"; _pfail="$_pfail ${_legname[$_i]}:rc=$_rc"'
    )
    out.append(ind + "      fi")
    out.append(ind + "    else")
    out.append(ind + '      _dl="${_legdeadline[$_i]}"; _hit=0')
    out.append(
        ind + '      { [ -n "$_dl" ] && [ "$SECONDS" -ge "$_dl" ]; } 2>/dev/null && _hit=1; true'
    )
    out.append(
        ind + '      { [ -n "$_pblock_deadline" ] && [ "$SECONDS" -ge "$_pblock_deadline" ]; } 2>/dev/null && _hit=1; true'
    )
    out.append(ind + '      if [ "$_hit" = 1 ]; then')
    out.append(
        ind + '        _tmux send-keys -t "${_legpane[$_i]}" C-c 2>/dev/null; true'
    )
    out.append(ind + '        kill "${_legpid[$_i]}" 2>/dev/null; true')
    out.append(ind + '        wait "${_legpid[$_i]}" 2>/dev/null; true')
    out.append(ind + '        [ -f "$_leglog/$_i.rc" ] || echo 124 > "$_leglog/$_i.rc"')
    out.append(
        ind + '        _pfail_idx="$_pfail_idx $_i"; _pfail="$_pfail ${_legname[$_i]}:timeout"'
    )
    out.append(ind + "      else")
    out.append(ind + '        _pnext="$_pnext $_i"')
    out.append(ind + "      fi")
    out.append(ind + "    fi")
    out.append(ind + "  done")
    out.append(ind + '  _premaining="$_pnext"')
    out.append(ind + "  [ -n \"$_premaining\" ] && sleep 1; true")
    out.append(ind + "done")
    # 6. join: print failed legs' tails, kill leg panes, report
    out.append(ind + 'if [ -n "$_pfail_idx" ]; then')
    out.append(ind + "  for _i in $_pfail_idx; do")
    out.append(ind + '    echo "--- leg log tail (${_legname[$_i]}) ---" >&2')
    out.append(ind + '    tail -30 "$_leglog/$_i.log" >&2 2>/dev/null; true')
    out.append(ind + "  done")
    out.append(ind + "fi")
    out.append(
        ind + 'for _p in "${_legpane[@]}"; do _tmux kill-pane -t "$_p" 2>/dev/null; true; done'
    )
    out.append(ind + 'rm -rf "$_leglog"; _leglog=""')
    out.append(ind + 'if [ -n "$_pfail_idx" ]; then')
    out.append(ind + '  _pfail="${_pfail# }"')
    out.append(
        ind + '  echo "COMPILE-FAIL step=%d reason=parallel-leg-failed legs=\\"$_pfail\\" dsl_line=%d" >&2'
        % (n, st["line"])
    )
    out.append(ind + "  exit 14")
    out.append(ind + "fi")


def _emit_retry(st, out, counter, tag, ind):
    # Bounded repeat-until. Inner step failure aborts immediately (a failing
    # step exits the whole product); only "condition unmet" loops.
    counter[0] += 1
    n = counter[0]
    out.append(
        "%s# --- step %d: retry up to %d (line %d) ---"
        % (ind, n, st["attempts"], st["line"])
    )
    out.append(ind + "_retry_ok=0")
    out.append(ind + "_retry_met=0")
    out.append(ind + "for _attempt in $(seq 1 %d); do" % st["attempts"])
    if st["delay_s"]:
        out.append(ind + '  [ "$_attempt" -gt 1 ] && sleep %d' % st["delay_s"])
    for s in st["steps"]:
        _emit_step(s, out, counter, tag, ind + "  ")
    # Reached only if the steps did not fail. Check stop conditions against
    # the fresh pane region (same semantics as branch).
    out.append(ind + "  _retry_met=1")
    if st["until_output_contains"] is not None:
        out.append(
            ind + "  _tc_fresh | grep -qE -- %s || _retry_met=0"
            % shlex.quote(st["until_output_contains"])
        )
    if st["until_exit_zero"]:
        # RCFILE holds the most recent run step's exit code (compile-time
        # checked: at least one run step exists when this is set).
        out.append(
            ind + '  _rrc="$(cat "$RCFILE" 2>/dev/null)";'
            ' [ "$_rrc" = "0" ] || _retry_met=0'
        )
    out.append(ind + '  if [ "$_retry_met" = 1 ]; then _retry_ok=1; break; fi')
    out.append(ind + "done")
    out.append(ind + 'if [ "$_retry_ok" != 1 ]; then')
    out.append(
        ind + '  echo "COMPILE-FAIL %sstep=%d reason=retry-exhausted'
        ' attempts=%d dsl_line=%d" >&2' % (tag, n, st["attempts"], st["line"])
    )
    out.append(ind + "  exit 15")
    out.append(ind + "fi")


def _emit_step(st, out, counter, tag="", ind=""):
    kind = st["kind"]
    if kind == "run":
        _emit_run(st, out, counter, tag, ind)
    elif kind == "wait_for":
        _emit_wait(st, out, counter, tag, ind)
    elif kind == "branch":
        _emit_branch(st, out, counter, tag, ind)
    elif kind == "parallel":
        _emit_parallel(st, out, counter, tag, ind)
    elif kind == "retry":
        _emit_retry(st, out, counter, tag, ind)
    elif kind == "fail":
        _emit_fail(st, out, counter, tag, ind)
    else:  # pragma: no cover - parser guarantees kind
        raise AssertionError("unknown step kind %r" % kind)


def emit_bash(name, steps, source, count_actions):
    total = count_actions(steps)
    # Header lines are comments; a newline in name/source would break out of
    # the comment and inject executable lines into the product.
    safe_name = name.replace("\n", " ").replace("\r", " ")
    safe_source = source.replace("\n", " ").replace("\r", " ")
    out = []
    out.append("#!/usr/bin/env bash")
    out.append("# Generated by tmux_compile v%s from: %s" % (__version__, safe_source))
    out.append("# Flow: %s" % safe_name)
    out.append("# DO NOT EDIT.")
    out.append("#")
    out.append("# NOTE: this product is 'compiled once, instantiated per run'.")
    out.append("# tmux wait-for signals latch (never clear), so TOKEN is generated")
    out.append("# at RUNTIME below, not baked in at compile time.")
    out.append("set -u")
    out.append("")
    out.append("# --- tmux address: -S path mode (agent_sock driver) wins over -L name ---")
    out.append('if [ -n "${TMUX_SOCK_PATH:-}" ]; then')
    out.append('  _TADDR=(-S "$TMUX_SOCK_PATH")')
    # _sig_addr is baked literally: the pane's shell cannot call _tmux.
    out.append('  _sig_addr="tmux -S \\"$TMUX_SOCK_PATH\\""')
    out.append("else")
    out.append(
        '  if [ -z "${TSOCK:-}" ]; then echo "COMPILE-FAIL reason=missing-env:TSOCK" >&2; exit 20; fi'
    )
    out.append(
        '  case "$TSOCK" in *[!A-Za-z0-9._-]*) echo "COMPILE-FAIL reason=bad-tsock" >&2; exit 20;; esac'
    )
    out.append('  _TADDR=(-L "$TSOCK")')
    out.append('  _sig_addr="tmux -L \\"$TSOCK\\""')
    out.append("fi")
    out.append("_tmux() { tmux \"${_TADDR[@]}\" \"$@\"; }")
    out.append(
        'if [ -z "${PANE:-}" ]; then echo "COMPILE-FAIL reason=missing-env:PANE" >&2; exit 20; fi'
    )
    out.append("")
    out.append("# --- runtime token (latch-safe) ---")
    out.append('if command -v uuidgen >/dev/null 2>&1; then _rid="$(uuidgen)"')
    out.append(
        'elif [ -r /proc/sys/kernel/random/uuid ]; then'
        ' _rid="$(cat /proc/sys/kernel/random/uuid)"'
    )
    out.append('else _rid="$$-$SECONDS-$RANDOM"; fi')
    out.append('TOKEN="ctok-${_rid}"')
    out.append('RCFILE="$(mktemp /tmp/tmux-compile-rc-XXXXXX)"')
    out.append('_leglog=""')
    out.append(
        'trap \'rm -f "$RCFILE"; [ -n "$_leglog" ] && rm -rf "$_leglog"\' EXIT'
    )
    out.append("")
    out.append("# send one literal line to the pane, then Enter")
    out.append("_psend() {")
    out.append('  _tmux send-keys -l -t "$PANE" "$1"')
    out.append('  _tmux send-keys -t "$PANE" Enter')
    out.append("}")
    out.append("")
    out.append("# Freshness: matchers (branch/wait_for/retry) see pane text after the")
    out.append("# most recent run step's TC-BEGIN marker, not the whole scrollback.")
    out.append("# _tc_anchor is empty until the first run completes -> whole pane.")
    out.append("# If the anchor scrolled out of history, fail closed (match nothing).")
    out.append("# The TC-BEGIN prefix is reserved; do not print it from your commands.")
    out.append('_tc_anchor=""')
    out.append("_tc_fresh() {")
    out.append('  _cap="$(_tmux capture-pane -p -S - -t "$PANE" 2>/dev/null)"')
    out.append('  if [ -n "$_tc_anchor" ]; then')
    out.append(
        '    _ln="$(printf \'%s\' "$_cap" | grep -nF -- "$_tc_anchor"'
        ' | tail -1 | cut -d: -f1)"'
    )
    out.append('    if [ -n "$_ln" ]; then')
    out.append('      printf \'%s\' "$_cap" | tail -n "+$((_ln + 1))"')
    out.append("    fi")
    out.append("  else")
    out.append('    printf \'%s\' "$_cap"')
    out.append("  fi")
    out.append("}")
    out.append("")
    counter = [0]
    for st in steps:
        _emit_step(st, out, counter)
    out.append("")
    out.append('echo "COMPILE-OK steps=%d"' % total)
    out.append("")
    return "\n".join(out)
