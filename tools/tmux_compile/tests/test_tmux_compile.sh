#!/usr/bin/env bash
# tests/test_tmux_compile.sh -- A1-A10 acceptance tests for tmux_compile.
# All automated. Each case: isolated tmux server (-L), fixed pane size,
# compile YAML -> run product -> assert. No manual steps.
#
# Product contract:
#   exit 0  stdout ends with "COMPILE-OK steps=N"
#   exit 10 stderr "COMPILE-FAIL step=N reason=timeout"
#   exit 11 stderr "COMPILE-FAIL step=N reason=pattern-timeout"
#   exit 12 stderr "COMPILE-FAIL step=N reason=nonzero-exit"
#   exit 13 stderr "COMPILE-FAIL step=N reason=..."
#   exit 20 compiler error

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

PASS=0
FAIL=0

_tpass() { echo "PASS $1"; PASS=$((PASS + 1)); }
_tfail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }

# _new_tmux <suffix> : start isolated server, set TSOCK and PANE
_new_tmux() {
  TSOCK="tmc-$1-$$"
  tmux -L "$TSOCK" kill-server 2>/dev/null
  tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
  PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')
  sleep 1 # let the shell start
}

_end_tmux() {
  tmux -L "$TSOCK" kill-server 2>/dev/null
}

# _compile <yaml> <out> [extra args...] : run compiler, return its exit code
_compile() {
  python3 -m tmux_compile "$1" -o "$2" "${@:3}"
}

