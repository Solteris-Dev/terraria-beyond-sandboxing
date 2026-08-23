#!/usr/bin/env bash
# Stand-in for tsrv during tests. Records what WOULD have been broadcast
# instead of posting it to the live Terraria server.
echo "$(date -Is)  [stub] $*" >> "${GATE_STUB_LOG:-/dev/null}"
exit 0
