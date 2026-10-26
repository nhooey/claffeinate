# claffeinate

**Keep your Mac awake while Claude Code works, and let it sleep the moment
the work stops, even when a tab crashes.**

## The problem

You give Claude Code a long task and step away. A few minutes later macOS
decides you're idle and puts the Mac to sleep. The agent is suspended
mid-task, its network connections drop, and you come back to half-finished
work.

[`caffeinate(1)`][caffeinate-man], the macOS utility that keeps a Mac awake,
fixes that. But it doesn't know when the work is done:

- **It stays on too long.** A `caffeinate` started for a task keeps the Mac
  awake for a fixed time, or until someone stops it, long after the agent
  has answered.
- **Nothing says whose it is.** `ps` shows five `caffeinate` processes, and
  none of them says which session, or which part of its work, started it.
- **It outlives its session.** When a tab closes or crashes, its
  `caffeinate` keeps running. With the lid open on battery, that can mean a
  flat battery by morning.

Claude Code 2.1.302 runs a `caffeinate` of its own, but it doesn't close
these gaps. It runs `caffeinate -i -t 300`, which keeps the Mac awake for 5
minutes, and starts a new one every 4 minutes only while the session is
busy: while a turn, a subagent, a workflow or a teammate runs. Once it stops
being busy, the last one expires and the Mac can sleep:

- **mid-build**, when the turn has ended and only a background shell is left
- **while a permission prompt or question waits on you**

It also doesn't say which session holds the Mac awake, and has no cap and no
battery floor.

## What claffeinate does

claffeinate keeps the Mac awake only while something is working, through
**holds**. Each hold is for one thing:

| Holder     | Starts when                          | Ends when                  |
| ---------- | ------------------------------------ | -------------------------- |
| a turn     | you send a prompt                    | the agent's response is in |
| a subagent | the agent starts one                 | the subagent finishes      |
| a shell    | the agent starts a background `Bash` | the shell exits            |

A Monitor never holds the Mac awake. Every hold also ends by itself:

- when its `claude` process exits
- after `awake-max-duration`, 4 hours by default
- once the battery is down to `awake-min-battery`, 20% by default, on AC
  power too, since a battery can drain while plugged in

`claffeinate` is one command for the whole Mac. `status` shows every hold
of every session, and when the Mac will be allowed to sleep:

```
$ claffeinate status
claffeinate  2026-10-16 15:30  macOS 15.6.1  power=battery  holds=2
💤 sleep    19:18  +3h48m  by=time
⏳ time     19:18  +3h48m  cap=4h
🔋 battery  19:40  +4h10m  now=64% floor=20% rate=-11%/h
💻 macos    15:35  +5m     input=15:29(-40s) display=5m sleep=1m other=-

PID    SESSION   NAME                    HOLDER                         CLAUDE  STATE     STARTED          ENDS
31985  0f311c94  Claffeinate             💬 turn                        55504   🟢 alive  14:42    -48m    18:42  +3h12m  ⏳ time
32456  0f311c94  Claffeinate             🐚 shell-bmnsyo3e4             55504   🟢 alive  15:18    -12m    19:18  +3h48m  ⏳ time

STOPPED          SESSION   NAME                    HOLDER                         REASON            RAN
14:02    -1h28m  0f311c94  Claffeinate             💬 turn                        ✅ ended          1h02m
13:40    -1h50m  9a1e2b77  Converting project to…  🤖 subagent-a1ed03884b02ccded  🔋 battery        22m
```

It is a single Bash script for macOS. It needs nothing beyond macOS
built-ins, apart from `jq` for `--json` output and for the plugin's
subagent and shell holds; macOS 15 ships `jq`.

## Quick start

### 1. Install the Claude Code plugin

It needs macOS. In Claude Code:

```
/plugin marketplace add nhooey/claffeinate
/plugin install claffeinate@claffeinate
/reload-plugins
```

To check it worked, run `/claffeinate:status`: this session's turn should
have an `alive` hold, since running the command is itself a turn.

