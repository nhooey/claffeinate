# claffeinate

A small Bash wrapper around `caffeinate(1)` that tags each instance with the
Claude Code tab that owns it. Multi-tab workflows can detect and reap orphans
(instances whose Claude tab has died) without killing each other's instances.

macOS only. Bash 3.2+. Zero external dependencies beyond macOS built-ins;
`jq` is required only when `--json` is requested.

## Install

Symlink `bin/claffeinate` into a directory on your `PATH`:

```sh
ln -s "$PWD/bin/claffeinate" ~/bin/claffeinate
```

Then verify:

```sh
claffeinate --help
```

## How tagging works

Every `claffeinate start` creates a uniquely-named symlink to `caffeinate` and
exec's that symlink. The symlink's name encodes the tab identifier, so the
process appears in `ps` and `pgrep` under a name like:

```
caffeinate--claffeinate--tab-<TERM_SESSION_ID>-<CLAUDE_CODE_SSE_PORT>--dir-<basename(PWD)>
```

The `caffeinate--` prefix is intentional: `pgrep caffeinate` and `pgrep -f
caffeinate` still find these processes. The project name `claffeinate`
(Claude + caffeinate) does not contain `caffeinate` as a substring, so the
prefix carries that responsibility.

Symlinks live under `/tmp/claffeinate/symlinks/`; pidfiles live under
`/tmp/claffeinate/`.

## Subcommands

Long options are canonical; short options are accepted but not used in
documentation.

### `claffeinate start [--display|--idle|--disk|--system|--user|--timeout SECS]...`

Start a tagged caffeinate instance for the current tab. Defaults to
`--display` if no flag is given. Idempotent: a second `start` in the same
tab detects the existing instance and exits 0 without spawning a duplicate.

```sh
claffeinate start                       # --display by default
claffeinate start --idle --display      # combine assertions
claffeinate start --timeout 3600        # auto-expire after 1 hour
```

### `claffeinate list [--json]`

One row per tagged instance, tab-separated:

```
<pid>	<term_sid>	<sse_port>	<dir>	<alive|dead>
```

```sh
claffeinate list
claffeinate list --json | jq '.[] | select(.alive)'
```

`--json` requires `jq`; see [jq dependency](#jq-dependency) below.

### `claffeinate status [--json]`

Like `list` but adds the matching `claude` PID and uptime in seconds:

```
<pid>	<term_sid>	<sse_port>	<dir>	<alive|dead>	<claude_pid|->	<uptime_seconds>
```

### `claffeinate kill-mine`

Kill the instance owned by this tab; remove its pidfile and symlink. Exits
3 if no instance for this tab exists.

### `claffeinate kill-orphans [--dry-run]`

Kill every tagged instance whose Claude tab is no longer alive. The matching
rule is "no `claude` process advertises both this `TERM_SESSION_ID` and this
`CLAUDE_CODE_SSE_PORT` in its environment." `--dry-run` only prints what
would be killed.

### `claffeinate claude-pid --term-session-id ID --sse-port PORT`

Resolve the `claude` PID associated with the given tab. Echoes the PID;
exits 1 if no match.

## Reap orphans on shell startup

Add to `~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish`:

```sh
# Reap claffeinate instances whose Claude tab has died.
command -v claffeinate >/dev/null && claffeinate kill-orphans >/dev/null 2>&1 &
```

This runs in the background so shell startup is not blocked. Killing live
instances is not possible: only those whose `TERM_SESSION_ID` /
`CLAUDE_CODE_SSE_PORT` no longer match a running `claude` are reaped.

## IDE-vs-CLI SSE port caveat

In IDE-integrated mode (WebStorm, VS Code, JetBrains), the
`CLAUDE_CODE_SSE_PORT` is held by the IDE rather than by the `claude`
binary itself. Liveness checks based on `lsof` of that port would therefore
mistake the IDE for Claude Code. claffeinate uses `pgrep -x claude` plus
an environment-match against `ps -E` instead, which is correct in both
CLI and IDE-integrated modes.

This also means that if you upgrade or rename the `claude` binary, you
need to update `CLAUDE_BIN_NAME` near the top of `bin/claffeinate`. There
is one such constant exactly for this reason.

## jq dependency

`--json` requires `jq` on `PATH`. claffeinate intentionally does not ship a
hand-rolled JSON encoder. If `jq` is missing or non-functional and `--json`
was requested, claffeinate exits with code 4 and a clear message:

```
error: --json requires jq; install with 'brew install jq'
```

No JSON-shaped output is produced in this case (no partial or malformed
output).

## TERM_SESSION_ID=unknown

Environments without iTerm/JediTerm (most SSH sessions) don't set
`TERM_SESSION_ID`. claffeinate substitutes the literal `unknown`. Such an
instance can never be matched to a live Claude tab, so `kill-orphans`
treats it as an orphan whenever no `claude` process advertises the same
combination -- which is by definition always true. These instances are
killed aggressively. This is accepted behavior.

## Exit codes

| Code | Meaning                                           |
| ---- | ------------------------------------------------- |
| 0    | Success                                           |
| 1    | Generic error                                     |
| 2    | Misuse (unknown subcommand, unknown flag, etc.)   |
| 3    | Nothing matched (e.g., `kill-mine` with no instance) |
| 4    | `--json` requested but `jq` is not installed     |

## Tests

```sh
tests/test.sh
```

Tests run inside Claude Code (they need a real `TERM_SESSION_ID` and
`CLAUDE_CODE_SSE_PORT` to verify the `claude-pid` resolver). They use
synthetic tab IDs internally so they don't collide with the user's real
instances.
