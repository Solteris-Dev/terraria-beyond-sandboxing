#!/usr/bin/env bash
# PreToolUse gate: announce the pending tool call in Terraria chat, then wait a
# bounded window for someone to type the veto token. Allow if nobody objects.
#
# FAIL-OPEN IS THE ENEMY. A hook that exceeds its timeout, crashes, or prints
# malformed JSON renders NO decision and the tool RUNS. So this script:
#   * bounds every external command with its own timeout,
#   * emits a decision from an EXIT TRAP so even a crash/signal decides,
#   * builds JSON without depending on jq being present,
#   * keeps its own deadline far inside the hook timeout in settings.json.
#
# Read the threat model in README.md before trusting this: the hard floor is a
# speed bump against an agent doing something dumb, NOT containment against a
# hostile prompt. The server password is the real boundary.
set -uo pipefail

BR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$BR/bridge.conf"

AUDIT="$BR/logs/gate.log"
mkdir -p "$BR/logs"

# Tests (and impatient humans) can shorten the wait without editing config.
VETO_WINDOW="${GATE_VETO_WINDOW:-$VETO_WINDOW}"

# Two distinct jobs, so two variables:
#   TSRV     -- the real binary path, used to RECOGNISE an auto-approvable
#               command. Never overridden, or the allowlist stops matching.
#   ANNOUNCE -- where chat output GOES. Tests redirect this to a stub, because
#               otherwise the suite broadcasts "PENDING Bash: rm --recursive
#               --force /etc" to whoever is currently playing. It did, once.
ANNOUNCE="${GATE_TSRV_OVERRIDE:-$TSRV}"
ts() { date -Is 2>/dev/null || echo "?"; }

DECIDED=0

# Emit JSON by hand -- no jq dependency, so a missing jq cannot fail us open.
# Only the reason string is variable, so escaping it is enough.
emit() {  # emit <allow|deny> <reason>
  local d="$1" r="$2"
  r="${r//\\/\\\\}"; r="${r//\"/\\\"}"; r="${r//$'\n'/ }"; r="${r//$'\t'/ }"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$d" "$r"
  DECIDED=1
  echo "$(ts)  DECISION=$d  $r" >> "$AUDIT" 2>/dev/null || true
}

decide() { emit "$1" "$2"; exit 0; }

# Last line of defence: if we fall off the end, crash, or get signalled without
# having decided, deny. Never let silence mean yes.
on_exit() {
  if [ "$DECIDED" -eq 0 ]; then
    emit deny "gate exited without a decision (fail-closed)"
  fi
}
trap on_exit EXIT
trap 'decide deny "gate interrupted (fail-closed)"' INT TERM

INPUT="$(timeout 5 cat)" || INPUT=""
[ -n "$INPUT" ] || decide deny "no hook input received"

# Minimal field extraction. Prefer jq when present, fall back to grep/sed so a
# broken jq degrades to a working gate rather than an open one.
field() {  # field <jq-path> <regex-key>
  local v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(timeout 5 jq -r "$1 // empty" <<<"$INPUT" 2>/dev/null)" || v=""
  fi
  if [ -z "$v" ]; then
    v="$(grep -oP "\"$2\"\s*:\s*\"\K([^\"\\\\]|\\\\.)*" <<<"$INPUT" 2>/dev/null | head -1)"
  fi
  printf '%s' "$v"
}

TOOL="$(field '.tool_name' 'tool_name')"
[ -n "$TOOL" ] || decide deny "malformed hook input: no tool_name (fail-closed)"
CMD="$(field '.tool_input.command' 'command')"
FILE="$(field '.tool_input.file_path' 'file_path')"
DETAIL="${CMD:-$FILE}"
echo "$(ts)  REQUEST tool=$TOOL detail=$(head -c 300 <<<"$DETAIL")" >> "$AUDIT" 2>/dev/null || true

# ---- 1. Hard floor -------------------------------------------------------
# A blacklist over shell strings is inherently leaky (rm -r -f --, /bin/rm,
# find -delete, an interpreter, a variable...). Kept because it stops the
# realistic accident, not because it stops a determined prompt.
deny_floor() { decide deny "hard floor: $1"; }