That's all it takes. The plugin's [hooks](https://code.claude.com/docs/en/hooks)
start and stop the holds:

| Hook event                       | claffeinate                                         |
| -------------------------------- | --------------------------------------------------- |
| `UserPromptSubmit`               | `start --holder turn`                               |
| `Stop`, `StopFailure`            | `stop --holder turn`                                |
| `SubagentStart`                  | `start --holder subagent-<agent_id>`                |
| `SubagentStop`                   | `stop --holder subagent-<agent_id>`                 |
| `PostToolUse`, background `Bash` | `start --holder shell-<task_id> --wait-pid <shell>` |
| `SessionEnd`                     | `kill-session`                                      |

No hook runs on an ordinary tool call, so tool calls cost nothing. On a
machine without `caffeinate`, such as Linux, the hooks do nothing.

The plugin also puts `claffeinate` on the agent's `PATH`, so you can ask
Claude about the holds. `/claffeinate:status` shows the status, and
`/claffeinate:set awake-max-duration 8h` changes a setting for this session
only.

**Updating.** Third-party marketplaces don't update by themselves unless
you turn that on under `/plugin` → Marketplaces. To update by hand:

```
/plugin marketplace update claffeinate
/plugin update claffeinate@claffeinate
/reload-plugins
```

Run `/reload-plugins` in every open session: a session keeps the hooks it
loaded until then. After updating from 0.2.0, `claffeinate kill-orphans`
stops 0.2.0's instances.

**Uninstalling.** Run `/plugin uninstall claffeinate@claffeinate`, then
`claffeinate kill-session` in a session that still has holds.

**Coming from manual hooks or a keep-awake skill.** Remove them first.
Claude Code runs a plugin's hooks and your own side by side, so hooks in
`~/.claude/settings.json` that call `claffeinate-hook.sh` would run twice.

### 2. Install the command, for your terminal

The plugin runs its own copy of the script. To use `status` and
`kill-orphans` from your shell, install the command too. With Nix:

```sh
nix profile install github:nhooey/claffeinate   # persistent
nix run github:nhooey/claffeinate -- --help     # try it once
```

The Nix package puts `jq` on `claffeinate`'s `PATH`. Keep the installed
command at the plugin's version: both read and write the same holds.

From a checkout, link the script onto your `PATH`:

```sh
ln -s "$PWD/bin/claffeinate" ~/bin/claffeinate
```

### 3. Reap what bugs leave behind

Every hold ends by itself, and a hold whose `claude` crashed ends within a
minute. `kill-orphans` is for what a bug leaves behind: a `caffeinate`
without its watcher, or a watcher without its `caffeinate`. Run it at shell
startup, in the background so the shell isn't slowed down. This works in
`~/.zshrc`, `~/.bashrc` or `~/.config/fish/config.fish`:

```sh
command -v claffeinate >/dev/null && claffeinate kill-orphans >/dev/null 2>&1 &
```

To see what it would stop first, run `claffeinate kill-orphans --dry-run`.

## Commands

Every command has its own help: `claffeinate COMMAND --help`, or
`claffeinate help COMMAND`. Any command takes `--no-emoji` or `--emoji`.

| Command                                         | What it does                                                               |
| ----------------------------------------------- | -------------------------------------------------------------------------- |
| `start [--holder H] [--wait-pid PID] [options]` | Start a hold, and print its watcher's PID.                                 |
| `stop [--holder H]`                             | End a hold, logged as `ended`. Exits 3 if there is none.                   |
| `status [--explain] [--stops N] [--json]`       | When the Mac may sleep, every hold, and the last stops.                    |
| `list [--json]`                                 | One tab-separated row per hold.                                            |
| `kill-session`                                  | End every hold of the session, logged as `killed`. Exits 3 if it has none. |
| `kill-orphans [--dry-run]`                      | End what nothing else will end.                                            |
| `config`, `config set`, `config unset`          | Show or change the settings.                                               |

`start`, `stop` and `kill-session` act on `$CLAUDE_CODE_SESSION_ID`'s session,
or `--session ID`; outside Claude Code the session is `none`. `start` takes
the claude process from `$CLAUDE_PID`, or `--claude-pid`.

### `start`

A holder has one hold: `start` for a holder that already has one prints
that hold's PID and does nothing else. The holder is `turn`,
`subagent-<id>`, `shell-<id>`, or `manual`, the default, for holds you start
by hand. A hold keeps the Mac from sleeping while you're away; the display
still turns off, unless you pass `--keep-display-on`.

| Option                          | Effect                                 |
| ------------------------------- | -------------------------------------- |
| `--wait-pid PID`                | ends the hold once PID exits           |
| `--awake-max-duration DURATION` | ends it after DURATION                 |
| `--awake-min-battery PERCENT`   | ends it once the battery is at PERCENT |
| `--keep-display-on`             | keeps the display on too               |

DURATION is a number with units, largest first: `30s`, `45m`, `1h30m`, `2d`.
A bare number is seconds. `--timeout` is now `--awake-max-duration`.

```sh
claffeinate start --keep-display-on --awake-max-duration 1h30m   # a presentation
claffeinate stop                                                 # done early
```

### `status`

`status` prints the same lines in the same order every time, with `-` for a
value that doesn't apply, so your eye learns where each value sits and two
readings show only what changed. Each moment is a clock time beside its
signed distance from now: `+3h12m` ahead, `-40s` behind, `+0s` now. A plain
length of time, such as `cap=4h` or `RAN`, never has a sign.

The four forecast lines:

| Line         | When                                                                                                               |
| ------------ | ------------------------------------------------------------------------------------------------------------------ |
| 💤 `sleep`   | the Mac is expected to sleep if you stay away; `by=` names the limit that decides it: `time`, `battery` or `macos` |
| ⏳ `time`    | `awake-max-duration` ends the last hold                                                                            |
| 🔋 `battery` | the battery reaches the lowest `awake-min-battery`, at its current drain; `none` on a Mac without one              |
| 💻 `macos`   | macOS would sleep if the last hold ended now                                                                       |

Each hold's `ENDS` is the earlier of its own two limits. It is an upper
bound: a hold usually ends sooner, when its holder does. `NAME` is the
session's name from its transcript: the last `/rename`, else the title
Claude Code generated.

`status --explain` adds the reasoning below, with this Mac's settings.
`status --json` has the same fields, with every moment as an epoch.

Emoji mark each line and state, always before the word, so `grep turn`
still works. Each is one wide code point, drawn 2 columns wide in every
terminal. `--no-emoji`, the `emoji = off` setting, or a locale that isn't
UTF-8 turns them off; each column keeps its width, so nothing moves.

### Settings

| Setting              | Default | Variable                         |
| -------------------- | ------- | -------------------------------- |
| `awake-max-duration` | `4h`    | `CLAFFEINATE_AWAKE_MAX_DURATION` |
| `awake-min-battery`  | `20`    | `CLAFFEINATE_AWAKE_MIN_BATTERY`  |
| `emoji`              | `on`    | `CLAFFEINATE_EMOJI`              |

The strongest layer wins:

1. the flag: `--awake-max-duration`, `--awake-min-battery`, `--emoji`
2. the session file, `~/.local/state/claffeinate/sessions/<session>.conf`,
   which `/claffeinate:set` writes
3. the variable, which Claude Code takes from the `env` of `--settings`,
   then `.claude/settings.json`, then `~/.claude/settings.json`, then from
   the environment it was started in
4. the config file, `~/.config/claffeinate/config`
5. the default

Both files hold `setting = value` lines. A hold keeps the settings it
started with; `claffeinate config` shows each value and its layer.

```sh
claffeinate config set --global awake-min-battery 30
```

### Scripting with `--json`

`list` and `status` take `--json`. It needs `jq`; without it they exit 4
and print nothing on stdout.

```sh
claffeinate list --json | jq '.[] | select(.alive | not)'
```

## How macOS decides to sleep

This Mac's power log, `pmset -g log`, on macOS 15.6.1, shows how a released
hold turns into sleep:

- **Releasing a hold restarts no timer.** A hold is a
  `PreventUserIdleSystemSleep` assertion; ending it only stops preventing
  sleep. macOS counts idle time from your last keyboard, mouse or trackpad
  input the whole time.
- **The display gates idle sleep.** While the display is on, powerd holds
  "Prevent sleep while display is on". The display turns off once you've
  been idle for `displaysleep` minutes of the current power source.
- **Then the Mac sleeps,** once you've also been idle for the `sleep`
  setting, unless another process holds an assertion: audio playing, a
  call, or another `caffeinate`.

So once the last hold ends, the Mac sleeps at the latest of: that moment,
your last input plus `displaysleep`, and your last input plus `sleep`. If
you've been away that long already, it sleeps within seconds. In the log: a
hold released at 23:05:25 with the display already off was followed by
sleep at 23:05:31; one released at 12:51:41 with the display on was
followed by sleep at 12:52:40, 5 seconds after the display turned off.

`status` reads these live: `pmset -g custom` for the settings,
`ioreg -c IOHIDSystem`'s `HIDIdleTime` for your last input, and
`pmset -g assertions` for other processes' assertions, named in `other=`.
They sit in one function, `macos_sleep_model`, the only part a port to
another OS would replace.

## How it works

### Holds

A hold is two processes, named with `exec -a` so `ps` shows what they're
for:

```
claffeinate-watch--<tag>            the watcher
caffeinate--claffeinate--<tag>      caffeinate -i -w <PID>, its child
```

The tag carries everything about the hold, so the process table is the
only registry:

```
session-<id>--holder-<holder>--claude-<pid>--max-<seconds>--floor-<percent>--at-<epoch>
```

`caffeinate -w` waits on the claude process for a turn or a subagent, and
on the shell for a background shell, so it ends the moment that process
exits. The watcher waits on its `caffeinate` and wakes every minute to
check the cap, the battery and the claude process. On `stop` it ends the
hold as `ended`, and on `kill-session` or `kill-orphans` as `killed`.

### The stop log

Each hold that stops writes one line to `~/Library/Logs/claffeinate.log`,
where Console.app lists it under Log Reports:

```
2026-10-16T14:02:00+0700 session=0f311c94-… holder=turn reason=ended ran=1h02m start=… stop=…
```

The reasons are `ended`, `claude-exited`, `cap`, `battery` and `killed`.
The log keeps its last 1,000 lines once it passes 2,000. A link at
`~/.local/state/claffeinate/claffeinate.log` points to it.

### Finding a background shell

A `PostToolUse` payload for a background `Bash` has its task id, but no
PID. The shell is the child of `claude` whose standard output is
`…/tasks/<task id>.output`; the hook finds it with `pgrep -P` and `lsof`.

### Parallel events

Hooks can fire together. Starts for one holder take turns through a lock,
so however many arrive together, the holder ends up with one hold.

### Without the plugin

The plugin is a set of hooks around `hooks/claffeinate-hook.sh`. To wire it
up by hand instead of installing the plugin, never as well as it, copy the
entries of `hooks/hooks.json` into `~/.claude/settings.json`, pointing at a
checkout. The script reads the hook's JSON payload on stdin, takes
`prompt`, `stop`, `subagent-start`, `subagent-stop`, `post-tool` and
`session-end`, and never fails or prints, so it can't interrupt the agent.

## Limits

- **A turn waiting on you is still a turn.** While Claude Code waits for you
  to approve a tool call, the Mac stays awake, up to the cap.
- **Notifications are short turns.** A task notification, a Monitor event
  or a subagent's report starts a turn of its own, and so a short hold.
- **Undocumented fields.** The shell hold relies on `backgroundTaskId`, the
  `tasks/<id>.output` path and `$CLAUDE_PID`, which Claude Code doesn't
  document. If they change, background shells get no hold, and nothing else
  breaks.
- **macOS only.** It wraps `caffeinate(1)` and reads `pmset` and `ioreg`. It
  needs Bash 3.2 or later, which macOS ships.

## Exit codes

| Code | Meaning                                       |
| ---- | --------------------------------------------- |
| 0    | Success                                       |
| 1    | Generic error                                 |
| 2    | Misuse: unknown command or flag, a bad value  |
| 3    | Nothing matched, such as `stop` with no hold  |
| 4    | `--json` requested, but `jq` is not installed |

## Development

```sh
tests/test.sh [TEST...]                # acceptance tests, or only those named
nix flake check                        # shellcheck and the tests
claude plugin validate --strict .      # the manifests (validate-plugin in the dev shell)
claude --plugin-dir . -p "…"           # try the plugin from this checkout
```

`--plugin-dir` takes over from an installed copy of the same plugin for
that session.

To release, raise `version` in `.claude-plugin/plugin.json`. Installed
copies only update when it changes, and the Nix package reads its version
from there too.

The tests run in their own directories, with made-up sessions and stand-in
claude processes, so they never touch your real holds; stubs for `ioreg`,
`pmset` and `sw_vers` pin the battery and the macOS settings.
[`SPECIFICATION.md`](SPECIFICATION.md) has the full contract.

[caffeinate-man]: https://ss64.com/mac/caffeinate.html
