# claffeinate

**Keep your Mac awake while Claude Code works, and let it sleep once the
work stops, even when a tab crashes.**

## The problem

You give Claude Code a long task and step away. A few minutes later macOS
decides you're idle and puts the Mac to sleep. The agent is suspended
mid-task, its network connections drop, and you come back to half-finished
work.

[`caffeinate(1)`][caffeinate-man], the macOS utility that keeps a Mac awake,
fixes that. But once you run Claude Code in more than one tab, it causes
problems of its own:

- **Nothing says whose it is.** `ps` shows five `caffeinate` processes, and
  none of them says which tab started it.
- **It outlives its tab.** When a tab closes or crashes, its `caffeinate`
  keeps running, and the Mac stays awake until you notice. With the lid open
  on battery, that can mean a flat battery by morning.
- **The blunt fix breaks other tabs.** `killall caffeinate` stops the
  forgotten ones, and also the ones your other tabs are still using.

## What claffeinate does

claffeinate starts `caffeinate` on behalf of one Claude Code tab and names
the process after that tab. Every instance then answers two questions:
*which tab owns me?* and *is that tab still open?* That lets claffeinate
stop exactly the instances whose tab is gone, and leave the rest alone.

Each instance lasts 10 minutes, and each `start` replaces the tab's
instance with a fresh one. So when Claude Code runs `start` every time it
does something, the Mac stays awake while the agent works, and sleeps
normally once it has been quiet for 10 minutes.

```sh
claffeinate start          # keep the Mac awake for this tab, for 10 minutes
claffeinate list           # every instance, and whether its tab is open
claffeinate kill-orphans   # stop the ones whose tab has closed
```

```
$ claffeinate list
41822  w0t1p0:9C1E…  63342  api-server   alive
41907  w0t2p0:52AF…  63342  web-client   alive
38114  w0t4p0:D0B3…  63342  migrations   dead

$ claffeinate kill-orphans
killed 38114 caffeinate--claffeinate--tab-w0t4p0:D0B3…-63342--dir-migrations
```

It is a single Bash script for macOS. It needs nothing beyond macOS
built-ins, apart from `jq` for `--json` output.

## Quick start

### 1. Install the Claude Code plugin

In Claude Code:

```
/plugin marketplace add nhooey/claffeinate
/plugin install claffeinate@claffeinate
```

That's all it takes to keep the Mac awake while the agent works. The
plugin's [hooks](https://code.claude.com/docs/en/hooks) run claffeinate at
each step of the agent's work:

| When                                  | claffeinate                                 |
| ------------------------------------- | ------------------------------------------- |
| You send a prompt                     | awake for the next 10 minutes               |
| A tool call starts                    | awake until it ends, for up to 2 hours      |
| A tool call ends, or the turn ends    | awake for the next 10 minutes               |
| You exit Claude Code                  | stops this tab's instance                   |

So the Mac stays awake while the agent works, including through a long
build, and can sleep 10 minutes after it goes quiet. Each step takes about
70 ms, so the agent doesn't slow down. On a machine without `caffeinate`,
such as Linux, the hooks do nothing.

The plugin also puts `claffeinate.sh` on the agent's `PATH`, so you can
ask Claude which instances are running, or to stop one.

### 2. Install the command, for your terminal

The plugin runs its own copy of the script. To use `list`, `status` and
`kill-orphans` from your shell, install the command too. With Nix:

```sh
nix profile install github:nhooey/claffeinate   # persistent
nix run github:nhooey/claffeinate -- --help     # try it once
```

The Nix package puts `jq` on `claffeinate`'s `PATH`, so `--json` works with
no separate install.

From a checkout, link the script onto your `PATH` without its `.sh`:

```sh
ln -s "$PWD/bin/claffeinate.sh" ~/bin/claffeinate
```

### 3. Reap what crashed tabs leave behind

