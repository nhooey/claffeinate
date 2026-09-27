#!/usr/bin/env bash
#
# claffeinate -- start/list/kill caffeinate instances tagged with the
# Claude Code tab that owns them. macOS-only.
#
# Each instance is launched via a uniquely-named symlink to caffeinate(1)
# so the binary name in `ps` carries the tab identifier (TERM_SESSION_ID +
# CLAUDE_CODE_SSE_PORT) and the basename of the working directory.
#
# Accepted behavior on TERM_SESSION_ID=unknown: SSH sessions and other
# environments without iTerm/JediTerm leave TERM_SESSION_ID unset; we
# substitute the literal "unknown". Any "unknown" instance can never be
# matched to a live Claude tab, so kill-orphans treats it as an orphan
# whenever no live claude process advertises the same combination -- which
# is by definition always true. Such instances are killed aggressively.
#
# A note on pgrep -a: macOS BSD pgrep EXCLUDES ancestors of the calling
# process by default. When this script is invoked from inside a Claude
# Code session, the claude binary is an ancestor and would be missed by
# `pgrep -x claude`. We pass -a everywhere so ancestors are included.

set -euo pipefail

readonly TAG_PREFIX="caffeinate--claffeinate--"
# RUN_DIR is overridable via $CLAFFEINATE_RUN_DIR for tests and sandboxed CI
# where /tmp/claffeinate/ may not be writable. Must end with "/".
readonly RUN_DIR="${CLAFFEINATE_RUN_DIR:-/tmp/claffeinate/}"
readonly TAG_DIR="${RUN_DIR}symlinks/"
readonly CLAUDE_BIN_NAME="claude"
# Matches the heartbeat `sh -c` that caffeinate(1) runs as its utility.
# Anchored on `^sh -c` so the tagged caffeinate, whose argv also carries
# the heartbeat text, never matches.
readonly HEARTBEAT_PATTERN='^sh -c .*awake \(full-dir='

# ---------- pure detection ----------

claude_tab_id() {
  local term_sid="${TERM_SESSION_ID:-unknown}"
  local sse_port="${CLAUDE_CODE_SSE_PORT:-noport}"
  printf '%s-%s\n' "$term_sid" "$sse_port"
}

current_tag() {
  local term_sid="${TERM_SESSION_ID:-unknown}"
  local sse_port="${CLAUDE_CODE_SSE_PORT:-noport}"
  local dir
  dir="$(basename "$PWD")"
  printf '%stab-%s-%s--dir-%s\n' \
    "$TAG_PREFIX" "$term_sid" "$sse_port" "$dir"
}

parse_tag() {
  local tag="$1"
  local rest="${tag#"${TAG_PREFIX}"tab-}"
  local left="${rest%%--dir-*}"
  local dir="${rest#*--dir-}"
  local term_sid sse_port
  if [[ $left =~ ^(.+)-([0-9]+|noport)$ ]]; then
    term_sid="${BASH_REMATCH[1]}"
    sse_port="${BASH_REMATCH[2]}"
  else
    sse_port="${left##*-}"
    term_sid="${left%-*}"
  fi
  printf '%s %s %s\n' "$term_sid" "$sse_port" "$dir"
}

list_tagged_pids() {
  pgrep -a -f -- "$TAG_PREFIX" 2>/dev/null || true
}

list_orphaned_heartbeat_pids() {
  # caffeinate(1) forks: the original process execs the utility and the
  # tagged caffeinate stays behind as its child. A heartbeat with no
  # tagged child has lost its caffeinate and keeps nothing awake.
  local pid
  for pid in $(pgrep -a -f -- "$HEARTBEAT_PATTERN" 2>/dev/null); do
    pgrep -q -P "$pid" -f -- "$TAG_PREFIX" 2>/dev/null || printf '%s\n' "$pid"
  done
}