C="$(tr -s '[:space:]' ' ' <<<"$DETAIL")"
case "$TOOL" in
  Bash|BashOutput|KillShell)
    case " $C " in
      *sudo*|*doas*|*pkexec*|*" su "*)        deny_floor "privilege escalation" ;;
      *mkfs*|*" dd "*|*"dd if="*|*"dd of="*)  deny_floor "raw disk write" ;;
      *shutdown*|*reboot*|*poweroff*|*halt*)  deny_floor "power state change" ;;
      *":(){"*)                               deny_floor "fork bomb" ;;
      *"|"*sh*|*"|"*bash*|*"|"*zsh*)          deny_floor "pipe-to-shell" ;;
      *iptables*|*nft*|*"tc qdisc"*)          deny_floor "network config change" ;;
      *crontab*|*systemctl*|*"at now"*)       deny_floor "persistence / service control" ;;
    esac
    # rm with recursive+force in any spelling, targeting anything near root.
    if grep -qE '(^|[;&|[:space:]])(/bin/|/usr/bin/)?rm([[:space:]]+(-[a-zA-Z]+|--[a-z-]+))*[[:space:]]+(--[[:space:]]+)?/([[:space:]]|$)' <<<"$C"; then
      deny_floor "recursive delete targeting /"
    fi
    # Recursive AND force, in any spelling (short bundle, split, or long form),
    # unless the target is clearly inside ~/Games.
    if grep -qE '(^|[;&|[:space:]])(/[a-z/]*)?rm([[:space:]]|$)' <<<"$C" \
       && grep -qE '(--recursive|[[:space:]]-[a-zA-Z]*[rR])' <<<"$C" \
       && grep -qE '(--force|[[:space:]]-[a-zA-Z]*[fF])' <<<"$C" \
       && ! grep -qF "$HOME/Games/" <<<"$C"; then
      deny_floor "recursive force delete outside ~/Games"
    fi
    ;;
  Write|Edit|NotebookEdit|MultiEdit)
    # Resolve before comparing. A plain prefix match is escapable with
    # "$HOME/Games/../.bashrc" or a symlink planted under an allowed root.
    # -m so a not-yet-existing target still normalises.
    _abs="$(realpath -m -- "$FILE" 2>/dev/null)" || _abs=""
    [ -n "$_abs" ] || deny_floor "cannot resolve write target: $FILE"
    _ok=0
    IFS=':' read -ra _roots <<< "$ALLOWED_WRITE_ROOTS"
    for _r in "${_roots[@]}" "$BR"; do
      [ -n "$_r" ] || continue
      _rr="$(realpath -m -- "$_r" 2>/dev/null)" || continue
      case "$_abs" in "$_rr"/*) _ok=1; break ;; esac
    done
    [ "$_ok" -eq 1 ] || deny_floor "write outside allowed roots ($ALLOWED_WRITE_ROOTS): $_abs"
    ;;
esac

# ---- 2. Silent auto-approve ----------------------------------------------
# Read-only tools only. NOTE: Bash is deliberately NOT auto-approved on a
# substring match any more -- "anything ; tsrv status" used to sail through.
# Only an exact, operator-free invocation of the tsrv binary qualifies.
case "$TOOL" in
  Read|Grep|Glob|WebSearch|WebFetch|TodoWrite)
    decide allow "auto: read-only tool"
    ;;
  Bash)
    TSRV_RE="^[[:space:]]*${TSRV//\//\\/}[[:space:]]+(status|players|log|chat|save|help)([[:space:]]+[0-9]+)?[[:space:]]*$"
    if [[ "$CMD" =~ $TSRV_RE ]] && ! grep -qE '[;&|<>`$()]' <<<"$CMD"; then
      decide allow "auto: exact tsrv read command"
    fi

    # The risk signal is whether a command MUTATES, not whether it is Bash.
    # `ls` is exactly as harmless as the Read tool, and gating it bought no
    # safety while costing 15s and a line of chat spam per call -- which is
    # what made the first live run time out at 300s having done nothing.
    #
    # Conservative by construction: a single unbranded command, no operators
    # (; & | < > ` $ ( )) so nothing can be chained on, from a fixed verb list.
    if ! grep -qE '[;&|<>`$()]' <<<"$CMD"; then
      _verb="$(awk '{print $1}' <<<"${CMD# }")"
      _verb="${_verb##*/}"
      # Deliberately EXCLUDED despite looking harmless:
      #   env, command, type, xargs, nice, timeout -- all run another program
      #   awk, sed, perl, python     -- awk has system(), sed has -i
      # Each of those is an execution primitive wearing a utility's clothes.
      case "$_verb" in
        ls|cat|head|tail|wc|stat|file|du|df|pwd|whoami|hostname|uname|date|\
        echo|printf|grep|rg|tree|realpath|basename|dirname|readlink|\
        ps|uptime|free|id|which|column|cut|jq|md5sum|sha256sum)
          decide allow "auto: read-only shell command ($_verb)"
          ;;
        sort|uniq)
          # Both can WRITE: `sort -o FILE` and `uniq INPUT OUTPUT`.
          _nargs="$(awk '{n=0; for(i=2;i<=NF;i++) if ($i !~ /^-/) n++; print n}' <<<"$CMD")"
          # -o FILE, -oFILE and --output=FILE all write.
          if ! grep -qE '(^|[[:space:]])(-[a-zA-Z]*o|--output)' <<<"$CMD" \
             && [ "${_nargs:-0}" -le 1 ]; then
            decide allow "auto: read-only $_verb"
          fi
          ;;
        find|fd)
          # find is read-only only until someone adds an action flag.
          # Any action flag makes these write. Match prefixes, not exact
          # words: -fprint0 and --exec both slipped past an anchored list.
          if ! grep -qE '(^|[[:space:]])--?(delete|exec|execdir|ok|okdir|fls|fprint|fprintf|X|x)' <<<"$CMD"; then
            decide allow "auto: read-only $_verb"
          fi
          ;;
        git)
          # `git branch <name>` creates, `git remote add` mutates config --
          # the subcommand alone is not enough to judge. Only allow the
          # unambiguously read-only ones, and require branch/remote to be
          # bare listings with no extra operand.
          _sub="$(awk '{print $2}' <<<"$CMD")"
          _rest="$(awk '{for(i=3;i<=NF;i++) if ($i !~ /^-/) print $i}' <<<"$CMD")"
          # Even a read-only subcommand can write with --output, and
          # branch/remote take mutating flags with no positional operand.
          if ! grep -qE '(^|[[:space:]])--(output|unset|unset-upstream|edit-description|set-upstream|set-url|move|copy|delete)' <<<"$CMD"; then
            case "$_sub" in
              status|log|diff|show|describe|rev-parse|ls-files|blame|shortlog)
                decide allow "auto: read-only git ($_sub)" ;;
              branch|remote|tag)
                # NOT stash: bare `git stash` mutates the worktree.
                [ -z "$_rest" ] && decide allow "auto: bare git $_sub listing" ;;
            esac
          fi
          ;;
      esac
    fi
    ;;
