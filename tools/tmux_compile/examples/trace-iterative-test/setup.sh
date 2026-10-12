#!/bin/bash
set -e
D="${1:-/tmp/tc-trace-iter}"
mkdir -p "$D"
cat > "$D/app.py" <<'EOF'
import os
n = int(os.environ.get("ITER", "1"))
print(f"iter {n}: OK")
EOF
echo "$D"