tag_for_pid() {
  # Returns the basename of argv[0] for $pid, but only when it begins with
  # our TAG_PREFIX -- which is the only case any caller cares about. Uses
  # `pgrep -alf` instead of `ps -p ... -o comm=` because /bin/ps is SUID
  # root and is denied by the macOS Nix build sandbox; pgrep is allowed.
  local pid="$1"
  local line
  line=$(pgrep -alf -- "$TAG_PREFIX" 2>/dev/null | awk -v p="$pid" '
    $1 == p {
      sub(/^[0-9]+[[:space:]]+/, "")
      print
      exit
    }
  ')
  [ -z "$line" ] && return 0
  local exe="${line%% *}"
  basename "$exe"
}

ps_env() {
  local pid="$1"
  ps -E -p "$pid" -o command= 2>/dev/null || true
}

claude_pid_for() {
  local term_sid="$1"
  local sse_port="$2"
  local pids
  pids=$(pgrep -a -x "$CLAUDE_BIN_NAME" 2>/dev/null) || return 1
  local pid env_line
  for pid in $pids; do
    env_line=$(ps_env "$pid")
    [ -z "$env_line" ] && continue
    if printf '%s\n' "$env_line" | tr ' ' '\n' |
      grep -qx "TERM_SESSION_ID=$term_sid" &&
      printf '%s\n' "$env_line" | tr ' ' '\n' |
      grep -qx "CLAUDE_CODE_SSE_PORT=$sse_port"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

tab_is_alive() {
  claude_pid_for "$@" >/dev/null
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1 || ! jq --version >/dev/null 2>&1; then
    printf "error: --json requires jq; install with 'brew install jq'\n" >&2
    exit 4
  fi
}

# ---------- helpers ----------

etime_to_seconds() {
  local etime="$1"
  local days=0 rest="$etime"
  if [[ $rest == *-* ]]; then
    days="${rest%%-*}"
    rest="${rest#*-}"
  fi
  local hours=0 mins=0 secs=0
  local IFS=:
  # shellcheck disable=SC2086
  set -- $rest
  if [ $# -eq 3 ]; then
    hours=$1
    mins=$2
    secs=$3
  elif [ $# -eq 2 ]; then
    mins=$1
    secs=$2
  elif [ $# -eq 1 ]; then
    secs=$1
  fi
  printf '%d\n' "$((10#$days * 86400 + 10#$hours * 3600 + 10#$mins * 60 + 10#$secs))"
}

duration_to_seconds() {
  # Accepts a bare number of seconds or one or more <number><unit> parts in
  # descending order, units d/h/m/s: 90, 30s, 60m, 1h30m, 2d. Fails on
  # anything else, and on a zero total.
  local duration="$1"
  local re='^([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+s)?$'
  local total
  if [[ $duration =~ ^[0-9]+$ ]]; then
    total=$((10#$duration))
  elif [ -n "$duration" ] && [[ $duration =~ $re ]]; then
    local d="${BASH_REMATCH[1]%d}" h="${BASH_REMATCH[2]%h}"
    local m="${BASH_REMATCH[3]%m}" s="${BASH_REMATCH[4]%s}"
    total=$((10#${d:-0} * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0}))
  else
    return 1
  fi
  [ "$total" -gt 0 ] || return 1
  printf '%d\n' "$total"
}

# ---------- help ----------

usage() {
  cat <<'EOF'
claffeinate -- keep your Mac awake while Claude Code works, one tab at a time

Each caffeinate(1) instance is tagged with the Claude Code tab that started
it, so a closed tab's keep-awake can be found and stopped without touching
the ones other tabs still need.

Usage:
  claffeinate <command> [options]

Commands:
  start           keep this Mac awake on behalf of this tab
  list            list every instance and whether its tab is still open
  status          list, plus each owning claude PID and uptime
  kill-mine       stop this tab's instance
  kill-orphans    stop every instance whose tab has closed
  claude-pid      find the claude process behind a tab
  help [COMMAND]  show this help, or a command's

Run 'claffeinate COMMAND --help' for a command's options and examples.

Exit codes:
  0  success
  1  generic error
  2  misuse
  3  nothing matched
  4  --json requested but jq is not installed
EOF
}

usage_start() {
  cat <<'EOF'
Usage: claffeinate start [--display] [--idle] [--disk] [--system] [--user]
                         [--timeout DURATION]

Keep this Mac awake on behalf of the current Claude Code tab, and print the
PID of the instance. Running start again in the same tab starts nothing new
and prints "already running: PID=N".

Options (combine any; with none, --display is used):
  --display           keep the display from sleeping    (caffeinate -d)
  --idle              keep the system from idle sleep   (caffeinate -i)
  --disk              keep the disk from idle sleep     (caffeinate -m)
  --system            keep the system awake, on AC only (caffeinate -s)
  --user              declare that the user is active   (caffeinate -u)
  --timeout DURATION  stop by itself after DURATION: 30s, 60m, 1h30m, 2d;
                      a bare number is seconds
  --help              show this help

Examples:
  claffeinate start
  claffeinate start --idle --display
  claffeinate start --timeout 1h30m
EOF
}

usage_list() {
  cat <<'EOF'
Usage: claffeinate list [--json]

List every claffeinate instance on this Mac, one tab-separated row each:

  PID  TERM_SESSION_ID  SSE_PORT  DIR  alive|dead

"dead" means no running Claude Code tab matches the instance, so
kill-orphans would stop it.

Options:
  --json  print a JSON array instead (needs jq)
  --help  show this help

Example:
  claffeinate list --json | jq '.[] | select(.alive | not)'
EOF
}

usage_status() {
  cat <<'EOF'
Usage: claffeinate status [--json]

Like list, with two more columns: the PID of the claude process that owns
the instance ("-" once its tab has closed), and how long the instance has
been running.

  PID  TERM_SESSION_ID  SSE_PORT  DIR  alive|dead  CLAUDE_PID  UPTIME_SECONDS

Warns on stderr if no claude process is running at all.

Options:
  --json  print a JSON array instead (needs jq)
  --help  show this help
EOF
}

usage_kill_mine() {
  cat <<'EOF'
Usage: claffeinate kill-mine

Stop the instance this Claude Code tab started, and remove its pidfile and
symlink. Instances from other tabs are left alone. Exits 3 if this tab has
no instance.

Options:
  --help  show this help
EOF
}

usage_kill_orphans() {
  cat <<'EOF'
Usage: claffeinate kill-orphans [--dry-run]

Stop every instance whose Claude Code tab has closed, and every heartbeat
loop that has lost its caffeinate. An instance whose tab is still open is
never touched. An instance started outside Claude Code has no tab to match,
so it always counts as an orphan.

Prints one line for each process it stops:

  killed PID TAG
  killed PID heartbeat

Options:
  --dry-run  print "would kill ..." instead, and stop nothing
  --help     show this help

Example, reaping in the background at shell startup:
  command -v claffeinate >/dev/null && claffeinate kill-orphans >/dev/null 2>&1 &
EOF
}

usage_claude_pid() {
  cat <<'EOF'
Usage: claffeinate claude-pid --term-session-id ID --sse-port PORT

Print the PID of the claude process whose environment has both
TERM_SESSION_ID=ID and CLAUDE_CODE_SSE_PORT=PORT. This is the check that
decides whether an instance's tab is still open. Exits 1 if no claude
process matches.

Options:
  --term-session-id ID  the tab's TERM_SESSION_ID (required)
  --sse-port PORT       the tab's CLAUDE_CODE_SSE_PORT (required)
  --help                show this help

Example:
  claffeinate claude-pid --term-session-id "$TERM_SESSION_ID" \
    --sse-port "$CLAUDE_CODE_SSE_PORT"
EOF
}

# Prints a command's help, or the overview when no command is given.
cmd_help() {
  case "${1:-}" in
  "") usage ;;
  start) usage_start ;;
  list) usage_list ;;
  status) usage_status ;;
  kill-mine) usage_kill_mine ;;
  kill-orphans) usage_kill_orphans ;;
  claude-pid) usage_claude_pid ;;
  *)
    printf "error: unknown command: %s (see 'claffeinate --help')\n" "$1" >&2
    return 2
    ;;
  esac
}

# Reports a flag the command doesn't accept, and where its flags are listed.
unknown_flag() {
  printf "error: unknown flag for %s: %s (see 'claffeinate %s --help')\n" \
    "$1" "$2" "$1" >&2
}

# ---------- shared row emitter ----------

emit_rows() {
  local pids pid tag parsed term_sid sse_port dir alive
  pids=$(list_tagged_pids)
  for pid in $pids; do
    tag=$(tag_for_pid "$pid")
    [ -z "$tag" ] && continue
    case "$tag" in
    ${TAG_PREFIX}*) ;;
    *) continue ;;
    esac
    parsed=$(parse_tag "$tag")
    read -r term_sid sse_port dir <<<"$parsed"
    if tab_is_alive "$term_sid" "$sse_port"; then
      alive="alive"
    else
      alive="dead"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$pid" "$term_sid" "$sse_port" "$dir" "$alive"
  done
}

