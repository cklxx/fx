#!/bin/bash
set -e
D="${1:-/tmp/tc-trace-branch}"
mkdir -p "$D"
echo '#!/bin/bash
echo "service HEALTHY"' > "$D/healthcheck.sh"
echo '#!/bin/bash
echo "deploying..."' > "$D/deploy.sh"
chmod +x "$D/healthcheck.sh" "$D/deploy.sh"
echo "$D"
