#!/usr/bin/env bash
#
# claffeinate-hook -- runs claffeinate from the Claude Code plugin's hooks.
#
# Usage: claffeinate-hook.sh EVENT, with the hook's JSON payload on stdin.
#
# Maps each hook event to a hold, so the Mac stays awake only while
# something is working:
#
#   prompt          start --holder turn
#   stop            stop --holder turn (Stop, and StopFailure on an API error)
#   subagent-start  start --holder subagent-<agent_id>
#   subagent-stop   stop --holder subagent-<agent_id>
#   post-tool       for a background Bash only: start --holder shell-<task_id>
#                   --wait-pid <the shell's PID>, so the hold ends with it
#   session-end     kill-session
#
# A Monitor never gets a hold. Each hold also ends when its claude process
# exits, at the duration cap and at the battery floor.
#
# A hook's failure would show up in the user's transcript, so this never
# fails: it discards all output, always exits 0, and does nothing where
# there is no caffeinate(1) to run, such as on Linux. Without jq it can't
# read the payload, and keeps only the turn's hold.

set -uo pipefail

CLAFFEINATE_BIN=""
PAYLOAD=""

claffeinate() {
  bash "$CLAFFEINATE_BIN" "$@" </dev/null >/dev/null 2>&1
}

# A field of the payload, or nothing.
field() {
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$PAYLOAD" | jq -r "$1 // empty" 2>/dev/null || true
}

# Only ids that are safe in a process name.
safe() {
  [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]] && [[ $1 != *--* ]]
}

# The PID of the background shell writing tasks/<id>.output: a child of
# claude whose stdout is that file. It can take a moment to appear.
shell_pid_for() {
  local task="$1" kids pid tries=0
  while [ "$tries" -lt 10 ]; do
    kids=$(pgrep -P "$CLAUDE_PID" 2>/dev/null | paste -sd, - || true)
    if [ -n "$kids" ]; then
      pid=$(lsof -a -p "$kids" -d 1 -Fpn 2>/dev/null | awk -v t="/tasks/${task}.output" '
        /^p/ { p = substr($0, 2) }
        /^n/ && substr($0, length($0) - length(t) + 1) == t { print p; exit }')
      if [ -n "$pid" ]; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

main() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
  command -v caffeinate >/dev/null 2>&1 || return 0
  CLAFFEINATE_BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/claffeinate"
  PAYLOAD=$(cat 2>/dev/null || true)
  local event="${1:-}" sid agent tool background task pid
  sid=$(field .session_id)
  [ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
  safe "$sid" || return 0
  local start=(start --session "$sid" --claude-pid "${CLAUDE_PID:-0}")
  case "$event" in
  prompt) claffeinate "${start[@]}" --holder turn ;;
  stop) claffeinate stop --session "$sid" --holder turn ;;
  subagent-start | subagent-stop)
    agent=$(field .agent_id)
    safe "$agent" || return 0
    if [ "$event" = subagent-start ]; then
      claffeinate "${start[@]}" --holder "subagent-$agent"
    else
      claffeinate stop --session "$sid" --holder "subagent-$agent"
    fi
    ;;
  post-tool)
    tool=$(field .tool_name)
    background=$(field .tool_input.run_in_background)
    task=$(field .tool_response.backgroundTaskId)
    [ "$tool" = Bash ] && [ "$background" = true ] && safe "$task" || return 0
    [ -n "${CLAUDE_PID:-}" ] || return 0
    pid=$(shell_pid_for "$task") || return 0
    claffeinate "${start[@]}" --holder "shell-$task" --wait-pid "$pid"
    ;;
  session-end) claffeinate kill-session --session "$sid" ;;
  esac
  return 0
}

main "$@"
exit 0