# ---------- subcommands ----------

cmd_start() {
  local short_flags=""
  local timeout=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --display | -d)
      short_flags="${short_flags}d"
      shift
      ;;
    --idle | -i)
      short_flags="${short_flags}i"
      shift
      ;;
    --disk | -m)
      short_flags="${short_flags}m"
      shift
      ;;
    --system | -s)
      short_flags="${short_flags}s"
      shift
      ;;
    --user | -u)
      short_flags="${short_flags}u"
      shift
      ;;
    --timeout | -t)
      if [ $# -lt 2 ]; then
        printf "error: --timeout requires a value\n" >&2
        return 2
      fi
      if ! timeout=$(duration_to_seconds "$2"); then
        printf "error: --timeout expects a duration like 30s, 60m, 1h30m: %s\n" "$2" >&2
        return 2
      fi
      shift 2
      ;;
    --help | -h)
      usage_start
      return 0
      ;;
    *)
      unknown_flag start "$1"
      return 2
      ;;
    esac
  done

  if [ -z "$short_flags" ]; then
    short_flags="d"
  fi

  local tag pidfile symlink caffeinate_bin
  tag="$(current_tag)"
  pidfile="${RUN_DIR}${tag}.pid"
  symlink="${TAG_DIR}${tag}"

  if [ -f "$pidfile" ]; then
    local existing
    existing=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      printf "already running: PID=%s\n" "$existing"
      return 0
    fi
  fi

  mkdir -p "$RUN_DIR" "$TAG_DIR"
  caffeinate_bin="$(command -v caffeinate || true)"
  if [ -z "$caffeinate_bin" ]; then
    printf "error: caffeinate not found on PATH\n" >&2
    return 1
  fi
  # The symlink stays as a kill-mine fallback marker (its presence /
  # removal is part of the contract), but we never exec it -- some
  # sandboxes (notably sandboxed macOS Nix builds) block exec on the
  # build volume even though writes are fine. Instead, exec the real
  # caffeinate(1) and override argv[0] with the symlink path via
  # `exec -a`, which gives the same observable tag in `ps`/`pgrep`.
  ln -sf "$caffeinate_bin" "$symlink"

  local logfile="${RUN_DIR}${tag}.log"
  # The heartbeat is caffeinate(1)'s utility, and caffeinate ignores -t when
  # given one, so the loop enforces the timeout ($2) itself; caffeinate
  # exits when its utility does. The loop also exits once its tagged
  # caffeinate child (argv[0] under $1, the symlink dir) is gone, since
  # nothing else would ever stop it.
  # shellcheck disable=SC2016 # body is run under sh -c later, so $-vars must stay literal here
  local heartbeat='deadline=${2:+$(($(date +%s) + $2))}; while pgrep -q -P $$ -f -- "$1"; do nap=60; if [ -n "$deadline" ]; then left=$((deadline - $(date +%s))); [ "$left" -gt 0 ] || exit 0; [ "$left" -lt "$nap" ] && nap=$left; fi; printf "[%s] awake (full-dir=%s)\n" "$(date +%T)" "$PWD"; sleep "$nap"; done'

  (exec -a "$symlink" "$caffeinate_bin" "-${short_flags}" sh -c "$heartbeat" sh "$TAG_DIR" "$timeout") \
    >"$logfile" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$pidfile"
  printf '%s\n' "$pid"
  disown "$pid" 2>/dev/null || true
}

