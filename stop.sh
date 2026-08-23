#!/usr/bin/env bash
BR="$(cd "$(dirname "$0")" && pwd)"
if pkill -f "$BR/bridge.sh"; then echo "stopped"; else echo "not running"; fi
# run.lock is a DIRECTORY (mkdir is the atomic lock primitive), so rm -f alone
# would silently leave it behind and wedge the next start.
rm -rf "$BR/state/run.lock"
rm -f "$BR/state/current.pid" "$BR/state/interrupted"
