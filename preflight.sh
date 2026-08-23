#!/usr/bin/env bash
# Check everything the bridge needs before you run it. Safe to run any time.
set -uo pipefail
BR="$(cd "$(dirname "$0")" && pwd)"
ok=0; bad=0

chk() {  # chk <label> <condition-result> <hint>
  if [ "$2" -eq 0 ]; then printf '  \033[32mok\033[0m    %s\n' "$1"; ok=$((ok+1))
  else printf '  \033[31mFAIL\033[0m  %-38s %s\n' "$1" "$3"; bad=$((bad+1)); fi
}

echo "terraria-beyond-sandboxing preflight"
echo

for c in claude jq tmux; do
  command -v "$c" >/dev/null 2>&1; chk "$c on PATH" $? "install $c"
done

# bash 4+ needed for associative/regex behaviour used in the gate
[ "${BASH_VERSINFO[0]}" -ge 4 ]; chk "bash >= 4 (have ${BASH_VERSION%%(*})" $? "upgrade bash"

# shellcheck source=/dev/null
. "$BR/bridge.conf" 2>/dev/null

[ -n "${TSRV:-}" ] && [ -x "${TSRV:-}" ]
chk "tsrv found${TSRV:+ ($TSRV)}" $? "get it from the tsrv project, or set TSRV="

[ -n "${SERVER_LOG:-}" ]
chk "server log path resolved" $? "set SERVER_LOG= in bridge.conf"

[ -x "$BR/hooks/gate.sh" ]; chk "hooks/gate.sh executable" $? "chmod +x hooks/gate.sh"

if command -v jq >/dev/null 2>&1; then
  jq -e '.hooks.PreToolUse[0].hooks[0].command' "$BR/.claude/settings.json" >/dev/null 2>&1
  chk "settings.json registers the hook" $? "check .claude/settings.json"
fi

# The single most dangerous misconfiguration: a veto window at or above the
# hook timeout means the hook gets killed mid-wait, renders no decision, and
# the tool runs anyway. Silent, and it turns the veto into a rubber stamp.
HOOK_TIMEOUT="$(jq -r '.hooks.PreToolUse[0].hooks[0].timeout // 60' "$BR/.claude/settings.json" 2>/dev/null || echo 60)"
[ "${VETO_WINDOW:-15}" -lt "$(( HOOK_TIMEOUT - 20 ))" ]
chk "VETO_WINDOW ($VETO_WINDOW s) safely under hook timeout (${HOOK_TIMEOUT}s)" $? \
    "raise the hook timeout or lower VETO_WINDOW -- otherwise the gate fails OPEN"

echo
if [ "$bad" -eq 0 ]; then
  echo "  all $ok checks passed -- ./start.sh when ready"
else
  echo "  $bad problem(s); fix those first"
fi
[ "$bad" -eq 0 ]