cmd_list() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --json | -j)
      json=1
      shift
      ;;
    --help | -h)
      usage_list
      return 0
      ;;
    *)
      unknown_flag list "$1"
      return 2
      ;;
    esac
  done

  if [ "$json" = "1" ]; then
    require_jq
    emit_rows | jq -Rn '
      [inputs | select(length > 0) | split("\t") | {
        pid: .[0],
        term_sid: .[1],
        sse_port: .[2],
        dir: .[3],
        alive: (.[4] == "alive")
      }]
    '
  else
    emit_rows
  fi
}

cmd_status() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --json | -j)
      json=1
      shift
      ;;
    --help | -h)
      usage_status
      return 0
      ;;
    *)
      unknown_flag status "$1"
      return 2
      ;;
    esac
  done

  if [ "$json" = "1" ]; then
    require_jq
  fi

  if ! pgrep -a -x "$CLAUDE_BIN_NAME" >/dev/null 2>&1; then
    printf "warning: no '%s' process found machine-wide; stale install?\n" \
      "$CLAUDE_BIN_NAME" >&2
  fi

  local rows=""
  local pid term_sid sse_port dir alive claude_pid uptime etime
  while IFS=$'\t' read -r pid term_sid sse_port dir alive; do
    [ -z "$pid" ] && continue
    if claude_pid=$(claude_pid_for "$term_sid" "$sse_port" 2>/dev/null); then
      :
    else
      claude_pid="-"
    fi
    etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || true)
    if [ -n "$etime" ]; then
      uptime=$(etime_to_seconds "$etime")
    else
      uptime="0"
    fi
    rows+="${pid}	${term_sid}	${sse_port}	${dir}	${alive}	${claude_pid}	${uptime}"$'\n'
  done < <(emit_rows)

  if [ "$json" = "1" ]; then
    if [ -z "$rows" ]; then
      printf '[]\n'
    else
      printf '%s' "$rows" | jq -Rn '
        [inputs | select(length > 0) | split("\t") | {
          pid: .[0],
          term_sid: .[1],
          sse_port: .[2],
          dir: .[3],
          alive: (.[4] == "alive"),
          claude_pid: (if .[5] == "-" then null else .[5] end),
          uptime_seconds: (.[6] | tonumber)
        }]
      '
    fi
  else
    printf '%s' "$rows"
  fi
}

