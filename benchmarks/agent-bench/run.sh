#!/bin/bash
# agent-bench one-click runner.
set -euo pipefail
cd "$(dirname "$0")"

ZIG_BIN=".tools/zig-x86_64-linux-0.17.0/zig"
SIM_BIN=".tools/sim-server"
FX_BIN=".tools/fx"

# 1. Zig toolchain
if [ ! -x "$ZIG_BIN" ]; then
  echo "downloading zig..."
  mkdir -p .tools
  curl -sL -o .tools/zig.tar.xz https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
  tar xf .tools/zig.tar.xz -C .tools --no-same-owner
fi

# 2. Build sim-server
if [ sim-server.zig -nt "$SIM_BIN" ] || [ ! -x "$SIM_BIN" ]; then
  echo "building sim-server..."
  "$ZIG_BIN" build-exe sim-server.zig -O ReleaseFast -femit-bin="$SIM_BIN"
fi

# 3. fx binary
if [ ! -x "$FX_BIN" ]; then
  echo "downloading fx..."
  mkdir -p .tools
  (cd .tools && gh release download v0.0.13 --repo vercel-labs/fx -p 'fx-linux-x86_64.tar.gz' && tar xzf fx-linux-x86_64.tar.gz --no-same-owner)
fi

# 4. Run harness
exec node harness.mjs "$@"
