# `claffeinate` — implementation spec

A Bash script that keeps a Mac awake only while Claude Code is working, one
**hold** per thing that works: a turn, a subagent or a background shell.
Every hold also ends on its own: when its `claude` process exits, at a
duration cap and at a battery floor. `status` shows every hold on the Mac
and when the Mac will be allowed to sleep.

Single-file Bash script. macOS-only. Small functions, a dispatch table, and
the process table as the only registry of holds.

## Terms

- **Session:** a Claude Code conversation, by its `session_id`
  (`$CLAUDE_CODE_SESSION_ID`). Outside Claude Code it is `none`.
- **Holder:** what a hold is for, within a session: `turn`,
  `subagent-<agent_id>`, `shell-<backgroundTaskId>`, or `manual`.
- **Hold:** a watcher process and its `caffeinate` child. A holder has at
  most one.

## Constraints

- macOS Darwin only: `caffeinate`, `pmset`, `ioreg`, `sw_vers`, `ps`,
  `pgrep`, `lsof`.
- Bash 3.2+: no Bash 4 features. `${arr[@]}` on a possibly empty array is
  written `${arr[@]+"${arr[@]}"}`.
- `jq` is required for `--json`, which exits 4 without it, and for the hook
  to read its payload; without `jq` the hook keeps only the turn's hold.
- `set -euo pipefail` in the script. Never `| head` on a function's output
  under `pipefail`: the writer's SIGPIPE fails the pipeline.
- Processes are listed with `ps -A -ww -o pid=,ppid=,command=`, once per
  command (`load_procs`). Without `-ww`, `ps` truncates long command lines.

## The hold

```text
claffeinate-watch--<tag>          bash bin/claffeinate __watch <tag> <flags> <target>
caffeinate--claffeinate--<tag>    caffeinate -<flags> [-w <target>]
```

Both names are set with `exec -a`. The tag:

```text
session-<sid>--holder-<holder>--claude-<pid>--max-<seconds>--floor-<percent>--at-<epoch>
```

- `<sid>` and `<holder>` match `^[A-Za-z0-9_.-]+$` and never contain `--`.
- `claude-0` means no claude process to watch; `floor-0` means no battery
  floor.
- The settings in force at `start` are in the tag, so a later change never
  moves a running hold.
- A watcher is a process whose `argv[0]` starts with `claffeinate-watch--`
  **and whose parent isn't one**: a watcher's own forks (its timer, the
  subshell before `exec caffeinate`) carry its argv until they exec.
- The target of `-w` is `--wait-pid` if given, else the claude PID, else
  none.
- 0.2.0's tagged caffeinates had a symlink directory before the name; the
  pattern `^(/[^ ]*/)?caffeinate--claffeinate--` matches both.

### The watcher (`cmd_watch`)

1. Start `caffeinate` as a background child, and trap `USR1` as `ended`,
   `TERM` and `INT` as `killed`, `USR2` as a wake-up; ignore `HUP`.
2. Loop:
   - the `caffeinate` is gone: `claude-exited` if the claude PID is gone
     too, else `ended`
   - the claude PID is gone: `claude-exited`
   - `now >= at + max`: `cap`
   - the floor is above 0, a battery is present, and `CurrentCapacity <=
     floor`: `battery`, on AC power too
   - otherwise start a timer `(sleep N && kill -USR2 $$) &`, with N the
     lesser of the interval (`$CLAFFEINATE_WATCH_INTERVAL`, default 60) and
     the time left to the cap, and `wait` on the `caffeinate`: it returns
     when the `caffeinate` exits or a trapped signal arrives
3. Kill the `caffeinate`, write the stop log line, exit 0.

## CLI surface