cmd_kill_mine() {
  while [ $# -gt 0 ]; do
    case "$1" in
    --help | -h)
      usage_kill_mine
      return 0
      ;;
    *)
      unknown_flag kill-mine "$1"
      return 2
      ;;
    esac
  done

  local tag pidfile symlink killed=0
  tag="$(current_tag)"
  pidfile="${RUN_DIR}${tag}.pid"
  symlink="${TAG_DIR}${tag}"

  if [ -f "$pidfile" ]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$pid" ] && kill "$pid" 2>/dev/null; then
      killed=1
    fi
  else
    if pkill -f -- "$tag" 2>/dev/null; then
      killed=1
    fi
  fi

  rm -f "$pidfile" "$symlink"

  if [ "$killed" = "0" ]; then
    return 3
  fi
}

cmd_kill_orphans() {
  local dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run | -n)
      dry_run=1
      shift
      ;;
    --help | -h)
      usage_kill_orphans
      return 0
      ;;
    *)
      unknown_flag kill-orphans "$1"
      return 2
      ;;
    esac
  done

  local pids pid tag parsed term_sid sse_port dir pidfile_pid
  pids=$(list_tagged_pids)
  for pid in $pids; do
    tag=$(tag_for_pid "$pid")
    [ -z "$tag" ] && continue
    case "$tag" in
    ${TAG_PREFIX}*) ;;
    *) continue ;;
    esac
    parsed=$(parse_tag "$tag")
    read -r term_sid sse_port dir <<<"$parsed"
    if tab_is_alive "$term_sid" "$sse_port"; then
      continue
    fi
    if [ "$dry_run" = "1" ]; then
      printf "would kill %s %s\n" "$pid" "$tag"
    else
      # The pidfile holds the heartbeat, caffeinate's parent; killing it
      # takes the caffeinate down too, where killing only the caffeinate
      # would leave the heartbeat running.
      pidfile_pid=$(cat "${RUN_DIR}${tag}.pid" 2>/dev/null || true)
      kill "$pid" ${pidfile_pid:+"$pidfile_pid"} 2>/dev/null || true
      rm -f "${RUN_DIR}${tag}.pid" "${TAG_DIR}${tag}"
      printf "killed %s %s\n" "$pid" "$tag"
    fi
  done

  # Heartbeats that outlived their caffeinate carry no tag, so the tab
  # check above cannot see them.
  for pid in $(list_orphaned_heartbeat_pids); do
    if [ "$dry_run" = "1" ]; then
      printf "would kill %s heartbeat\n" "$pid"
    else
      kill "$pid" 2>/dev/null || true
      printf "killed %s heartbeat\n" "$pid"
    fi
  done
}

cmd_claude_pid() {
  local term_sid="" sse_port=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --term-session-id)
      if [ $# -lt 2 ]; then
        printf "error: --term-session-id requires a value\n" >&2
        return 2
      fi
      term_sid="$2"
      shift 2
      ;;
    --sse-port)
      if [ $# -lt 2 ]; then
        printf "error: --sse-port requires a value\n" >&2
        return 2
      fi
      sse_port="$2"
      shift 2
      ;;
    --help | -h)
      usage_claude_pid
      return 0
      ;;
    *)
      unknown_flag claude-pid "$1"
      return 2
      ;;
    esac
  done

  if [ -z "$term_sid" ] || [ -z "$sse_port" ]; then
    printf "error: --term-session-id and --sse-port are required\n" >&2
    return 2
  fi

  if ! claude_pid_for "$term_sid" "$sse_port"; then
    return 1
  fi
}

# ---------- dispatch ----------

main() {
  if [ $# -eq 0 ]; then
    usage
    return 0
  fi
  case "$1" in
  start)
    shift
    cmd_start "$@"
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  kill-mine)
    shift
    cmd_kill_mine "$@"
    ;;
  kill-orphans)
    shift
    cmd_kill_orphans "$@"
    ;;
  claude-pid)
    shift
    cmd_claude_pid "$@"
    ;;
  help)
    shift
    cmd_help "$@"
    ;;
  --help | -h) usage ;;
  *)
    printf "error: unknown command: %s (see 'claffeinate --help')\n" "$1" >&2
    return 2
    ;;
  esac
}

main "$@"
