#!/usr/bin/env bash
# Open the bridge's Claude conversation in your terminal.
#
#   ./resume.sh                 resume the newest bridge session
#   ./resume.sh --safe-mode     ...without this repo's PreToolUse gate
#   ./resume.sh <extra args>    anything else is passed through to claude
#
# Why this exists: `/resume` builds its list from ~/.claude/history.jsonl,
# which records prompts TYPED at the REPL. The bridge speaks to Claude with
# `claude -p`, so its prompts never land there and its conversation never shows
# up in the picker -- not in this project, not under ctrl+A "all projects".
# Nothing is wrong with the transcript; it just has to be resumed by id.
set -uo pipefail
BR="$(cd "$(dirname "$0")" && pwd -P)"

# Transcripts live in a project directory named after the cwd with `/` and `.`
# flattened to `-`.
PDIR="$HOME/.claude/projects/$(printf '%s' "$BR" | tr '/.' '--')"
if [ ! -d "$PDIR" ]; then
  # Naming rule changed, or this checkout moved after the session was created:
  # ask the transcripts themselves which one records this directory as its cwd.
  PDIR="$(grep -rl --include='*.jsonl' -m1 "\"cwd\":\"$BR\"" \
          "$HOME/.claude/projects" 2>/dev/null | head -1 | xargs -r dirname)"
fi

SID="$(ls -t "$PDIR"/*.jsonl 2>/dev/null | head -1)"
if [ -z "$SID" ]; then
  echo "No bridge conversation yet — send a '!' message in-game first." >&2
  exit 1
fi
SID="$(basename "$SID" .jsonl)"

# Never pin an id: IDLE_ROTATE starts a fresh thread once the old one goes
# cold, so the newest transcript is the live one.
if pgrep -f "$BR/bridge.sh" >/dev/null 2>&1; then
  echo "NOTE: the bridge is running. It shares this thread, so your turns"
  echo "      become context for the next in-game '!'. Your tool calls also"
  echo "      hit the gate: announced in chat, with the veto window before"
  echo "      each one. --safe-mode skips the hook; ./stop.sh gives you the"
  echo "      conversation to yourself."
fi

echo "resuming $SID"
cd "$BR" || exit 1
exec claude --resume "$SID" "$@"
