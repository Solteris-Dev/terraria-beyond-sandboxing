#!/usr/bin/env bash
set -euo pipefail
# `pwd` is logical, so invoking this through a symlink yields a different
# spelling of the same directory -- and the "already running?" check below
# compares spellings. That mismatch starts a SECOND bridge, which then answers
# every in-game message twice. `pwd -P` resolves to one canonical path.
BR="$(cd "$(dirname "$0")" && pwd -P)"
if pgrep -f "$BR/bridge.sh" >/dev/null; then
  echo "already running (pid $(pgrep -f "$BR/bridge.sh" | head -1))"
  exit 0
fi
mkdir -p "$BR/logs"
nohup "$BR/bridge.sh" >> "$BR/logs/bridge.out" 2>&1 &
echo "started pid $!"