# ---------------------------------------------------------------- A1: deterministic sequence
t_a1() {
  local id="a1"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a1
steps:
  - run: echo step1
  - run: echo step2
  - run: echo step3
EOF
  if ! _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>"$work/cerr.txt"; then
    _tfail "A1" "compile failed: $(cat "$work/cerr.txt")"; _end_tmux; rm -rf "$work"; return
  fi
  local out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  [ "$rc" -eq 0 ] || { _tfail "A1" "exit=$rc err=$(cat "$work/err.txt")"; _end_tmux; rm -rf "$work"; return; }
  [ "$(echo "$out" | tail -1)" = "COMPILE-OK steps=3" ] || { _tfail "A1" "bad OK line: $out"; _end_tmux; rm -rf "$work"; return; }
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  local l1 l2 l3
  l1=$(echo "$po" | grep -n "step1" | head -1 | cut -d: -f1)
  l2=$(echo "$po" | grep -n "step2" | head -1 | cut -d: -f1)
  l3=$(echo "$po" | grep -n "step3" | head -1 | cut -d: -f1)
  if [ -n "$l1" ] && [ -n "$l2" ] && [ -n "$l3" ] && [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ]; then
    _tpass "A1"
  else
    _tfail "A1" "output order wrong"
  fi
  # negative: unknown key must fail at compile time with line number
  cat > "$work/bad.yaml" <<'EOF'
name: bad
steps:
  - runn: echo hi
EOF
  if _compile "$work/bad.yaml" "$work/bad.sh" 2>"$work/baderr.txt"; then
    _tfail "A1-neg" "unknown key accepted"
  else
    local brc=$?
    if [ "$brc" -ne 20 ]; then
      _tfail "A1-neg" "wrong exit $brc"
    elif ! grep -q "runn" "$work/baderr.txt"; then
      _tfail "A1-neg" "key name missing in error"
    elif ! grep -qE ":[0-9]+:" "$work/baderr.txt"; then
      _tfail "A1-neg" "line number missing in error"
    else
      _tpass "A1-neg"
    fi
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A2: shell escaping
t_a2() {
  local id="a2"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a2
steps:
  - run: echo "a;b" '$HOME' '$(id)'
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A2" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  [ "$rc" -eq 0 ] || { _tfail "A2" "exit=$rc"; _end_tmux; rm -rf "$work"; return; }
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if echo "$po" | grep -qF 'a;b $HOME $(id)'; then
    _tpass "A2"
  else
    _tfail "A2" "literal text not preserved"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A3: token uniqueness (latch)
t_a3() {
  local id="a3"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a3
steps:
  - run: sleep 2; echo done
    timeout_s: 15
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A3" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local s1 e1 s2 e2 rc1 rc2
  s1=$SECONDS
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>&1; rc1=$?
  e1=$((SECONDS - s1))
  s2=$SECONDS
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>&1; rc2=$?
  e2=$((SECONDS - s2))
  # If the token were hard-coded (latch bug), the 2nd run would return instantly.
  if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$e1" -ge 2 ] && [ "$e2" -ge 2 ]; then
    _tpass "A3"
  else
    _tfail "A3" "rc1=$rc1 t1=${e1}s rc2=$rc2 t2=${e2}s (2nd run must really wait)"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A4: loop wait
t_a4() {
  local id="a4"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  # background job prints READY after 3s
  ( sleep 3; tmux -L "$TSOCK" send-keys -l -t "$PANE" 'echo READY'; tmux -L "$TSOCK" send-keys -t "$PANE" Enter ) &
  cat > "$work/dsl.yaml" <<'EOF'
name: a4
steps:
  - wait_for: READY
    timeout_s: 10
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A4" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local s=$SECONDS out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  local el=$((SECONDS - s))
  wait 2>/dev/null
  if [ "$rc" -eq 0 ] && [ "$el" -ge 3 ] && [ "$el" -lt 10 ]; then
    _tpass "A4"
  else
    _tfail "A4" "rc=$rc elapsed=${el}s"
  fi
  # negative: misspelled pattern -> pattern-timeout
  cat > "$work/bad.yaml" <<'EOF'
name: a4neg
steps:
  - wait_for: READI
    timeout_s: 3
EOF
  _compile "$work/bad.yaml" "$work/bad.sh" >/dev/null 2>&1
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/bad.sh" 2>"$work/baderr.txt"); rc=$?
  if [ "$rc" -eq 11 ] && grep -q "COMPILE-FAIL step=1 reason=pattern-timeout" "$work/baderr.txt"; then
    _tpass "A4-neg"
  else
    _tfail "A4-neg" "rc=$rc"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A5/A6: branch taken / not taken
t_a5_a6() {
  local id="a56"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a5
steps:
  - run: echo ALREADY_APPLIED
  - branch:
      if_output_contains: ALREADY_APPLIED
      then:
        - run: echo took-then
      else:
        - run: echo SHOULD_NOT_RUN
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A5" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>&1
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if echo "$po" | grep -q "took-then" && ! echo "$po" | grep -q "SHOULD_NOT_RUN"; then
    _tpass "A5"
  else
    _tfail "A5" "then-branch not taken correctly"
  fi
  # A6: pattern absent -> else branch
  tmux -L "$TSOCK" send-keys -l -t "$PANE" 'clear'; tmux -L "$TSOCK" send-keys -t "$PANE" Enter; sleep 0.5
  cat > "$work/dsl6.yaml" <<'EOF'
name: a6
steps:
  - run: echo FRESH
  - branch:
      if_output_contains: ALREADY_APPLIED
      then:
        - run: echo SHOULD_NOT_RUN
      else:
        - run: echo took-else
EOF
  _compile "$work/dsl6.yaml" "$work/product6.sh" >/dev/null 2>&1 || { _tfail "A6" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product6.sh" >/dev/null 2>&1
  po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if echo "$po" | grep -q "took-else" && ! echo "$po" | grep -q "SHOULD_NOT_RUN"; then
    _tpass "A6"
  else
    _tfail "A6" "else-branch not taken correctly"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A7: shell injection
t_a7() {
  local id="a7"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  local marker="/tmp/pwned-accept-$$"
  rm -f "$marker"
  cat > "$work/dsl.yaml" <<EOF
name: a7
steps:
  - run: '"; touch $marker; echo "'
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A7" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>&1
  if [ -e "$marker" ]; then
    _tfail "A7" "injection succeeded: $marker created"
  else
    _tpass "A7"
  fi
  rm -f "$marker"
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A8: concurrent products, no token crosstalk
t_a8() {
  local id="a8"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  # second pane (horizontal split of the 200x50 window)
  tmux -L "$TSOCK" split-window -h -t "$PANE"
  sleep 0.5
  local pane_a pane_b
  pane_a=$(tmux -L "$TSOCK" list-panes -F '#{pane_id}' | head -1)
  pane_b=$(tmux -L "$TSOCK" list-panes -F '#{pane_id}' | tail -1)
  cat > "$work/dsl.yaml" <<'EOF'
name: a8
steps:
  - run: sleep 2; echo done
    timeout_s: 15
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A8" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local s=$SECONDS
  TSOCK="$TSOCK" PANE="$pane_a" bash "$work/product.sh" >"$work/o1.txt" 2>&1 & local p1=$!
  TSOCK="$TSOCK" PANE="$pane_b" bash "$work/product.sh" >"$work/o2.txt" 2>&1 & local p2=$!
  wait $p1; local rc1=$?
  wait $p2; local rc2=$?
  local el=$((SECONDS - s))
  local po_a po_b
  po_a=$(tmux -L "$TSOCK" capture-pane -p -t "$pane_a")
  po_b=$(tmux -L "$TSOCK" capture-pane -p -t "$pane_b")
  # If tokens collided, one waiter would be released by the other's signal
  # and finish in <2s. Both must take >=2s and both panes must show done.
  if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$el" -ge 2 ] \
     && echo "$po_a" | grep -q "done" && echo "$po_b" | grep -q "done"; then
    _tpass "A8"
  else
    _tfail "A8" "rc1=$rc1 rc2=$rc2 elapsed=${el}s"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A9: single-step timeout
t_a9() {
  local id="a9"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a9
steps:
  - run: sleep 60
    timeout_s: 3
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A9" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local s=$SECONDS out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  local el=$((SECONDS - s))
  if [ "$rc" -eq 10 ] && grep -q "COMPILE-FAIL step=1 reason=timeout" "$work/err.txt" && [ "$el" -lt 10 ]; then
    _tpass "A9"
  else
    _tfail "A9" "rc=$rc elapsed=${el}s err=$(cat "$work/err.txt")"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A10: pattern timeout
t_a10() {
  local id="a10"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a10
steps:
  - wait_for: NEVER_APPEARS_EVER
    timeout_s: 3
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A10" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local s=$SECONDS out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  local el=$((SECONDS - s))
  if [ "$rc" -eq 11 ] && grep -q "COMPILE-FAIL step=1 reason=pattern-timeout" "$work/err.txt" && [ "$el" -lt 10 ]; then
    _tpass "A10"
  else
    _tfail "A10" "rc=$rc elapsed=${el}s"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A11: params substitution
t_a11() {
  local id="a11"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a11-{{who}}
params:
  who: {default: "world"}
  must: {required: true}
steps:
  - run: echo "hello {{who}} {{must}}"
EOF
  if ! _compile "$work/dsl.yaml" "$work/product.sh" --param must=yes >/dev/null 2>"$work/cerr.txt"; then
    _tfail "A11" "compile failed: $(cat "$work/cerr.txt")"; _end_tmux; rm -rf "$work"; return
  fi
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>&1
  local rc=$?
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if [ "$rc" -eq 0 ] && echo "$po" | grep -q "hello world yes"; then
    _tpass "A11"
  else
    _tfail "A11" "rc=$rc"
  fi
  # negative: missing required param
  if _compile "$work/dsl.yaml" "$work/bad.sh" 2>"$work/berr.txt"; then
    _tfail "A11-neg" "missing required param accepted"
  elif grep -q "missing required param 'must'" "$work/berr.txt"; then
    _tpass "A11-neg"
  else
    _tfail "A11-neg" "wrong error: $(cat "$work/berr.txt")"
  fi
  # negative: unknown param ref
  cat > "$work/bad2.yaml" <<'EOF'
name: bad2
steps:
  - run: echo "{{nope}}"
EOF
  if _compile "$work/bad2.yaml" "$work/bad2.sh" 2>"$work/b2err.txt"; then
    _tfail "A11-neg2" "unknown param ref accepted"
  elif grep -q "unknown param '{{nope}}'" "$work/b2err.txt"; then
    _tpass "A11-neg2"
  else
    _tfail "A11-neg2" "wrong error: $(cat "$work/b2err.txt")"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A12: multi-line run
t_a12() {
  local id="a12"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a12
steps:
  - run: |
      echo line-one
      for i in 1 2; do
        echo "iter-$i"
      done
      echo line-last
    assert_exit: 0
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A12" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>"$work/err.txt"
  local rc=$?
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if [ "$rc" -eq 0 ] && echo "$po" | grep -q "line-one" \
     && echo "$po" | grep -q "iter-1" && echo "$po" | grep -q "iter-2" \
     && echo "$po" | grep -q "line-last"; then
    _tpass "A12"
  else
    _tfail "A12" "rc=$rc err=$(cat "$work/err.txt")"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A13: parallel success + failure
t_a13() {
  local id="a13"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a13
steps:
  - parallel:
      legs:
        - name: legA
          steps:
            - run: echo A-done
        - name: legB
          steps:
            - run: echo B-done
    timeout_s: 60
  - run: echo after-parallel
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A13" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(echo "$out" | tail -1)" = "COMPILE-OK steps=2" ]; then
    _tpass "A13"
  else
    _tfail "A13" "rc=$rc out=$out err=$(cat "$work/err.txt")"
  fi
  # negative: one leg fails -> exit 14, names the leg
  cat > "$work/fail.yaml" <<'EOF'
name: a13f
steps:
  - parallel:
      legs:
        - name: goodleg
          steps:
            - run: echo fine
        - name: badleg
          steps:
            - wait_for: NEVER_APPEARS_XYZ
              timeout_s: 3
EOF
  _compile "$work/fail.yaml" "$work/fail.sh" >/dev/null 2>&1 || { _tfail "A13-neg" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/fail.sh" 2>"$work/failerr.txt"); rc=$?
  if [ "$rc" -eq 14 ] && grep -q 'reason=parallel-leg-failed' "$work/failerr.txt" \
     && grep -q 'badleg' "$work/failerr.txt"; then
    _tpass "A13-neg"
  else
    _tfail "A13-neg" "rc=$rc err=$(cat "$work/failerr.txt")"
  fi
  # negative: nested parallel rejected at compile time
  cat > "$work/nest.yaml" <<'EOF'
name: nest
steps:
  - parallel:
      legs:
        - name: outer
          steps:
            - parallel:
                legs:
                  - name: inner
                    steps:
                      - run: echo hi
EOF
  if _compile "$work/nest.yaml" "$work/nest.sh" 2>"$work/nesterr.txt"; then
    _tfail "A13-neg2" "nested parallel accepted"
  elif grep -q "may not be nested" "$work/nesterr.txt"; then
    _tpass "A13-neg2"
  else
    _tfail "A13-neg2" "wrong error: $(cat "$work/nesterr.txt")"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A14: compile errors
t_a14() {
  local id="a14"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  # empty steps
  printf 'name: e1\nsteps: []\n' > "$work/e1.yaml"
  if _compile "$work/e1.yaml" "$work/e1.sh" 2>"$work/e1e.txt"; then
    _tfail "A14-empty" "empty steps accepted"
  elif grep -q "must not be empty" "$work/e1e.txt"; then _tpass "A14-empty"; else _tfail "A14-empty" "$(cat "$work/e1e.txt")"; fi
  # retry without stop condition
  cat > "$work/e2.yaml" <<'EOF'
name: e2
steps:
  - retry:
      attempts: 2
      steps:
        - run: echo hi
EOF
  if _compile "$work/e2.yaml" "$work/e2.sh" 2>"$work/e2e.txt"; then
    _tfail "A14-nocond" "retry without condition accepted"
  elif grep -q "at least one of until_output_contains" "$work/e2e.txt"; then _tpass "A14-nocond"; else _tfail "A14-nocond" "$(cat "$work/e2e.txt")"; fi
  # retry attempts: 0
  cat > "$work/e3.yaml" <<'EOF'
name: e3
steps:
  - retry:
      attempts: 0
      until_output_contains: X
      steps:
        - run: echo hi
EOF
  if _compile "$work/e3.yaml" "$work/e3.sh" 2>"$work/e3e.txt"; then
    _tfail "A14-attempts" "attempts: 0 accepted"
  elif grep -q "attempts must be >= 1" "$work/e3e.txt"; then _tpass "A14-attempts"; else _tfail "A14-attempts" "$(cat "$work/e3e.txt")"; fi
  # nested retry rejected
  cat > "$work/e4.yaml" <<'EOF'
name: e4
steps:
  - retry:
      attempts: 2
      until_output_contains: X
      steps:
        - retry:
            attempts: 2
            until_output_contains: Y
            steps:
              - run: echo hi
EOF
  if _compile "$work/e4.yaml" "$work/e4.sh" 2>"$work/e4e.txt"; then
    _tfail "A14-nest" "nested retry accepted"
  elif grep -q "may not be nested" "$work/e4e.txt"; then _tpass "A14-nest"; else _tfail "A14-nest" "$(cat "$work/e4e.txt")"; fi
  # until_exit_zero without any run step
  cat > "$work/e5.yaml" <<'EOF'
name: e5
steps:
  - retry:
      attempts: 2
      until_exit_zero: true
      steps:
        - wait_for: X
          timeout_s: 1
EOF
  if _compile "$work/e5.yaml" "$work/e5.sh" 2>"$work/e5e.txt"; then
    _tfail "A14-noexit" "until_exit_zero without run accepted"
  elif grep -q "needs at least one run step" "$work/e5e.txt"; then _tpass "A14-noexit"; else _tfail "A14-noexit" "$(cat "$work/e5e.txt")"; fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A15: missing env
t_a15() {
  local id="a15"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  printf 'name: e\nsteps:\n  - run: echo hi\n' > "$work/dsl.yaml"
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1
  local out rc
  out=$(TSOCK="$TSOCK" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  if [ "$rc" -eq 20 ] && grep -q "missing-env:PANE" "$work/err.txt"; then
    _tpass "A15"
  else
    _tfail "A15" "rc=$rc err=$(cat "$work/err.txt")"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A16: 3-way concurrency
t_a16() {
  local id="a16"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  tmux -L "$TSOCK" split-window -h -t "$PANE"; sleep 0.3
  tmux -L "$TSOCK" split-window -h -t "$PANE"; sleep 0.5
  local panes; panes=$(tmux -L "$TSOCK" list-panes -F '#{pane_id}')
  [ "$(echo "$panes" | wc -l)" -eq 3 ] || { _tfail "A16" "need 3 panes"; _end_tmux; rm -rf "$work"; return; }
  cat > "$work/dsl.yaml" <<'EOF'
name: a16
steps:
  - run: sleep 2; echo done16
    timeout_s: 15
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1
  local s=$SECONDS i=0
  for p in $panes; do
    i=$((i+1))
    TSOCK="$TSOCK" PANE="$p" bash "$work/product.sh" >"$work/o$i.txt" 2>&1 &
  done
  wait
  local el=$((SECONDS - s)) ok=1
  for j in 1 2 3; do grep -q "COMPILE-OK" "$work/o$j.txt" || ok=0; done
  # tokens must not collide: all three really waited >=2s (parallel => ~2s total)
  if [ "$ok" -eq 1 ] && [ "$el" -ge 2 ] && [ "$el" -lt 12 ]; then
    _tpass "A16"
  else
    _tfail "A16" "elapsed=${el}s"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A17: retry primitive
t_a17() {
  local id="a17"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  # success on 2nd attempt
  rm -f "$work/count"
  cat > "$work/dsl.yaml" <<EOF
name: a17
steps:
  - retry:
      attempts: 3
      until_output_contains: "WENT_OK"
      steps:
        - run: |
            c=\$(cat $work/count 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > $work/count
            if [ "\$c" -ge 2 ]; then echo WENT_OK; else echo NOT_YET; fi
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A17" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(echo "$out" | tail -1)" = "COMPILE-OK steps=2" ] && [ "$(cat "$work/count")" = "2" ]; then
    _tpass "A17-ok2nd"
  else
    _tfail "A17-ok2nd" "rc=$rc out=$out count=$(cat "$work/count" 2>/dev/null)"
  fi
  # exhaustion -> exit 15 with attempts and dsl_line
  cat > "$work/ex.yaml" <<'EOF'
name: a17ex
steps:
  - run: echo before
  - retry:
      attempts: 2
      delay_s: 1
      until_output_contains: "NEVER_COMES"
      steps:
        - run: echo trying
EOF
  _compile "$work/ex.yaml" "$work/ex.sh" >/dev/null 2>&1
  local s=$SECONDS
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/ex.sh" 2>"$work/exerr.txt"); rc=$?
  local el=$((SECONDS - s))
  if [ "$rc" -eq 15 ] && grep -q 'reason=retry-exhausted' "$work/exerr.txt" \
     && grep -q 'attempts=2' "$work/exerr.txt" && grep -q 'dsl_line=' "$work/exerr.txt" \
     && [ "$el" -ge 1 ]; then
    _tpass "A17-exhaust"
  else
    _tfail "A17-exhaust" "rc=$rc elapsed=${el}s err=$(cat "$work/exerr.txt")"
  fi
  # until_exit_zero with flaky command
  rm -f "$work/fc"
  cat > "$work/fz.yaml" <<EOF
name: a17fz
steps:
  - retry:
      attempts: 3
      until_exit_zero: true
      steps:
        - run: |
            c=\$(cat $work/fc 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > $work/fc
            [ "\$c" -ge 2 ]
EOF
  _compile "$work/fz.yaml" "$work/fz.sh" >/dev/null 2>&1
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/fz.sh" 2>"$work/fzerr.txt"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$work/fc")" = "2" ]; then
    _tpass "A17-exitzero"
  else
    _tfail "A17-exitzero" "rc=$rc err=$(cat "$work/fzerr.txt")"
  fi
  # inner step failure aborts immediately (no retry on timeout)
  cat > "$work/ab.yaml" <<'EOF'
name: a17ab
steps:
  - retry:
      attempts: 5
      until_output_contains: "X"
      steps:
        - run: sleep 30
          timeout_s: 2
EOF
  _compile "$work/ab.yaml" "$work/ab.sh" >/dev/null 2>&1
  s=$SECONDS
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/ab.sh" 2>"$work/aberr.txt"); rc=$?
  el=$((SECONDS - s))
  if [ "$rc" -eq 10 ] && grep -q 'reason=timeout' "$work/aberr.txt" && [ "$el" -lt 8 ]; then
    _tpass "A17-abortfast"
  else
    _tfail "A17-abortfast" "rc=$rc elapsed=${el}s (must not retry a timeout)"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A18: command echo suppressed (marker problem auto-fixed)
t_a18() {
  local id="a18"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  # The command TEXT contains the pattern; the OUTPUT does not.
  # With echo on, branch would wrongly take 'then'.
  cat > "$work/dsl.yaml" <<'EOF'
name: a18
steps:
  - run: echo "clean" # ECHO_MARKER_XYZ
  - branch:
      if_output_contains: ECHO_MARKER_XYZ
      then:
        - run: echo BUG_ECHO_LEAKED
      else:
        - run: echo ECHO_SUPPRESSED_OK
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A18" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>&1
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if echo "$po" | grep -q "ECHO_SUPPRESSED_OK" && ! echo "$po" | grep -q "BUG_ECHO_LEAKED"; then
    _tpass "A18"
  else
    _tfail "A18" "command echo leaked into branch matching"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A19: matchers see fresh output only (no manual clear)
t_a19() {
  local id="a19"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a19
steps:
  - run: echo STALE_OLD_AAA
  - run: echo FRESH_NEW_BBB
  - wait_for: FRESH_NEW_BBB
    timeout_s: 5
  - branch:
      if_output_contains: STALE_OLD_AAA
      then:
        - run: echo STALE_LEAKED
      else:
        - run: echo FRESHNESS_OK
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1 || { _tfail "A19" "compile failed"; _end_tmux; rm -rf "$work"; return; }
  local out rc
  out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if [ "$rc" -eq 0 ] && echo "$po" | grep -q "FRESHNESS_OK" && ! echo "$po" | grep -q "STALE_LEAKED"; then
    _tpass "A19"
  else
    _tfail "A19" "rc=$rc err=$(cat "$work/err.txt")"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A20: dsl_line in every failure
t_a20() {
  local id="a20"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a20
steps:
  - run: echo fine
  - run: sleep 30
    timeout_s: 2
  - fail: unreachable
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt" >/dev/null; local rc=$?
  # the failing `run: sleep 30` is on YAML line 4
  if [ "$rc" -eq 10 ] && grep -q "dsl_line=4" "$work/err.txt"; then
    _tpass "A20-timeout"
  else
    _tfail "A20-timeout" "rc=$rc err=$(cat "$work/err.txt")"
  fi
  cat > "$work/f.yaml" <<'EOF'
name: a20f
steps:
  - fail: boom-reason
EOF
  _compile "$work/f.yaml" "$work/f.sh" >/dev/null 2>&1
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/f.sh" 2>"$work/ferr.txt" >/dev/null; rc=$?
  if [ "$rc" -eq 13 ] && grep -q "reason=boom-reason dsl_line=3" "$work/ferr.txt"; then
    _tpass "A20-fail"
  else
    _tfail "A20-fail" "rc=$rc err=$(cat "$work/ferr.txt")"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- A21: echo restored after timeout failure
t_a21() {
  local id="a21"; _new_tmux "$id"
  local work; work=$(mktemp -d)
  cat > "$work/dsl.yaml" <<'EOF'
name: a21
steps:
  - run: sleep 30
    timeout_s: 2
EOF
  _compile "$work/dsl.yaml" "$work/product.sh" >/dev/null 2>&1
  TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" >/dev/null 2>&1; local rc=$?
  [ "$rc" -eq 10 ] || { _tfail "A21" "expected timeout rc=10, got $rc"; _end_tmux; rm -rf "$work"; return; }
  # pane echo must be back on: typed text echoes
  tmux -L "$TSOCK" send-keys -l -t "$PANE" 'echo ECHO_CHECK_789'
  tmux -L "$TSOCK" send-keys -t "$PANE" Enter; sleep 0.5
  local po; po=$(tmux -L "$TSOCK" capture-pane -p -t "$PANE")
  if echo "$po" | grep -q 'echo ECHO_CHECK_789'; then
    _tpass "A21"
  else
    _tfail "A21" "pane echo left off after timeout"
  fi
  _end_tmux; rm -rf "$work"
}

# ---------------------------------------------------------------- run all
t_a1
t_a2
t_a3
t_a4
t_a5_a6
t_a7
t_a8
t_a9
t_a10
t_a11
t_a12
t_a13
t_a14
t_a15
t_a16
t_a17
t_a18
t_a19
t_a20
t_a21

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
