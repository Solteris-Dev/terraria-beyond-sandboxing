#!/usr/bin/env bash
set -euo pipefail
BR="$(cd "$(dirname "$0")" && pwd)"
if pgrep -f "$BR/bridge.sh" >/dev/null; then
  echo "already running (pid $(pgrep -f "$BR/bridge.sh" | head -1))"
  exit 0
fi
mkdir -p "$BR/logs"
nohup "$BR/bridge.sh" >> "$BR/logs/bridge.out" 2>&1 &
echo "started pid $!"
