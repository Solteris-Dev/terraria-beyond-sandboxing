#!/usr/bin/env bash
# Feed fixtures.jsonl through the PreToolUse gate and check both the decision
# AND the reason -- the reason is what distinguishes "silently auto-approved"
# from "announced, waited, nobody objected". Conflating those is how the tsrv
# substring bypass survived the first round of tests.
set -uo pipefail
BR="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$BR/hooks/gate.sh"
FIXTURES=("$BR/tests/fixtures.jsonl" "$BR/tests/fixtures-readonly.jsonl")

# Fixtures are templated so they work on any machine; fill them from the
# same discovery the gate uses.
# shellcheck source=/dev/null
. "$BR/bridge.conf"
# The suite is meant to run with no Terraria server present, so give the
# templates a placeholder when discovery found nothing.
: "${TSRV:=/nonexistent/tsrv}"
: "${ALLOWED_WRITE_ROOTS:=$HOME/Games}"

# Keep the announce-and-wait cases quick.
export GATE_VETO_WINDOW="${GATE_VETO_WINDOW:-2}"

# Never talk to the live server from tests. The announce path is exercised by
# several fixtures, and without this it broadcasts alarming half-finished
# commands to whoever is currently playing.
export GATE_TSRV_OVERRIDE="$BR/tests/tsrv-stub.sh"
export GATE_STUB_LOG="$BR/logs/test-broadcasts.log"
: > "$GATE_STUB_LOG"

pass=0; fail=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  expect=$(jq -r '.expect' <<<"$line")
  rxp=$(jq -r '.reason // ""' <<<"$line")
  why=$(jq -r '.why' <<<"$line")
  input=$(jq -c '.input' <<<"$line")

  out=$(printf '%s' "$input" | timeout 30 "$GATE" 2>/dev/null)
  got=$(jq -r '.hookSpecificOutput.permissionDecision // "NONE"' <<<"$out" 2>/dev/null)
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$out" 2>/dev/null)

  ok=1
  [ "$got" = "$expect" ] || ok=0
  if [ -n "$rxp" ] && ! grep -qE "$rxp" <<<"$reason"; then ok=0; fi

  if [ "$ok" -eq 1 ]; then
    printf '  PASS  %-6s %s\n' "$got" "$why"
    pass=$((pass+1))
  else
    printf '  FAIL  want=%s/%s got=%s/"%s"\n        %s\n' \
      "$expect" "${rxp:-*}" "$got" "$reason" "$why"
    fail=$((fail+1))
  fi
done < <(cat "${FIXTURES[@]}" \
          | sed -e "s|__TSRV__|${TSRV}|g" \
                -e "s|__GAMES__|${ALLOWED_WRITE_ROOTS%%:*}|g" \
                -e "s|__HOME__|${HOME}|g")

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
