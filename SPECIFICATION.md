# `claffeinate` — implementation spec

A Bash script that starts/lists/kills `caffeinate` instances tagged with the Claude
Code tab that owns them, so multi-tab workflows can detect and reap orphans
without killing each other's instances.

Single-file Bash script. macOS-only. Functional/declarative style: small pure
functions, no mutable globals beyond constants, idempotent operations, composable
via pipes.

## Naming

The project, the script, and the runtime directory in `/tmp` all share the
single name **`claffeinate`** (Claude + caffeinate).

A note on the term *session*: Claude Code already uses `session_id` for its
own conversation-session UUID (see `--session-id` / `CLAUDE_SESSION_ID`).
To avoid collision, this spec uses **`claude_tab_id`** for the
`<TERM_SESSION_ID>-<CLAUDE_CODE_SSE_PORT>` pair that uniquely identifies one
Claude Code instance — i.e. one terminal tab running Claude Code.

## Constraints

- macOS Darwin only — uses `caffeinate`, `pmset`, BSD `ps -E`.
- Bash 3.2+ (don't require Bash 4 features; macOS ships 3.2 by default).
- Zero external deps beyond coreutils + macOS built-ins (`pgrep`, `pkill`, `ps`,
  `lsof`, `caffeinate`, `mktemp`, `ln`, `basename`).
- `jq` is required **only** when `--json` is requested. If `--json` is used and
  `jq` is not on `PATH`, the script must exit with a clear error (do not fall
  back to a hand-rolled JSON encoder).
- `set -euo pipefail` at the top. Every function returns its result via stdout +
  exit status; no shared mutable state.

## Style rules (functional / declarative)

- **One function per concept.** No 100-line `main`; the entrypoint is a dispatch
  table from subcommand → function.
- **Pure where possible.** Detection functions read state (env, process table)
  and write to stdout — never mutate. Only `cmd_start`, `cmd_kill_mine`,
  `cmd_kill_orphans` mutate process state.
- **No globals except readonly config.** `readonly TAG_PREFIX=...`,
  `readonly RUN_DIR=...`, `readonly TAG_DIR=...`. Anything else is a `local`
  inside a function or piped through stdin/stdout.
- **One instance per tab.** Running `start` twice in the same tab: the
  second call replaces the first instance, taking the new flags and a
  fresh timeout, and leaves exactly one instance running.
- **Composable output.** `list` emits one line per instance, tab-separated, suitable
  for `awk`/`cut`. A `--json` flag on `list` and `status` for machine consumption.
- **No `set -e` traps for control flow.** Use explicit `||` and `if` for
  expected-failure paths.

## CLI surface

Long options are canonical and used throughout this spec, the README, the
`--help` output, and every example. Short options are accepted as aliases
but never appear in documentation.

```
claffeinate start [--display|--idle|--disk|--system|--user|--timeout DURATION]...   # default: --display
claffeinate list   [--json]
claffeinate status [--json]
claffeinate kill-mine
claffeinate kill-orphans [--dry-run]
claffeinate claude-pid --term-session-id ID --sse-port PORT
claffeinate help [COMMAND]
claffeinate [--help]
claffeinate COMMAND --help
```

Help is per command. `claffeinate --help` (or `help`, or no arguments) prints
an overview: a one-line summary of each command and the exit codes.
`claffeinate COMMAND --help` and `claffeinate help COMMAND` print the same
text for that command: its synopsis, what it does, its options and, where
useful, examples. Help goes to stdout and exits 0; `start --help` starts
nothing. An unknown flag exits 2 with
`error: unknown flag for COMMAND: FLAG (see 'claffeinate COMMAND --help')`.

Short option aliases (accepted; not used in docs):

| Long                     | Short  | Subcommand      | Notes                              |
| ------------------------ | ------ | --------------- | ---------------------------------- |
| `--display`              | `-d`   | `start`         | translates to `caffeinate -d`      |
| `--idle`                 | `-i`   | `start`         | translates to `caffeinate -i`      |
| `--disk`                 | `-m`   | `start`         | translates to `caffeinate -m`      |
| `--system`               | `-s`   | `start`         | translates to `caffeinate -s`      |
| `--user`                 | `-u`   | `start`         | translates to `caffeinate -u`      |
| `--timeout DURATION`     | `-t`   | `start`         | heartbeat exits after DURATION (default 10m) |
| `--json`                 | `-j`   | `list`/`status` | JSON output via `jq` (required)    |
| `--dry-run`              | `-n`   | `kill-orphans`  | only print what would be killed    |
| `--term-session-id ID`   | (none) | `claude-pid`    | required                           |
| `--sse-port PORT`        | (none) | `claude-pid`    | required                           |
| `--help`                 | `-h`   | (any)           | print that command's help, exit 0  |

`caffeinate(1)` itself does not understand long options; the script translates
long → short before exec'ing the symlink. Default to `--display` if no flag
is given to `start`.

Exit codes:

- `0` success
- `1` generic error
- `2` misuse (unknown command, unknown flag, missing required arg)
- `3` nothing matched (e.g., `kill-mine` with no instance for this tab)
- `4` `--json` requested but `jq` is not installed

## Tag format

Each instance is launched via a uniquely-named symlink to `caffeinate` so the tag
is the binary name in `ps`:

```
caffeinate--claffeinate--tab-<TERM_SID>-<SSE_PORT>--dir-<basename(PWD)>
```

- `<TERM_SID>` = `${TERM_SESSION_ID:-unknown}`
- `<SSE_PORT>` = `${CLAUDE_CODE_SSE_PORT:-noport}`
- The leading `caffeinate--` prefix is intentional: it preserves substring
  matching for `pgrep caffeinate` and `pgrep -f caffeinate`. The project name
  `claffeinate` does **not** contain `caffeinate` as a substring (the `l`
  breaks it), so the prefix carries that responsibility.
- `${RUN_DIR}` = `/tmp/claffeinate/` — the runtime directory, named after
  the script.
- `${TAG_DIR}` = `${RUN_DIR}symlinks/` — holds the per-instance symlinks
  to `$(command -v caffeinate)`.
- Pidfile: `${RUN_DIR}<full-tag-name>.pid` (one per instance).

## Function inventory (required signatures)

Each function below has a fixed contract. Implement exactly these — the dispatch
table and tests assume these names and behaviors.

### Pure detection (no side effects)

```
claude_tab_id     ()                             -> echoes "<TERM_SID>-<SSE_PORT>"
current_tag       ()                             -> echoes full tag string for THIS tab
parse_tag         (tag)                          -> echoes "<TERM_SID> <SSE_PORT> <DIR_BASENAME>"
list_tagged_pids  ()                             -> one PID per line, all matching tag prefix
tag_for_pid       (pid)                          -> echoes the tag (argv[0] basename); empty if none
claude_pid_for    (term_sid, sse_port)           -> echoes claude PID; exit 1 if none
tab_is_alive      (term_sid, sse_port)           -> exit 0 alive, 1 dead; no stdout
stop_instance     (heartbeat_pid)                -> stops that heartbeat and its tagged caffeinate;
                                                    no-op unless the PID is still a heartbeat
lock_tag          (lock_path)                    -> takes the tab's start lock: `ln -s $$ lock_path`,
                                                    retrying every 0.05 s; takes over a lock whose
                                                    holder PID is dead; exit 1 after ~10 s
unlock_tag        (lock_path)                    -> removes the lock if this process holds it
ps_env            (pid)                          -> echoes env line from `ps -E`, stderr suppressed
require_jq        ()                             -> exit 4 with a clear message if `jq` not on PATH
```

### Mutation (subcommand bodies)

```
cmd_start         (caffeinate_flags...)          -> spawns one instance, replacing this tab's; prints PID
cmd_list          (--json?)                      -> table or JSON of {pid, tag, tab, dir, alive}
cmd_status        (--json?)                      -> like list but also includes claude PID + uptime
cmd_kill_mine     ()                             -> kills the instance owned by THIS tab
cmd_kill_orphans  (--dry-run?)                   -> kills all instances whose Claude tab is dead
cmd_claude_pid    (--term-session-id, --sse-port) -> echoes claude PID; exit 1 if none
```

### Help

```
usage             ()                             -> overview: commands and exit codes
usage_<command>   ()                             -> one per command, e.g. usage_kill_orphans
cmd_help          (command?)                     -> usage or usage_<command>; exit 2 if unknown
unknown_flag      (command, flag)                -> prints the error pointing at COMMAND --help
```

### Dispatch

```
main (args...) -> case "$1" in start) cmd_start "${@:2}";; ... esac
```

## Behavior detail

### `cmd_start`

1. Parse the long-and-short caffeinate flags (`--display|-d`, `--idle|-i`,
   `--disk|-m`, `--system|-s`, `--user|-u`, `--timeout DURATION|-t DURATION`); accept
   any combination. Default to `--display` if none given. DURATION is a bare
   number of seconds or `<number><unit>` parts in d/h/m/s order (`30s`,
   `60m`, `1h30m`, `2d`), converted to seconds by `duration_to_seconds`;
   anything else, or a zero total, exits 2. Without `--timeout`, the timeout
   is `DEFAULT_TIMEOUT` (`10m`), so every instance ends by itself.
2. Compute `tag=$(current_tag)`. Take the tab's lock,
   `lock_tag "${RUN_DIR}${tag}.lock"`, and exit 1 if it can't be had. The
   plugin's hooks fire together when the agent runs tools in parallel, and
   unserialized starts would each spawn an instance and lose track of one.
3. Read the previous instance's heartbeat PID from `${RUN_DIR}${tag}.pid`,
   if there is one.
4. Ensure `${RUN_DIR}` and `${TAG_DIR}` exist (`mkdir -p`); create symlink
   `${TAG_DIR}${tag} -> $(command -v caffeinate)`.
5. Translate the parsed long flags back to caffeinate's short forms and exec
   the symlink in background with those flags plus a heartbeat:
   `sh -c '<heartbeat>' sh "$TAG_DIR" "$timeout"`, where the heartbeat prints
   `[%s] awake (full-dir=%s)` every 60 sec. caffeinate(1) forks: the original
   process execs the heartbeat and the tagged caffeinate stays behind as its
   child, exiting when the heartbeat does. So the heartbeat:
   - ends itself once `$timeout` seconds have passed, because caffeinate
     ignores `-t` when given a utility, and `-t` is not passed;
   - ends itself once it has no child whose argv contains `$TAG_DIR`
     (`pgrep -q -P $$ -f`), since killing only the caffeinate would otherwise
     leave it running under launchd until reboot.
6. Write PID to `${RUN_DIR}${tag}.pid`. Echo the PID.
7. Stop the previous instance with `stop_instance`. The new instance starts
   first, so the Mac is never left without an assertion in between. Because
   each `start` restarts the timeout, a caller that runs `start` on every
   bit of agent activity (the README's Claude Code hooks) keeps the Mac
   awake until the agent has been quiet for the timeout. Release the lock.

### `cmd_list`

For each PID from `list_tagged_pids`:

- Resolve tag via `tag_for_pid`.
- Parse via `parse_tag`.
- Determine alive state via `tab_is_alive`.
- Emit `<pid>\t<term_sid>\t<sse_port>\t<dir>\t<alive|dead>`.

`--json` emits a JSON array via `jq`. Call `require_jq` first; if `jq` is
absent, exit 4 with a clear message (`error: --json requires jq; install with 'brew install jq'`).
Build the array by piping the tab-separated rows through
`jq -R 'split("\t") | {pid, term_sid, sse_port, dir, alive} | …' | jq -s '.'`
(or equivalent). Do **not** ship a hand-rolled JSON encoder.

### `cmd_status`

Same as `cmd_list` plus columns: `<claude_pid_or_->\t<uptime_seconds>`.

Uptime via `ps -p <pid> -o etime=`; convert `[[dd-]hh:]mm:ss` to seconds in a
helper `etime_to_seconds`. JSON output uses `jq` with the same `require_jq`
gate.

### `cmd_kill_mine`

1. `tag=$(current_tag)`.
2. If `${RUN_DIR}${tag}.pid` exists, `kill $(cat ${RUN_DIR}${tag}.pid)`;
   otherwise `pkill -f -- "${tag}"` as fallback.
3. Remove `${RUN_DIR}${tag}.pid` and `${TAG_DIR}${tag}` symlink. Both removals
   tolerate non-existence (`rm -f`).
4. Exit 3 if nothing matched.

### `cmd_kill_orphans`

For each tagged PID:

- Parse tag → `(term_sid, sse_port, dir)`.
- If `tab_is_alive` returns non-zero:
    - With `--dry-run`: echo `would kill <pid> <tag>`.
    - Otherwise: `kill <pid>` and the heartbeat PID in the pidfile; remove
      pidfile + symlink; echo `killed <pid> <tag>`.

Then, for each heartbeat (`pgrep -f '^sh -c .*awake \(full-dir='`) with no
tagged caffeinate child (`pgrep -P <pid> -f "$TAG_PREFIX"`), which no tab can
own:

- With `--dry-run`: echo `would kill <pid> heartbeat`.
- Otherwise: `kill <pid>`; echo `killed <pid> heartbeat`.

### `claude_pid_for`

For each `pid` in `pgrep -x claude`:

1. `env=$(ps_env "$pid")`.
2. Tokenize on spaces (`tr ' ' '\n'`); look for both
   `TERM_SESSION_ID=<sid>` and `CLAUDE_CODE_SSE_PORT=<port>` as exact matches
   (`grep -qx`).
3. On match: echo `pid`, return 0.

After loop: return 1.

### `tab_is_alive`

Implemented as `claude_pid_for "$@" >/dev/null`.

### Edge cases / known foot-guns to handle

- `TERM_SESSION_ID` may be unset (e.g., SSH session without iTerm/JediTerm) →
  the literal `unknown` is used; `kill-orphans` should treat any instance with
  `TERM_SID=unknown` as a candidate only if **no** Claude process has that
  combination, which by definition will be true → such instances are killed
  aggressively. Document this in the script header comment as accepted behavior.
- `ps -E` prints `ps: time: requires entitlement` on macOS 12+; redirect
  stderr (`2>/dev/null`) in `ps_env`.
- `lsof` on `CLAUDE_CODE_SSE_PORT` is **not** a reliable Claude liveness check
  because, in IDE-integrated mode (WebStorm, VS Code, JetBrains), the SSE port
  is held by the IDE, not by the `claude` binary. The spec intentionally uses
  `pgrep -x claude` + env match instead. Do not "improve" by adding lsof.
- The `claude` binary may have a different name in future Claude Code releases.
  Centralize the binary name as `readonly CLAUDE_BIN_NAME=claude` so future
  upgrades change one line.
- macOS `pgrep -x` matches the full process name; confirm `pgrep -x claude`
  during `cmd_status` and warn if zero claude processes exist machine-wide
  (probable stale install).
- `--json` requires `jq`. Detect early via `require_jq` and exit with code 4
  and a clear message rather than emitting partial or malformed output.

## Acceptance tests

Ship as `tests/test.sh` invoking the script as a subprocess. Each test prints
`PASS <name>` or `FAIL <name>: <reason>`; exit non-zero on any FAIL.

1. **start replaces**: `claffeinate start` runs with a 600-second timeout;
   a second `claffeinate start --idle --timeout 1h` in the same shell prints
   a new PID, the first heartbeat is gone, and exactly one tagged process
   exists, with `-i` and a 3600-second timeout.
2. **list shows the instance**: after `claffeinate start`, `claffeinate list`
   includes a row with the matching tab + dir + `alive`.
3. **kill-mine removes it**: after `claffeinate kill-mine`, `claffeinate list`
   is empty (modulo other tabs) and the symlink + pidfile under
   `/tmp/claffeinate/` are gone.
4. **kill-orphans is a no-op when alive**: with this Claude tab alive,
   `claffeinate kill-orphans --dry-run` prints nothing for our instance.
5. **kill-orphans reaps fakes**: simulate a dead tab by manually creating a
   symlink + pidfile under `/tmp/claffeinate/` with bogus `TERM_SID`/`PORT` and
   a backgrounded `sleep 600`; `claffeinate kill-orphans` should kill it and
   clean up.
6. **claude-pid resolves**:
   `claffeinate claude-pid --term-session-id "$TERM_SESSION_ID" --sse-port "$CLAUDE_CODE_SSE_PORT"`
   returns a PID; the PID's `ps` shows `claude`.
7. **--json parses**: `claffeinate list --json | python3 -c 'import json,sys; json.load(sys.stdin)'`
   exits 0.
8. **--json without jq fails cleanly**: with a stub `jq` ahead of the real one
   on `PATH` that exits 127 (or by unsetting `PATH` to a `jq`-less directory),
   `claffeinate list --json` exits 4 with a `jq required` message and emits no
   JSON on stdout.
9. **short options still work**: `claffeinate start -d` and
   `claffeinate list -j` behave identically to their long-form equivalents.
10. **kill-orphans reaps heartbeat loops**: start an `sh -c` heartbeat loop
    with no caffeinate child; `claffeinate kill-orphans` should kill it.
11. **--timeout expires**: `claffeinate start --timeout 2s` is not flagged by
    `kill-orphans --dry-run` while running, and both the heartbeat and the
    tagged caffeinate are gone 3.5 sec later.
12. **--timeout rejects bad durations**: `start --timeout` with `1x`, `30ms`,
    `m`, `1m1h`, or `0s` exits 2 without starting anything.
13. **every command has its own --help**: for each command, `COMMAND --help`
    exits 0 and starts with `Usage: claffeinate COMMAND`, `help COMMAND`
    prints the same text, and an unknown flag exits 2 naming
    `claffeinate COMMAND --help`. `start --help` starts nothing, and
    `help no-such-command` exits 2.
14. **concurrent starts leave one instance**: 8 simultaneous
    `claffeinate start --idle` in one tab leave exactly one tagged process,
    and no lock behind.
15. **the hook events drive the instance**: `claffeinate-hook.sh pre-tool`
    starts an `-i` instance with a 7200-second timeout; `post-tool` leaves
    one instance with a 600-second timeout; `session-end` stops it; an
    unknown event exits 0. None of them prints anything.
16. **the hook does nothing without caffeinate**: with `PATH` holding only a
    `uname` stub, `pre-tool` exits 0 silently and creates nothing, both when
    `uname` says `Darwin` and `caffeinate` is missing, and when `uname` says
    `Linux` and a `caffeinate` stub is present (the stub must not run).

## Claude Code plugin

The repository is a Claude Code plugin, and its own marketplace:

- `.claude-plugin/plugin.json`: the manifest, named `claffeinate`.
- `.claude-plugin/marketplace.json`: a marketplace also named
  `claffeinate`, with one plugin whose `source` is `./`, the repository
  root. Users install it with `/plugin marketplace add nhooey/claffeinate`
  and `/plugin install claffeinate@claffeinate`.
- `hooks/hooks.json`: one command hook per event, each running
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/claffeinate-hook.sh" EVENT` with a
  15-second timeout (the start lock waits up to ~10 s).
- `hooks/claffeinate-hook.sh EVENT`: maps the event to an action and runs
  `bin/claffeinate.sh` beside it, with stdin, stdout and stderr detached.

| Hook event                          | EVENT         | Action                                 |
| ----------------------------------- | ------------- | -------------------------------------- |
| `UserPromptSubmit`                  | `prompt`      | `start --idle` (10m)                   |
| `PreToolUse`                        | `pre-tool`    | `start --idle --timeout 2h`            |
| `PostToolUse`, `PostToolUseFailure` | `post-tool`   | `start --idle` (10m)                   |
| `Stop`                              | `stop`        | `start --idle` (10m)                   |
| `SessionEnd`                        | `session-end` | `kill-mine`                            |

`PreToolUse` allows 2 hours because no hook fires during a tool call; the
cap bounds how long a crashed tab can keep the Mac awake. `PostToolUse`,
`PostToolUseFailure` and `Stop` bring the deadline back to 10 minutes, so a
failed tool that skips `PostToolUse` is still covered at the end of the
turn.

A hook's failure would show in the user's transcript on every tool call, so
the hook script never fails: it always exits 0, prints nothing, and does
nothing unless `uname -s` is `Darwin` and `caffeinate` is on `PATH`.

## Out of scope

- Sleep-time prediction across overlapping `--timeout` durations. (Defer;
  `pmset -g assertions` is the source of truth.)
- Replacing `caffeinate` with direct `IOPMAssertion*` calls.
- Any persistent daemon or background watcher.
- Anything cross-platform.

## Deliverables

- `bin/claffeinate` (executable, `#!/usr/bin/env bash`).
- `tests/test.sh` (executable).
- The plugin: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
  `hooks/hooks.json` and `hooks/claffeinate-hook.sh`.
- `README.md` covering: install (symlink into `~/bin`), per-subcommand
  examples written exclusively with the canonical long option names, the
  IDE-vs-CLI SSE-port caveat, the `jq` dependency for `--json`, and how to add
  a `claffeinate kill-orphans` invocation to a shell startup file.

No license file needed unless asked; assume the user will add one.
