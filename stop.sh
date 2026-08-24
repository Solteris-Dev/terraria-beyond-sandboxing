#!/usr/bin/env bash
# `pwd` is logical, so invoking this through a symlink yields a different
# spelling of the same directory -- and the "already running?" check below
# compares spellings. That mismatch starts a SECOND bridge, which then answers
# every in-game message twice. `pwd -P` resolves to one canonical path.
BR="$(cd "$(dirname "$0")" && pwd -P)"
if pkill -f "$BR/bridge.sh"; then echo "stopped"; else echo "not running"; fi
# run.lock is a DIRECTORY (mkdir is the atomic lock primitive), so rm -f alone
# would silently leave it behind and wedge the next start.
rm -rf "$BR/state/run.lock"
rm -f "$BR/state/current.pid" "$BR/state/interrupted"