```
claffeinate start [--holder H] [--session ID] [--claude-pid PID] [--wait-pid PID]
                  [--awake-max-duration DURATION] [--awake-min-battery PERCENT]
                  [--keep-display-on]
claffeinate stop [--holder H] [--session ID]
claffeinate status [--explain] [--stops N] [--json|-j]
claffeinate list [--json|-j]
claffeinate kill-session [--session ID]
claffeinate kill-orphans [--dry-run|-n]
claffeinate config [--session ID]
claffeinate config set (--session ID | --global) SETTING VALUE
claffeinate config unset (--session ID | --global) SETTING
claffeinate help [COMMAND]
```

`--no-emoji` and `--emoji` are accepted anywhere. `COMMAND --help` and
`help COMMAND` print the same text, starting `Usage: claffeinate COMMAND`.
An unknown flag exits 2 naming `claffeinate COMMAND --help`.

| Command        | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `start`        | Under a per-holder lock, print the holder's existing watcher PID, or start a hold, wait up to 2 s for its `caffeinate`, and print the watcher's PID. Holder defaults to `manual`, session to `$CLAUDE_CODE_SESSION_ID` or `none`, claude PID to `$CLAUDE_PID` or 0. Flags are `-i`, or `-di` with `--keep-display-on`. A target that isn't running is an error. `--timeout` exits 2 naming `--awake-max-duration`, and `--display` naming `--keep-display-on`; `--idle`, `--disk`, `--system` and `--user` exit 2. |
| `stop`         | Send `USR1` to the holder's watcher. Exit 3 if none.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `kill-session` | Send `TERM` to every watcher of the session. Exit 3 if none.                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `kill-orphans` | Stop: a watcher whose claude PID is gone; a watcher with no `caffeinate` child, once older than 5 s; a tagged `caffeinate` whose parent isn't a watcher, logged as `killed`; a 0.2.0 heartbeat loop. Delete a session file whose `claude-pid` is gone. Print `killed PID NAME (WHY)` or `deleted FILE (WHY)`; `--dry-run` prints `would …` and changes nothing.                                                                                                                                                    |
| `list`         | `PID SESSION HOLDER CLAUDE_PID alive\|dead STARTED MAX FLOOR`, tab-separated. `dead`: no `caffeinate`, or the claude PID is gone.                                                                                                                                                                                                                                                                                                                                                                                  |
| `status`       | Below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `config`       | Each setting's value and layer, then the session file, config file and log paths. `set` validates the value; `set`/`unset` on a session also record `claude-pid = $CLAUDE_PID`.                                                                                                                                                                                                                                                                                                                                    |

Durations: a bare number of seconds, or `<n>d<n>h<n>m<n>s` parts in that
order, total above 0. Battery: an integer 0–100.

## Settings

`awake-max-duration` (4h), `awake-min-battery` (20), `emoji` (on). Layers,
strongest first, in `resolve_setting`:

1. the flag
2. `$CLAFFEINATE_STATE_DIR/sessions/<sid>.conf`
3. `CLAFFEINATE_AWAKE_MAX_DURATION`, `CLAFFEINATE_AWAKE_MIN_BATTERY`,
   `CLAFFEINATE_EMOJI` (Claude Code fills these from `--settings`, project
   and user `settings.json` `env`, then the launch environment)
4. `$CLAFFEINATE_CONFIG`, default `$XDG_CONFIG_HOME/claffeinate/config`
5. the default

Files hold `setting = value` lines, `#` comments, last one wins, parsed
with `awk` and never sourced. A bad value in layers 2–4 warns on stderr and
falls through; a bad flag exits 2.

## Paths

| Variable                     | Default                                            |
| ---------------------------- | -------------------------------------------------- |
| `CLAFFEINATE_RUN_DIR`        | `/tmp/claffeinate-$UID/` (locks)                   |
| `CLAFFEINATE_STATE_DIR`      | `${XDG_STATE_HOME:-~/.local/state}/claffeinate`    |
| `CLAFFEINATE_CONFIG`         | `${XDG_CONFIG_HOME:-~/.config}/claffeinate/config` |
| `CLAFFEINATE_LOG`            | `~/Library/Logs/claffeinate.log`                   |
| `CLAUDE_CONFIG_DIR`          | `~/.claude` (transcripts, for `NAME`)              |
| `CLAFFEINATE_WATCH_INTERVAL` | `60`                                               |
| `CLAFFEINATE_NOW`            | the current time, for `status` (tests)             |