A tab that crashes, or a window closed without exiting, never runs its
`SessionEnd` hook. Its instance still runs out by itself: 10 minutes after
its last step, or up to 2 hours if it crashed during a tool call. To reap
those sooner, run `kill-orphans` at shell startup, in the background so the
shell isn't slowed down. This works in `~/.zshrc`, `~/.bashrc` or
`~/.config/fish/config.fish`:

```sh
command -v claffeinate >/dev/null && claffeinate kill-orphans >/dev/null 2>&1 &
```

To see what it would stop first, run `claffeinate kill-orphans --dry-run`.

## Commands

Every command has its own help: `claffeinate COMMAND --help`, or
`claffeinate help COMMAND`.

| Command                        | What it does                                                            |
| ------------------------------ | ----------------------------------------------------------------------- |
| `start [flags]`                | Keep the Mac awake for this tab, for 10 minutes. Prints the PID.        |
| `list [--json]`                | One row per instance: PID, tab, SSE port, directory, `alive` or `dead`. |
| `status [--json]`              | `list`, plus the owning `claude` PID and uptime in seconds.             |
| `kill-mine`                    | Stop this tab's instance. Exits 3 if it has none.                       |
| `kill-orphans [--dry-run]`     | Stop every instance whose tab has closed.                               |
| `claude-pid --term-session-id ID --sse-port PORT` | Print the `claude` PID behind a tab. Exits 1 if none. |

### `start`

With no flags, `start` keeps the display from sleeping for 10 minutes. A
tab has one instance: running `start` again replaces it, with the new flags
and a fresh timeout. The flags map to `caffeinate`'s own, and combine
freely:

| Flag                 | Keeps…                                 | `caffeinate` |
| -------------------- | -------------------------------------- | ------------ |
| `--display`          | the display on (the default)           | `-d`         |
| `--idle`             | the system from idle sleep; the display may still turn off | `-i` |
| `--disk`             | the disk from idle sleep               | `-m`         |
| `--system`           | the system awake, on AC power only     | `-s`         |
| `--user`             | the user marked as active              | `-u`         |
| `--timeout DURATION` | it running for DURATION, not 10m       |              |

DURATION is a number with units, largest first: `30s`, `45m`, `1h30m`, `2d`.
A bare number is seconds.

```sh
claffeinate start --idle                 # screen can dim; the work goes on
claffeinate start --idle --timeout 2h    # the same, for two hours instead
```

### Scripting with `--json`

`list` and `status` take `--json` and print an array of objects instead of
rows. It needs `jq`; without it they exit 4 and print nothing on stdout.

```sh
claffeinate status --json | jq '.[] | select(.alive) | {dir, uptime_seconds}'
```

## How it works

### Knowing the agent is working

claffeinate doesn't watch the agent. It relies on two signals, and each one
answers a different question:

- **Is the agent busy? Ask the hooks.** Claude Code runs the plugin's hooks
  when you send a prompt, around every tool call, and when a turn ends.
  Each one runs `start`, which replaces the tab's instance and so resets
  its deadline. While the agent is working, the deadline keeps moving. Once
  it goes quiet, the deadline arrives and the instance exits. No hook fires
  during a tool call, so the one before it allows up to 2 hours, and the
  one after it brings the deadline back to 10 minutes.
- **Is the tab still open? Ask the process table.** This decides what
  `list` shows as `dead` and what `kill-orphans` stops. It says nothing
  about whether the agent is busy: a tab left open at an idle prompt is
  still `alive`.

### Tagging

`start` runs `caffeinate` with its process name (`argv[0]`) set to a tag
that carries the tab's identity and the working directory's name:

```
caffeinate--claffeinate--tab-<TERM_SESSION_ID>-<CLAUDE_CODE_SSE_PORT>--dir-<basename of $PWD>
```

The tag starts with `caffeinate--`, so `pgrep caffeinate` and
`pgrep -f caffeinate` still find these processes. The tag is also kept as
a symlink under `/tmp/claffeinate/symlinks/`, and the PID in
`/tmp/claffeinate/<tag>.pid`.

