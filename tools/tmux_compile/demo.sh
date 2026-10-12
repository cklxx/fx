#!/usr/bin/env bash
# demo-tmux-compile.sh -- 2-minute demo of tmux_compile.
# User story 1 (PR review loop), simplified:
#   1. YAML -> bash: compile and show the readable product
#   2. Run the product twice: proves the wait-for latch is handled
#      (2nd run really waits, not instantly released)
#   3. Timeout failure: precise error naming the step
#
# Zero dependencies beyond tmux CLI. Isolated tmux server (-L).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

TSOCK="demo-tmc-$$"
WORK=$(mktemp -d)
trap 'tmux -L "$TSOCK" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT

say() { echo; echo "=== $1 ==="; }

say "1. Write the flow (YAML)"
cat > "$WORK/review.yaml" <<'EOF'
name: pr-review-loop
steps:
  # pretend CI: reviewer agent posts verdict after ~2s
  - run: sleep 2; echo REVIEW verdict=APPROVED
    timeout_s: 15
  - wait_for: verdict=APPROVED
    timeout_s: 15
  # text branch: approved -> merge, else -> request changes
  - branch:
      if_output_contains: verdict=APPROVED
      then:
        - run: echo MERGE pr=1234
      else:
        - run: echo REQUEST_CHANGES pr=1234
EOF
cat "$WORK/review.yaml"

say "2. Compile YAML -> bash (readable, zero-dependency)"
python3 -m tmux_compile "$WORK/review.yaml" -o "$WORK/review.sh"
echo "--- product (first 30 lines) ---"
head -30 "$WORK/review.sh"
echo "... (full product: $(wc -l < "$WORK/review.sh") lines, plain bash + tmux CLI)"

say "3. Run it (isolated tmux server, 200x50 pane)"
tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')
sleep 1
TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/review.sh"
echo "exit=$?"

say "4. Run it AGAIN on the same server (latch check)"
echo "If the wait-for token were hard-coded, this 2nd run would return instantly."
echo "Watch: it really waits ~2s for the sleep to finish."
START=$SECONDS
TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/review.sh"
EL=$((SECONDS - START))
echo "exit=$? elapsed=${EL}s (must be >= 2s)"

say "5. Timeout failure: precise error names the step"
cat > "$WORK/fail.yaml" <<'EOF'
name: fail-demo
steps:
  - run: echo ok-first
  - run: sleep 60
    timeout_s: 3
  - run: echo never-reached
EOF
python3 -m tmux_compile "$WORK/fail.yaml" -o "$WORK/fail.sh" >/dev/null
if TSOCK="$TSOCK" PANE="$PANE" bash "$WORK/fail.sh" 2>"$WORK/fail.err"; then
  echo "unexpected success"
else
  echo "exit=$? (expect 10)"
  echo "stderr: $(cat "$WORK/fail.err")"
fi

say "Done. The product is 'compiled once, instantiated per run':"
echo "TOKEN is generated at RUNTIME (see product header), never baked in."
