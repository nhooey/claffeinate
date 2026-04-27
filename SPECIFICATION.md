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
- **Idempotent.** Running `start` twice in the same tab: the second call
  detects the existing instance and exits 0 with a "already running, PID=N"
  message — does not spawn a duplicate.
- **Composable output.** `list` emits one line per instance, tab-separated, suitable
  for `awk`/`cut`. A `--json` flag on `list` and `status` for machine consumption.
- **No `set -e` traps for control flow.** Use explicit `||` and `if` for
  expected-failure paths.

## CLI surface

Long options are canonical and used throughout this spec, the README, the
`--help` output, and every example. Short options are accepted as aliases
but never appear in documentation.

```
claffeinate start [--display|--idle|--disk|--system|--user|--timeout SECS]...   # default: --display
claffeinate list   [--json]
claffeinate status [--json]
claffeinate kill-mine
claffeinate kill-orphans [--dry-run]
claffeinate claude-pid --term-session-id ID --sse-port PORT
claffeinate help
claffeinate [--help]
```

Short option aliases (accepted; not used in docs):

| Long                     | Short  | Subcommand      | Notes                              |
| ------------------------ | ------ | --------------- | ---------------------------------- |
| `--display`              | `-d`   | `start`         | translates to `caffeinate -d`      |
| `--idle`                 | `-i`   | `start`         | translates to `caffeinate -i`      |
| `--disk`                 | `-m`   | `start`         | translates to `caffeinate -m`      |
| `--system`               | `-s`   | `start`         | translates to `caffeinate -s`      |
| `--user`                 | `-u`   | `start`         | translates to `caffeinate -u`      |
| `--timeout SECS`         | `-t`   | `start`         | translates to `caffeinate -t SECS` |
| `--json`                 | `-j`   | `list`/`status` | JSON output via `jq` (required)    |
| `--dry-run`              | `-n`   | `kill-orphans`  | only print what would be killed    |
| `--term-session-id ID`   | (none) | `claude-pid`    | required                           |
| `--sse-port PORT`        | (none) | `claude-pid`    | required                           |
| `--help`                 | `-h`   | (any)           | print help and exit 0              |

`caffeinate(1)` itself does not understand long options; the script translates
long → short before exec'ing the symlink. Default to `--display` if no flag
is given to `start`.

Exit codes:

- `0` success
- `1` generic error
- `2` misuse (unknown subcommand, unknown flag, missing required arg)
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
ps_env            (pid)                          -> echoes env line from `ps -E`, stderr suppressed
require_jq        ()                             -> exit 4 with a clear message if `jq` not on PATH
```

### Mutation (subcommand bodies)

```
cmd_start         (caffeinate_flags...)          -> spawns one instance, prints PID; idempotent
cmd_list          (--json?)                      -> table or JSON of {pid, tag, tab, dir, alive}
cmd_status        (--json?)                      -> like list but also includes claude PID + uptime
cmd_kill_mine     ()                             -> kills the instance owned by THIS tab
cmd_kill_orphans  (--dry-run?)                   -> kills all instances whose Claude tab is dead
cmd_claude_pid    (--term-session-id, --sse-port) -> echoes claude PID; exit 1 if none
```

### Dispatch

```
main (args...) -> case "$1" in start) cmd_start "${@:2}";; ... esac
```

## Behavior detail

### `cmd_start`

1. Parse the long-and-short caffeinate flags (`--display|-d`, `--idle|-i`,
   `--disk|-m`, `--system|-s`, `--user|-u`, `--timeout SECS|-t SECS`); accept
   any combination. Default to `--display` if none given.
2. Compute `tag=$(current_tag)`.
3. If `[ -f "${RUN_DIR}${tag}.pid" ]` and
   `kill -0 "$(cat ${RUN_DIR}${tag}.pid)" 2>/dev/null`,
   echo `already running: PID=<pid>` and return 0.
4. Ensure `${RUN_DIR}` and `${TAG_DIR}` exist (`mkdir -p`); create symlink
   `${TAG_DIR}${tag} -> $(command -v caffeinate)`.
5. Translate the parsed long flags back to caffeinate's short forms and exec
   the symlink in background with those flags plus a heartbeat:
   `sh -c 'while true; do printf "[%s] awake (full-dir=%s)\n" "$(date +%T)" "$PWD"; sleep 60; done'`.
6. Write PID to `${RUN_DIR}${tag}.pid`. Echo the PID.

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
    - Otherwise: `kill <pid>`; remove pidfile + symlink; echo `killed <pid> <tag>`.

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

1. **start is idempotent**: `claffeinate start` twice in the same shell → second
   call exits 0 with `already running` and only one tagged process exists.
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

## Out of scope

- Sleep-time prediction across overlapping `--timeout` durations. (Defer;
  `pmset -g assertions` is the source of truth.)
- Replacing `caffeinate` with direct `IOPMAssertion*` calls.
- Any persistent daemon or background watcher.
- Anything cross-platform.

## Deliverables

- `bin/claffeinate` (executable, `#!/usr/bin/env bash`).
- `tests/test.sh` (executable).
- `README.md` covering: install (symlink into `~/bin`), per-subcommand
  examples written exclusively with the canonical long option names, the
  IDE-vs-CLI SSE-port caveat, the `jq` dependency for `--json`, and how to add
  a `claffeinate kill-orphans` invocation to a shell startup file.

No license file needed unless asked; assume the user will add one.