### Deciding a tab is gone

An instance's tab is open if some running `claude` process has both its
`TERM_SESSION_ID` and its `CLAUDE_CODE_SSE_PORT` in its environment. It's
read with `ps -E`. Otherwise the instance is `dead`, and `kill-orphans`
stops it.

The check looks at the `claude` process, not at who is listening on the SSE
port. When Claude Code is connected to an IDE (JetBrains, VS Code), the IDE
holds that port, so a port check would take the IDE for Claude Code. If the
`claude` binary is ever renamed, change `CLAUDE_BIN_NAME` near the top of
`bin/claffeinate.sh`.

### The heartbeat

Each instance runs a small shell loop, which is the command `caffeinate`
keeps awake for. Once a minute it writes `awake` to
`/tmp/claffeinate/<tag>.log`. The loop is also what ends the instance:

- **The timeout:** it exits once the timeout passes, 10 minutes unless
  `--timeout` says otherwise, and `caffeinate` exits with it.
- **A killed `caffeinate`:** the loop notices and exits too, so no loop is
  left running on its own.

`kill-orphans` also stops loops that lost their `caffeinate` before
claffeinate handled that case.

### Parallel tool calls

When the agent runs several tools at once, their hooks run `start` at the
same moment. Starts in one tab take turns through a lock, so however many
arrive together, the tab ends up with exactly one instance.

### Without the plugin

The plugin is a set of hooks around `hooks/claffeinate-hook.sh`. To wire it
up by hand instead, point your own hooks in `~/.claude/settings.json` at a
checkout, with the event names from `hooks/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "bash ~/src/claffeinate/hooks/claffeinate-hook.sh pre-tool" }] }
    ]
  }
}
```

The script takes `prompt`, `pre-tool`, `post-tool`, `stop` and
`session-end`. It never fails and never prints, so it can't interrupt the
agent.

## Limits

- **A tool call gets up to 2 hours.** A single tool call that runs longer
  can outlast its instance. With parallel tool calls, the first one to
  finish brings the deadline back to 10 minutes while the others may still
  be running.
- **Outside an IDE, every instance looks orphaned.** Claude Code sets
  `CLAUDE_CODE_SSE_PORT` only when it's connected to an IDE. Without it, an
  instance is tagged `noport`, no `claude` process can match it, and
  `kill-orphans` stops it even while its tab is working. If you run Claude
  Code in a plain terminal, let the plugin's deadlines do the work, and
  leave `kill-orphans` out of your shell startup.
- **Terminals without `TERM_SESSION_ID`.** macOS Terminal, iTerm2 and
  JetBrains terminals set it; most SSH sessions don't. There the tag says
  `unknown`, and those instances are also treated as orphans.
- **macOS only.** It wraps `caffeinate(1)` and uses BSD `ps -E` and `pgrep`.
  It needs Bash 3.2 or later, which macOS ships.

## Exit codes

| Code | Meaning                                                  |
| ---- | -------------------------------------------------------- |
| 0    | Success                                                  |
| 1    | Generic error                                            |
| 2    | Misuse: unknown command or flag, missing argument        |
| 3    | Nothing matched, such as `kill-mine` with no instance    |
| 4    | `--json` requested, but `jq` is not installed            |

## Development

```sh
tests/test.sh                          # acceptance tests
nix flake check                        # shellcheck and the tests
claude plugin validate .               # the plugin and marketplace manifests
claude --plugin-dir . -p "…"           # try the plugin from this checkout
```

The tests use made-up tab IDs, so they don't touch your real instances. Two
of them need a live Claude Code tab connected to an IDE, and skip without
one. [`SPECIFICATION.md`](SPECIFICATION.md) has the full contract: every
function, behavior and test.

[caffeinate-man]: https://ss64.com/mac/caffeinate.html
