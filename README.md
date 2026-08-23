# terraria-beyond-sandboxing

<img width="1106" height="73" alt="image" src="https://github.com/user-attachments/assets/ed7eb56d-3e7a-4604-8482-1dd21465d89b" />
<img width="1387" height="812" alt="image" src="https://github.com/user-attachments/assets/4ff9347d-76eb-4362-a7e1-f8c64d15b57c" />


Ask Claude Code from inside Terraria chat.

```
<Alice> !what is the world seed
<Server> The seed is 754227596.
```

It is exactly as silly as it sounds, and the name is a warning, not a boast.

---

## ⚠️ Read this before installing

**This gives an AI agent a real shell on your machine, driven by your game's
chat box.** The tool filtering described below is a **speed bump, not a
sandbox** — it matches command spellings, and a shell has endless synonyms for
the same operation.

Assume that **anyone who can type `!` on your server can eventually run anything
as your user.** The Terraria server password is the only real boundary. Don't
run this on a public server, and don't run it on a machine where that outcome
would matter to you.

It is a toy. Treat it like one.

---

## What you need

| Requirement | Notes |
|---|---|
| Linux, `bash` 4+ | Uses `setsid`, `pgrep`, GNU `timeout`, GNU `grep -P` |
| [`tmux`](https://github.com/tmux/tmux) | How the server is kept alive |
| [`jq`](https://jqlang.github.io/jq/) | Used by the tests; the gate degrades without it |
| [`tsrv`](https://github.com/Solteris-Dev/tsrv) | The Terraria server wrapper this talks to |
| [Claude Code](https://claude.com/claude-code) | Installed **and logged in** |
| A running Terraria server **with a password set** | See `tsrv` |

### Cost and authentication

The bridge shells out to `claude -p` once per request, so **it uses whatever
Claude Code account you are already logged into on that machine** — your
subscription, at your normal limits. It does not read an API key and does not
create separate billing.

That also means **every `!` message consumes your usage**, and an agent that
decides to read a lot of files can consume a surprising amount in one request.
There is no spend cap built in. If that matters to you, don't leave it running
unattended.

## Setup

```bash
# 1. get and start the server (separate project)
git clone https://github.com/Solteris-Dev/tsrv.git
cd tsrv
cp serverconfig.example.txt serverconfig.txt   # SET A PASSWORD
./tsrv start

# 2. get the bridge
cd ..
git clone https://github.com/Solteris-Dev/terraria-beyond-sandboxing.git
cd terraria-beyond-sandboxing
./preflight.sh      # dependency and config check
./start.sh
```

`preflight.sh` checks the main dependencies (`claude`, `jq`, `tmux`, bash
version), that `tsrv` was found, and that the veto window is safely inside the
hook timeout. It does **not** verify every utility the scripts use (`setsid`,
`pgrep`, GNU `timeout`, `grep -P`, `realpath`), nor that your server actually
has a password set.

If `tsrv` lives somewhere unusual, or you use a different server wrapper:

```bash
export TSRV=/path/to/tsrv           # must support: reply, logpath
export SERVER_LOG=/path/to/server.log
```

`stop.sh` stops it.

## In-game usage

| You type | What happens |
|---|---|
| `!<anything>` | Sent to Claude Code; the answer is spoken back in chat |
| `!!!` | **Veto / interrupt** — denies a pending tool call, or aborts a running agent |

`!` must be the *first* character. `hi claude!` does not trigger it.

Replies are wrapped to ~115 characters because Terraria truncates long chat
lines, so a long answer arrives as several messages.

## Its own directory, on purpose

`claude --continue` resolves to the most recent session **in the working
directory**. Keeping the bridge in its own checkout keeps its thread separate
from your interactive sessions — neither can hijack the other. You can join the
conversation yourself:

```bash
cd /path/to/terraria-beyond-sandboxing && claude    # then /resume
```

Don't drive it from both sides at once.

## Threading

One shared thread for everyone, reused via `--continue`, rotating to a fresh
session after `IDLE_ROTATE` (4h default). Everyone shares context, so players
can see what each other asked.

## What the gate actually does

Three layers. Being precise here matters, because the previous version of this
section overclaimed and a reviewer caught it.

**1. The server password.** The real boundary. Player names are **not**
authenticated — the bridge uses them as labels, never as authorisation. Anyone
who can join can invoke the agent.

**2. `--disallowedTools`,** passed to the CLI on every run so it survives a
broken hook. It covers privilege escalation, root deletes, disk formatting and
power commands — **a subset** of what layer 3 catches. Hook-only rules (pipe-to-
shell, network config, persistence) are lost if the hook fails.

**3. The `PreToolUse` gate** (`hooks/gate.sh`), which sees every tool call:

- **Denied outright:** privilege escalation, recursive force deletes, raw disk
  writes, power-state changes, pipe-to-shell, network config, persistence, and
  writes outside the allowed roots. Write paths are canonicalised
  (`realpath -m`) before comparison, so `../` and existing symlinks are
  resolved rather than trusted. It is a static check, not a locked door: a
  symlink swapped between the check and the write would still win.
- **Silently allowed:** the `Read`/`Grep`/`Glob`/`WebSearch`/`WebFetch`/
  `TodoWrite` tools, exact `tsrv` read commands, and shell commands judged
  read-only — a fixed verb list (`ls`, `du`, `grep`, `cat`, …), `find`/`fd`
  without action flags, `sort`/`uniq` without an output file, and read-only
  `git` subcommands without writing flags. Anything with a shell operator
  (`; & | < > \` $ ( )`) is excluded outright.

  This classifier is **heuristic**. It has been wrong before — `git stash`,
  `sort -oFILE`, `git diff --output=`, `find -fprint0` and `fd --exec` all
  slipped through review rounds and are now regression-tested. Assume more
  exist.
- **Announced with a veto window:** everything else. You get
  `PENDING Bash: …` in chat and `VETO_WINDOW` seconds to type `!!!`.

### What layer 3 does *not* confine

The write-root check applies to Claude's **file tools only**. A shell command
that writes — `touch /tmp/x`, a redirect, `mv`, `git push` — is *announced*, not
blocked. If nobody vetoes in time, it runs. That is the design (otherwise the
agent can do nothing useful), but it means **the roots confine the file tools,
not the machine**.

### The fail-open trap

A `PreToolUse` hook that exceeds its timeout, crashes, or emits malformed JSON
renders **no decision, and the tool runs**. So `gate.sh` bounds every external
call, decides from an `EXIT` trap, and builds its JSON without needing `jq`.

Worst-case path through the gate is roughly 59s (input read, field parses, log
scan, announce, veto window, final scan, denial announce), against a **120s**
hook timeout in `.claude/settings.json`.

**If you raise `VETO_WINDOW`, raise that timeout too.** Otherwise the gate gets
killed mid-wait and silently becomes a rubber stamp. `preflight.sh` checks this.

## Tests

```bash
./tests/run-gate-tests.sh
```

59 cases, offline — no Terraria server needed, and broadcasts go to a stub
rather than a live game (an early version shouted a half-written `rm` command
into a live game mid-session; hence the stub).

Every hole found in review has a regression test: the `tsrv` substring bypass,
`../` root escapes, `sort -o` and `-oFILE`, `uniq IN OUT`, `git branch <name>`,
`git remote add`, `git stash`, `git diff --output=`, `find -delete`,
`find -fprint0`, `fd --exec`, and `env`/`command` as execution primitives.

## Config

All in `bridge.conf`, all auto-discovering. `TRUSTED_PLAYERS` is a label passed
to the prompt, **not** an access check.

| Key | Default |
|---|---|
| `TSRV` / `SERVER_LOG` | auto-discovered |
| `TRIGGER` / `VETO` | `!` / `!!!` |
| `VETO_WINDOW` | 15s |
| `IDLE_ROTATE` | 14400s (4h) |
| `ALLOWED_WRITE_ROOTS` | `$HOME/Games` |

## Files

| Path | Role |
|---|---|
| `bridge.sh` | Main loop: watch chat, dispatch, reply |
| `hooks/gate.sh` | PreToolUse veto gate |
| `preflight.sh` | Dependency and config check |
| `logs/gate.log` | Every tool decision — the audit trail |
| `logs/bridge.log` | Requests and replies |

## Licence

MIT.
