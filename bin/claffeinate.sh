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

usage() {
  cat <<'EOF'
claffeinate -- tag caffeinate instances with the Claude Code tab that owns them

Usage:
  claffeinate start [--display|--idle|--disk|--system|--user|--timeout SECS]...
  claffeinate list   [--json]
  claffeinate status [--json]
  claffeinate kill-mine
  claffeinate kill-orphans [--dry-run]
  claffeinate claude-pid --term-session-id ID --sse-port PORT
  claffeinate help
  claffeinate [--help]

Flags for `start` (no flag: defaults to --display):
  --display    prevent display sleep         (caffeinate -d)
  --idle       prevent idle sleep            (caffeinate -i)
  --disk       prevent disk sleep            (caffeinate -m)
  --system     prevent system sleep on AC    (caffeinate -s)
  --user       declare user is active        (caffeinate -u)
  --timeout N  expire after N seconds        (caffeinate -t N)

Exit codes:
  0  success
  1  generic error
  2  misuse
  3  nothing matched
  4  --json requested but jq is not installed
EOF
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
      timeout="$2"
      shift 2
      ;;
    --help | -h)
      usage
      return 0
      ;;
    *)
      printf "error: unknown flag: %s\n" "$1" >&2
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
  ln -sf "$caffeinate_bin" "$symlink"

  local logfile="${RUN_DIR}${tag}.log"
  # shellcheck disable=SC2016 # body is run under sh -c later, so $-vars must stay literal here
  local heartbeat='while true; do printf "[%s] awake (full-dir=%s)\n" "$(date +%T)" "$PWD"; sleep 60; done'

  if [ -n "$timeout" ]; then
    "$symlink" "-${short_flags}" -t "$timeout" sh -c "$heartbeat" \
      >"$logfile" 2>&1 &
  else
    "$symlink" "-${short_flags}" sh -c "$heartbeat" \
      >"$logfile" 2>&1 &
  fi
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
      usage
      return 0
      ;;
    *)
      printf "error: unknown flag: %s\n" "$1" >&2
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
      usage
      return 0
      ;;
    *)
      printf "error: unknown flag: %s\n" "$1" >&2
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
      usage
      return 0
      ;;
    *)
      printf "error: unknown flag: %s\n" "$1" >&2
      return 2
      ;;
    esac
  done

  local pids pid tag parsed term_sid sse_port dir
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
      kill "$pid" 2>/dev/null || true
      rm -f "${RUN_DIR}${tag}.pid" "${TAG_DIR}${tag}"
      printf "killed %s %s\n" "$pid" "$tag"
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
      usage
      return 0
      ;;
    *)
      printf "error: unknown flag: %s\n" "$1" >&2
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
  help | --help | -h) usage ;;
  *)
    printf "error: unknown subcommand: %s\n" "$1" >&2
    return 2
    ;;
  esac
}

main "$@"
