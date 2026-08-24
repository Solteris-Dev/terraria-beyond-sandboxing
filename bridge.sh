#!/usr/bin/env bash
# terraria-claude-bridge -- listen for "!" commands in Terraria chat, run them
# through the Claude Code CLI, and speak the answer back into the game.
#
# Runs out of its own directory on purpose: `claude --continue` resolves to the
# most recent session in the working directory, so keeping the bridge here stops
# it from hijacking (or being hijacked by) interactive sessions elsewhere.
set -uo pipefail

BR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BR/bridge.conf"

STATE="$BR/state"
LOG="$BR/logs/bridge.log"
LOCK="$STATE/run.lock"
LAST="$STATE/last_activity"
CURPID="$STATE/current.pid"

mkdir -p "$STATE" "$BR/logs"

if [ -z "${TSRV:-}" ] || [ ! -x "${TSRV:-}" ]; then
  echo "Could not find tsrv (the Terraria server wrapper this bridge talks to)." >&2
  echo "  Get it:  https://github.com/Solteris-Dev/tsrv" >&2
  echo "  Or set:  export TSRV=/path/to/tsrv" >&2
  echo "Run ./preflight.sh for a full check." >&2
  exit 1
fi
if [ -z "${SERVER_LOG:-}" ]; then
  echo "Could not determine the server log path. Set SERVER_LOG=/path/to/server.log" >&2
  exit 1
fi
ts() { date -Is; }
note() { echo "$(ts)  $*" >> "$LOG"; }

# tsrv can fail transiently (server mid-save, console busy). Swallowing the
# exit code made a lost reply indistinguishable from a delivered one: the
# bridge logged REPLY either way while the player saw nothing. Retry, and if
# it still will not go, say so in the log instead of pretending.
say() {
  local msg="$*" attempt
  for attempt in 1 2 3; do
    if "$TSRV" reply "$msg" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  note "SAY FAILED after 3 attempts: $(head -c 120 <<<"$msg")"
  return 1
}

# The server console interleaves its own prompt and a cursor-position query
# (ESC[6n) into the log, so a chat line that lands mid-prompt is recorded as
#   :  ESC[6n<Player> ! ping
# rather than at the start of the line. Anchored matches then skip it, which
# silently drops the request -- and, worse, drops a veto. Strip the escapes
# and any junk ahead of the first "<name> " before matching.
sanitize() {
  sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/^[^<]*\(<[^<>]*> \)/\1/'
}

# A second, independent layer enforced by the CLI itself, so a crashed or
# mis-edited hook cannot approve these. NOT a containment boundary: like the
# gate's hard floor it matches spellings, and a shell has endless synonyms
# (/bin/rm, find -delete, an interpreter, a variable). It stops the realistic
# accident. The server password is what actually keeps strangers out.
DISALLOW=(
  "Bash(sudo *)" "Bash(doas *)" "Bash(pkexec *)"
  "Bash(rm -rf /*)" "Bash(mkfs*)" "Bash(dd *)"
  "Bash(shutdown *)" "Bash(reboot *)"
)

cleanup() { rm -rf "$LOCK"; rm -f "$CURPID"; }
trap cleanup EXIT

# --- session threading -----------------------------------------------------
# Reuse the thread while it is warm; start fresh after IDLE_ROTATE seconds.
continue_flag() {
  [ -f "$LAST" ] || { echo ""; return; }
  local last now age
  last="$(cat "$LAST" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$(( now - last ))
  if [ "$age" -lt "$IDLE_ROTATE" ]; then echo "--continue"; else
    note "thread idle ${age}s >= ${IDLE_ROTATE}s, rotating to a fresh session"
    echo ""
  fi
}

# --- one request -----------------------------------------------------------
handle() {  # handle <speaker> <message>
  local who="$1"; shift
  local msg="$*"

  # Atomic lock. `[ -e ] && touch` is a race: two instances can both pass the
  # test and then delete each other's lock. mkdir either succeeds or doesn't.
  if ! mkdir "$LOCK" 2>/dev/null; then
    say "busy with the previous request, ignoring: $(head -c 60 <<<"$msg")"
    return
  fi

  local trust="unknown"
  case " $TRUSTED_PLAYERS " in *" $who "*) trust="trusted" ;; esac

  local prompt
  prompt="[Terraria chat] Player '$who' ($trust) asks: $msg