The log is in `~/Library/Logs` because Console.app lists files there but
doesn't follow a symlink placed there; `$STATE_DIR/claffeinate.log` links to
it, created on the first write.

## The stop log

One line per stopped hold, appended with a single `printf >>`:

```text
<ISO 8601 time> session=<sid> holder=<holder> reason=<reason> ran=<duration> start=<epoch> stop=<epoch>
```

Reasons: `ended`, `claude-exited`, `cap`, `battery`, `killed`. When the
file passes 2,000 lines it is cut to its last 1,000.

## `status`

### Inputs

- `read_battery`, from `ioreg -rn AppleSmartBattery`: `CurrentCapacity`
  (%), `AppleRawCurrentCapacity` and `AppleRawMaxCapacity` (mAh), `Amperage`
  (mA; printed unsigned, wrapped back to negative by Bash arithmetic),
  `ExternalConnected`, `BatteryInstalled`. No battery: a desktop.
- `macos_sleep_model`, the only OS-specific part:
  - the power source from `pmset -g batt`
  - that source's `displaysleep` and `sleep` from `pmset -g custom` (0 is
    never)
  - the last input, `now − HIDIdleTime / 10⁹`, from `ioreg -c IOHIDSystem`
  - `other`: `NAME:PID` of every process in `pmset -g assertions`' "Listed
    by owning process" with `PreventUserIdleSystemSleep`,
    `PreventSystemSleep`, `PreventUserIdleDisplaySleep`,
    `NoIdleSleepAssertion` or `NoDisplaySleepAssertion`, except `powerd`
    (its display-on assertion is modeled) and the holds' own `caffeinate`s

### The forecast

- `battery_end(floor)`: now if `CurrentCapacity <= floor`; nothing if not
  draining (`Amperage >= 0`); else `now + (cur·100 − floor·max)·36 ÷ −amp`
  seconds.
- Each hold ends at the earlier of `at + max` (`time`) and
  `battery_end(its floor)` (`battery`).
- `time`: the latest `at + max`; `cap=` that hold's max, or the setting with
  no holds.
- `battery`: `battery_end` of the lowest floor; `-` with no holds or no
  drain; details `now=P% floor=F% rate=-R%/h`, `rate=0` with no drain,
  `floor=off` at 0, `none` without a battery.
- `macos_sleep_at(T)`: the latest of `T`, `input + displaysleep` and
  `input + sleep`; nothing while `other` is set or either setting is never.
- `macos`: `macos_sleep_at(now)`.
- `sleep`: with holds, `macos_sleep_at(last hold's end)`, `by=` that hold's
  limit unless macOS comes later or never (`by=macos`); with none, `macos`.

### Output

The same lines, in the same order, every time:

```text
claffeinate  <YYYY-MM-DD HH:MM>  macOS <version>  power=<AC|battery|UPS>  holds=<n>
💤 sleep    <clock>  <rel>  by=<time|battery|macos>[ other=<list>]
⏳ time     <clock>  <rel>  cap=<duration>
🔋 battery  <clock>  <rel>  <battery details>
💻 macos    <clock>  <rel>  input=<clock>(<rel>) display=<d> sleep=<d> other=<list|->

PID  SESSION  NAME  HOLDER  CLAUDE  STATE  STARTED <clock> <rel>  ENDS <clock> <rel>  <by>
(none)

STOPPED <clock> <rel>  SESSION  NAME  HOLDER  REASON  RAN
(none)
```

- A moment is a clock time, `HH:MM`, or `MM-DD HH:MM` when not today,
  beside its distance from now, always signed: `+3h12m`, `-40s`, `+0s`. A
  duration is never signed: `40s`, `5m`, `1h02m`, `4h`, `2d03h`. Unknown or
  not applicable: `-`.
