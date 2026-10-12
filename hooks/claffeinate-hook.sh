#!/usr/bin/env bash
#
# claffeinate-hook -- runs claffeinate from the Claude Code plugin's hooks.
#
# Usage: claffeinate-hook.sh EVENT
#
# Maps each hook event to a claffeinate action, so the Mac stays awake while
# the agent works and can sleep once it has been quiet for 10 minutes:
#
#   prompt, post-tool, stop   start --idle               (10 minutes)
#   pre-tool                  start --idle --timeout 2h  (covers a long tool
#                                                         call; 2h is a cap)
#   session-end               kill-mine
#
# A hook's failure would show up in the user's transcript on every tool
# call, so this never fails: it discards all output, always exits 0, and
# does nothing where there is no caffeinate(1) to run, such as on Linux.

set -uo pipefail

readonly TOOL_TIMEOUT="2h"

claffeinate() {
  bash "$(dirname "$0")/../bin/claffeinate.sh" "$@" </dev/null >/dev/null 2>&1
}

main() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
  command -v caffeinate >/dev/null 2>&1 || return 0
  case "${1:-}" in
  prompt | post-tool | stop) claffeinate start --idle ;;
  pre-tool) claffeinate start --idle --timeout "$TOOL_TIMEOUT" ;;
  session-end) claffeinate kill-mine ;;
  esac
  return 0
}

main "$@"
exit 0