esac

# ---- 3. Announce and wait for a veto -------------------------------------
MARK="$(timeout 5 wc -l < "$SERVER_LOG" 2>/dev/null || echo 0)"
SUMMARY="$(head -c 110 <<<"$DETAIL" | tr -d '\n')"

# Bounded: a hung tsrv must not eat the hook timeout and fail us open.
timeout 8 "$ANNOUNCE" reply "PENDING $TOOL: ${SUMMARY:-<no detail>} -- type $VETO within ${VETO_WINDOW}s to deny" \
  >/dev/null 2>&1 || echo "$(ts)  WARN announce failed/timed out" >> "$AUDIT"

vetoed() {
  timeout 3 tail -n "+$((MARK + 1))" "$SERVER_LOG" 2>/dev/null \
    | grep -aE "^<[^>]+> *!!!" | grep -qav "^<Server>"
}

DEADLINE=$(( $(date +%s) + VETO_WINDOW ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if vetoed; then
    timeout 8 "$ANNOUNCE" reply "DENIED $TOOL by veto." >/dev/null 2>&1 || true
    decide deny "vetoed in game with $VETO"
  fi
  sleep 1
done

# Mandatory final scan: the loop above can exit up to a second before the last
# check would have run, so a veto landing at the very end must still count.
if vetoed; then
  timeout 8 "$ANNOUNCE" reply "DENIED $TOOL by veto." >/dev/null 2>&1 || true
  decide deny "vetoed in game with $VETO (final scan)"
fi

decide allow "no veto within ${VETO_WINDOW}s"