Answer for in-game chat: plain text, no markdown, no code blocks. Be brief --
every ~115 characters becomes another chat line. Prefer 1-3 short sentences."

  note "REQUEST from=$who trust=$trust msg=$msg"
  say "thinking..."

  local cont; cont="$(continue_flag)"
  local outf rc watcher agent watch_mark

  # Capture the log position BEFORE launching, synchronously. Capturing it
  # inside the watcher (which starts later) baselines away any veto typed in
  # the gap, so an instant "!!!" would be silently ignored.
  watch_mark="$(wc -l < "$SERVER_LOG" 2>/dev/null || echo 0)"
  outf="$(mktemp)"

  # setsid puts the agent in its own process group so we can signal the whole
  # tree. Killing only the `timeout` pid can orphan claude, since SIGKILL is
  # never forwarded to children.
  setsid bash -c "cd '$BR' && exec timeout 300 claude -p \"\$1\" $cont \
      --disallowedTools \"\${@:2}\" >'$outf' 2>>'$BR/logs/claude-stderr.log'" \
      _ "$prompt" "${DISALLOW[@]}" &
  agent=$!
  echo "$agent" > "$CURPID"

  # Watch chat for the veto token and abort the whole run if it appears.
  # This is the "interrupt the agent" half; the PreToolUse gate is the
  # "deny one action" half. Both listen for the same token.
  (
    while kill -0 "$agent" 2>/dev/null; do
      if tail -n "+$((watch_mark + 1))" "$SERVER_LOG" 2>/dev/null \
           | tr -d '\r' | sanitize \
           | grep -aE "^<[^>]+> *!!!" | grep -qav "^<Server>"; then
        touch "$STATE/interrupted"
        kill -INT -- "-$agent" 2>/dev/null || kill -INT "$agent" 2>/dev/null
        for _ in 1 2 3 4; do
          kill -0 "$agent" 2>/dev/null || break
          sleep 0.5
        done
        kill -KILL -- "-$agent" 2>/dev/null || kill -KILL "$agent" 2>/dev/null
        break
      fi
      sleep 1
    done
  ) &
  watcher=$!

  wait "$agent"; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null

  local out; out="$(cat "$outf")"; rm -f "$outf"
  date +%s > "$LAST"
  rm -rf "$LOCK"; rm -f "$CURPID"

  if [ -e "$STATE/interrupted" ]; then
    rm -f "$STATE/interrupted"
    say "interrupted."; note "INTERRUPTED by $VETO"; return
  fi
  if [ "$rc" -eq 124 ]; then
    say "timed out after 300s."; note "TIMEOUT"; return
  fi
  if [ "$rc" -ne 0 ] || [ -z "${out// }" ]; then
    say "something went wrong (exit $rc). check logs/claude-stderr.log"
    note "ERROR rc=$rc"; return
  fi

  note "REPLY $(head -c 200 <<<"$out")"
  say "$out"
}

# --- main loop -------------------------------------------------------------
note "bridge starting; watching $SERVER_LOG"
say "Claude bridge online. Prefix a message with $TRIGGER to ask. $VETO denies a pending action."

MARK="$(wc -l < "$SERVER_LOG" 2>/dev/null || echo 0)"
while true; do
  if [ ! -f "$SERVER_LOG" ]; then sleep 5; continue; fi

  CUR="$(wc -l < "$SERVER_LOG")"
  if [ "$CUR" -lt "$MARK" ]; then MARK=0; fi   # log was truncated by a restart

  if [ "$CUR" -gt "$MARK" ]; then
    while IFS= read -r line; do
      case "$line" in
        '<Server>'*) continue ;;
        '<'*'> '*) : ;;
        *) continue ;;
      esac
      who="${line%%>*}"; who="${who#<}"
      body="${line#*> }"
      case "$body" in
        "$VETO"*) continue ;;          # veto is for the gate, not a prompt
        "$TRIGGER"*) : ;;
        *) continue ;;
      esac
      req="${body#"$TRIGGER"}"
      req="${req# }"
      [ -n "${req// }" ] || continue
      handle "$who" "$req"
    done < <(tail -n "+$((MARK + 1))" "$SERVER_LOG" | tr -d '\r' | sanitize)
    MARK="$CUR"
  fi
  sleep 2
done