- Columns are padded to the widest cell, with a minimum width per column,
  so the shape doesn't change between readings; `(none)` takes no part in
  the widths.
- `SESSION` is the first 8 characters of the session id. `NAME` is the last
  `custom-title` record of `$CLAUDE_CONFIG_DIR/projects/*/<sid>.jsonl`,
  else its last `ai-title`, else `-`, cut to 22 characters with `…`.
- Stops are the log's last N lines (`--stops`, default 5), newest first.
- `--explain` appends how macOS decides to sleep, with the live values.
- `--json`: `now`, `power`, `sleep`, `time`, `battery`, `macos`, `holds`,
  `stops`, every moment as `{at, in}` or `null`.

### Emoji

`emoji_for` holds every emoji: 💤 ⏳ 🔋 💻 for the forecast lines; 🟢 🔴 for
`alive` and `dead`; 💬 🤖 🐚 ✋ for `turn`, `subagent`, `shell`, `manual`; ✅ ⏳
🔋 🚪 🧹 for `ended`, `cap`, `battery`, `claude-exited`, `killed`. Each is
one code point with `East_Asian_Width=W` and `Emoji_Presentation=Yes`: no
variation selector, so every terminal draws it 2 columns wide. Text-default
symbols such as ⚠, ⏱ and 🖥 are excluded.

An emoji always precedes its word. A marked cell is drawn 3 columns wider
than its word whether emoji are on or off, so turning them off moves no
column. They are off with `--no-emoji`, the `emoji = off` setting, or a
locale (`LC_ALL`, `LC_CTYPE`, `LANG`) that isn't UTF-8. Widths are measured
with `LC_ALL=en_US.UTF-8` either way.

## Claude Code plugin

- `.claude-plugin/plugin.json`: the manifest; `version` is the single
  version, read by the Nix package too.
- `.claude-plugin/marketplace.json`: a marketplace named `claffeinate` with
  one plugin whose `source` is `./`.
- `hooks/hooks.json`: one command hook per event, each
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/claffeinate-hook.sh" ACTION`, 15-second
  timeout; `PostToolUse` matches `Bash` only.
- `hooks/claffeinate-hook.sh ACTION`: reads the JSON payload on stdin, and
  runs `bin/claffeinate` beside it with stdin, stdout and stderr detached.
  It never fails or prints, and does nothing unless `uname -s` is `Darwin`
  and `caffeinate` is on `PATH`. The session comes from the payload's
  `session_id`, else `$CLAUDE_CODE_SESSION_ID`; the claude PID from
  `$CLAUDE_PID`.
- `skills/status/SKILL.md`: `/claffeinate:status`, user-invoked.
- `skills/set/SKILL.md`: `/claffeinate:set SETTING VALUE`, user-invoked;
  runs `claffeinate config set --session "$CLAUDE_CODE_SESSION_ID"`.
- `bin/` is on the agent's Bash `PATH` while the plugin is enabled.

| Hook event             | ACTION           | Action                                                                                                                |
| ---------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------- |
| `UserPromptSubmit`     | `prompt`         | `start --holder turn`                                                                                                 |
| `Stop`, `StopFailure`  | `stop`           | `stop --holder turn`                                                                                                  |
| `SubagentStart`        | `subagent-start` | `start --holder subagent-<agent_id>`                                                                                  |
| `SubagentStop`         | `subagent-stop`  | `stop --holder subagent-<agent_id>`                                                                                   |
| `PostToolUse` (`Bash`) | `post-tool`      | if `tool_input.run_in_background` is true: `start --holder shell-<tool_response.backgroundTaskId> --wait-pid <shell>` |
| `SessionEnd`           | `session-end`    | `kill-session`                                                                                                        |

The shell's PID: the child of `$CLAUDE_PID` (`pgrep -P`) whose fd 1, by
`lsof -a -p <children> -d 1 -Fpn`, ends in `/tasks/<task id>.output`,
retried for up to a second. A Monitor's stdout is a pipe, so it never
matches; the `Monitor` tool also has its own `tool_name`.

