#!/usr/bin/env bash
# tests/soak_tmux_compile.sh -- long-run stability soak for tmux_compile.
# NOT part of the default suite (takes ~2-3 min). Run manually:
#   bash tests/soak_tmux_compile.sh
#
# Exercises what "tmux connection stability" really means here: every tmux
# CLI call is a fresh socket connection (nothing persistent to drop), so the
# risks are (1) wait-for signal reliability over many iterations,
# (2) the 0.5s poll loops, (3) /tmp file hygiene (RCFILE per run).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

TSOCK="soak-$$"
tmux -L "$TSOCK" kill-server 2>/dev/null
tmux -L "$TSOCK" new-session -d -x 200 -y 50 -s main
sleep 1
PANE=$(tmux -L "$TSOCK" display-message -p -t main '#{pane_id}')

work=$(mktemp -d)
# 40 sequential runs + 5 real wait_for cycles + a retry block
{
  echo "name: soak"
  echo "steps:"
  for i in $(seq 1 40); do
    echo "  - run: echo soak-step-$i"
  done
  for i in $(seq 1 5); do
    echo "  - run: ( sleep 2; echo SOAK_READY_$i ) &"
    echo "  - wait_for: SOAK_READY_$i"
    echo "    timeout_s: 10"
  done
  echo "  - retry:"
  echo "      attempts: 3"
  echo "      until_output_contains: SOAK_DONE"
  echo "      steps:"
  echo "        - run: echo SOAK_DONE"
} > "$work/dsl.yaml"

python3 -m tmux_compile "$work/dsl.yaml" -o "$work/product.sh" \
  || { echo "FAIL soak: compile"; tmux -L "$TSOCK" kill-server 2>/dev/null; exit 1; }

s=$SECONDS
out=$(TSOCK="$TSOCK" PANE="$PANE" bash "$work/product.sh" 2>"$work/err.txt"); rc=$?
el=$((SECONDS - s))
tmux -L "$TSOCK" kill-server 2>/dev/null

# /tmp hygiene: no leftover rc files from this run's products
leftovers=$(ls /tmp/tmux-compile-rc-* 2>/dev/null | wc -l)

echo "elapsed=${el}s rc=$rc leftovers=$leftovers"
[ "$rc" -eq 0 ] || { echo "FAIL soak: rc=$rc"; cat "$work/err.txt"; rm -rf "$work"; exit 1; }
echo "$out" | tail -1 | grep -q "COMPILE-OK" || { echo "FAIL soak: no COMPILE-OK"; rm -rf "$work"; exit 1; }
[ "$leftovers" -eq 0 ] || { echo "WARN soak: $leftovers rc files leaked (pre-existing trap behavior)"; }
echo "PASS soak: 40 runs + 5 wait_for + retry, ${el}s"
rm -rf "$work"
