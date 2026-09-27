# claffeinate

**Keep your Mac awake while Claude Code works, and let it sleep once the
work is done, even when a tab crashes.**

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

```sh
claffeinate start          # keep the Mac awake for this tab
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

### 1. Install

With Nix:

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

### 2. Have Claude Code start and stop it

Claude Code [hooks](https://code.claude.com/docs/en/hooks) run
inside the tab's environment, which is what claffeinate reads to tag an
instance. Add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "claffeinate start --idle >/dev/null" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "claffeinate kill-mine || true" }] }
    ]
  }
}
```

A tab that exits normally now cleans up after itself. `start` is safe to run
again: a tab that already has an instance keeps it.

### 3. Reap what crashed tabs leave behind

A tab that crashes, or a window closed without exiting, never runs its
`SessionEnd` hook. Reap those at shell startup, in the background so the
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
| `start [flags]`                | Keep the Mac awake for this tab. Prints the PID.                        |
| `list [--json]`                | One row per instance: PID, tab, SSE port, directory, `alive` or `dead`. |
| `status [--json]`              | `list`, plus the owning `claude` PID and uptime in seconds.             |
| `kill-mine`                    | Stop this tab's instance. Exits 3 if it has none.                       |
| `kill-orphans [--dry-run]`     | Stop every instance whose tab has closed.                               |
| `claude-pid --term-session-id ID --sse-port PORT` | Print the `claude` PID behind a tab. Exits 1 if none. |

### `start`

With no flags, `start` keeps the display from sleeping. The flags map to `caffeinate`'s own, and combine freely:

| Flag                 | Keeps…                                 | `caffeinate` |
| -------------------- | -------------------------------------- | ------------ |
| `--display`          | the display on (the default)           | `-d`         |
| `--idle`             | the system from idle sleep; the display may still turn off | `-i` |
| `--disk`             | the disk from idle sleep               | `-m`         |
| `--system`           | the system awake, on AC power only     | `-s`         |
| `--user`             | the user marked as active              | `-u`         |
| `--timeout DURATION` | it running for DURATION only           |              |

DURATION is a number with units, largest first: `30s`, `45m`, `1h30m`, `2d`.
A bare number is seconds.

```sh
claffeinate start --idle                 # screen can dim; the work goes on
claffeinate start --idle --timeout 2h    # and stop by itself after two hours
```

### Scripting with `--json`

`list` and `status` take `--json` and print an array of objects instead of
rows. It needs `jq`; without it they exit 4 and print nothing on stdout.

```sh
claffeinate status --json | jq '.[] | select(.alive) | {dir, uptime_seconds}'
```

## How it works

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

- **`--timeout`:** it exits once the timeout passes, and `caffeinate`
  exits with it.
- **A killed `caffeinate`:** the loop notices and exits too, so no loop is
  left running on its own.

`kill-orphans` also stops loops that lost their `caffeinate` before
claffeinate handled that case.

## Limits

- **Outside an IDE, every instance looks orphaned.** Claude Code sets
  `CLAUDE_CODE_SSE_PORT` only when it's connected to an IDE. Without it, an
  instance is tagged `noport`, no `claude` process can match it, and
  `kill-orphans` stops it even while its tab is working. If you run Claude
  Code in a plain terminal, rely on the `SessionEnd` hook and `--timeout`,
  and leave `kill-orphans` out of your shell startup.
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
tests/test.sh      # acceptance tests
nix flake check    # shellcheck and the tests
```

The tests use made-up tab IDs, so they don't touch your real instances. Two
of them need a live Claude Code tab connected to an IDE, and skip without
one. [`SPECIFICATION.md`](SPECIFICATION.md) has the full contract: every
function, behavior and test.

[caffeinate-man]: https://ss64.com/mac/caffeinate.html