## Acceptance tests

`tests/test.sh [NAME...]` runs every test, or only those named. Each prints
`PASS`, `FAIL: reason` or `SKIP: reason`; it exits non-zero on any FAIL.
Every test runs in its own directories with its own session ids and
stand-in claude processes (`/bin/sleep` renamed `fake-claude`), with a
1-second watch interval. Stubs for `ioreg`, `pmset` and `sw_vers` pin the
battery, idle time, power settings and assertions. Tests that start
processes skip where `/bin/sleep` or `ps` can't run, as in a sandboxed Nix
build.

| Test                          | Checks                                                                                  |
| ----------------------------- | --------------------------------------------------------------------------------------- |
| `start_and_stop`              | the watcher and `caffeinate -i -w <claude>` named for the tag; `stop` ends it as `ended`; a second `stop` exits 3 |
| `start_repeat_noop`           | a second `start` prints the same PID, one hold                                          |
| `start_concurrent`            | 8 simultaneous starts leave one hold and no lock                                        |
| `subagent_outlives_turn`      | stopping the turn leaves the subagent's hold                                            |
| `wait_pid_ends_hold`          | a shell hold ends with its shell, as `ended`                                            |
| `claude_exit_ends_hold`       | a hold ends with its claude, as `claude-exited`                                         |
| `cap_ends_hold`               | a 2 s cap ends the hold, as `cap`                                                       |
| `battery_floor_ends_hold`     | at 15% on AC, a 20% floor ends its hold as `battery`, a 10% floor doesn't               |
| `kill_session`                | ends the session's holds as `killed`, not another session's; exits 3 with none          |
| `kill_orphans`                | each orphan kind and a dead session file; `--dry-run` stops nothing; a live hold is untouched |
| `config_precedence`           | default, config, variable, session and flag in order; a bad variable warns and falls through; `set` needs a layer and a valid value; the tag records what applied |
| `start_rejects_bad_values`    | bad durations, floors, holders, sessions and PIDs exit 2; `--timeout` names its successor |
| `per_command_help`            | every command's `--help`, `help COMMAND` and unknown flag                               |
| `json_parses`                 | `list --json` and `status --json` parse, with the hold and the macOS block              |
| `json_without_jq_fails`       | exit 4 naming `jq`                                                                      |
| `emoji_are_terminal_safe`     | every `emoji_for` entry is one wide `So` code point                                     |
| `status_shape`                | the exact output, with no holds, from stubs, a fixture log and transcripts; `--no-emoji` and a C locale keep every line's width |
| `status_macos_model`          | display on, display off, another app's assertion, no battery                            |
| `status_forecast`             | a cap before the battery gives `by=time`; a faster drain gives `by=battery`             |
| `log_trim`                    | a log past 2,000 lines keeps its last 1,000; the state directory links to it            |
| `hook_events`                 | prompt, subagent start and stop, stop, session-end; a Monitor or foreground Bash gets no hold; silent |
| `hook_background_shell`       | a background Bash gets a hold waiting on the shell writing `tasks/<id>.output`, ending with it |
| `hook_noop_without_caffeinate`| silent no-op without `caffeinate`, or off Darwin                                        |
| `hooks_json_structure`        | every event known and present, every action handled, timeouts ≥ 15 s, `PostToolUse` matches `Bash` |
| `non_macos_error`             | off macOS, `start` exits 1 with the macOS error and `start --help` works                |

## Out of scope

- Replacing `caffeinate` with direct `IOPMAssertion*` calls.
- A daemon: each hold's watcher lives only as long as its hold.
- Anything cross-platform. Off macOS, every command but help exits 1 with
  `error: claffeinate needs macOS caffeinate(1)`. A port replaces
  `macos_sleep_model` and `read_battery` (Linux: `systemd-inhibit`,
  logind's `IdleActionSec`, `/sys/class/power_supply`).
