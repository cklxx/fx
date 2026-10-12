# Simulates the HETEROGENEOUS.md "missing-item" case: a small model that
# forgets to write part of its output, then gets it right on retry.
#!/bin/sh
STATE_FILE="${RETRY_STATE:-/tmp/retry-demo-count}"
n=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$STATE_FILE"
echo "attempt $n: writing report..."
if [ "$n" -lt 3 ]; then
  # small-model mistake: writes the report but forgets the gamma section
  printf 'alpha: ok\nbeta: ok\n' > report.md
  echo "report.md written (gamma section missing)"
  exit 0
fi
printf 'alpha: ok\nbeta: ok\ngamma: ok\n' > report.md
echo "report.md written (complete)"
exit 0
