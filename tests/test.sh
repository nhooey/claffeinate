#!/usr/bin/env bash
#
# Acceptance tests for claffeinate. Invokes bin/claffeinate as a subprocess.
# Usage: tests/test.sh [TEST_NAME...]
# Each test prints "PASS <name>", "FAIL <name>: <reason>" or "SKIP <name>:
# <reason>"; exits non-zero if any test fails.
#
# Every test runs in its own sandbox of directories (run, state, log,
# config, a fake ~/.claude) and its own session ids, with a fake claude
# process to watch, so the user's real holds are never touched. Watchers
# check every second instead of every minute.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# CLAFF is an array so we can invoke bin/claffeinate through `bash` rather
# than relying on the kernel to exec the script directly. Some sandboxes
# (sandboxed macOS Nix builds) block exec on the build volume even though
# writes are fine; bash-as-loader bypasses that.
if [ -n "${CLAFFEINATE_BIN:-}" ]; then
  CLAFF=("$CLAFFEINATE_BIN")
else
  CLAFF=(bash "${ROOT_DIR}/bin/claffeinate")
fi
HOOK="${ROOT_DIR}/hooks/claffeinate-hook.sh"

BASE=$(mktemp -d "${TMPDIR:-/tmp}/claffeinate-test.XXXXXX")
export CLAFFEINATE_RUN_DIR="${BASE}/run/"
export CLAFFEINATE_STATE_DIR="${BASE}/state"
export CLAFFEINATE_LOG="${BASE}/logs/claffeinate.log"
export CLAFFEINATE_CONFIG="${BASE}/config"
export CLAFFEINATE_WATCH_INTERVAL=1
export CLAUDE_CONFIG_DIR="${BASE}/claude"
export LANG=en_US.UTF-8
unset LC_ALL LC_CTYPE CLAFFEINATE_NOW CLAFFEINATE_AWAKE_MAX_DURATION \
  CLAFFEINATE_AWAKE_MIN_BATTERY CLAFFEINATE_EMOJI CLAUDE_CODE_SESSION_ID CLAUDE_PID
mkdir -p "${BASE}/claude/projects/-test" "${BASE}/logs"
REAL_PATH="$PATH"
RUN="t$$"

FAILS=0
PASSES=0
SKIPS=0

# A sandboxed macOS Nix build can block exec of any path outside /nix/store
# (caffeinate(1), /bin/sleep, etc.) with EPERM. Probe once: if a tiny
# system-binary exec fails, tests that need one skip rather than fail.
# The same sandbox denies ps(1), which is SUID root; without it
# claffeinate can't see its holds, nor the tests clean up after themselves.
SYSTEM_EXEC_BLOCKED=0
if ! /bin/sleep 0 2>/dev/null || ! ps -p $$ -o pid= >/dev/null 2>&1; then
  SYSTEM_EXEC_BLOCKED=1
fi

pass() {
  printf 'PASS %s\n' "$1"
  PASSES=$((PASSES + 1))
}
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAILS=$((FAILS + 1))
}
skip() {
  printf 'SKIP %s: %s\n' "$1" "$2"
  SKIPS=$((SKIPS + 1))
}

# Skips test $1 when processes can't be started.
needs_exec() {
  [ "$SYSTEM_EXEC_BLOCKED" = 0 ] && return 0
  skip "$1" "needs caffeinate(1), /bin/sleep and ps(1) (build sandbox blocks them)"
  return 1
}

FAKES=()
# Starts a stand-in for a claude process and prints its PID.
fake_process() {
  (exec -a fake-claude /bin/sleep 600) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

cleanup() {
  local pid
  for pid in $(ps -A -ww -o pid=,command= 2>/dev/null |
    awk -v r="session-$RUN" '$2 ~ /^(claffeinate-watch|caffeinate--claffeinate)--/ && index($2, r) { print $1 }'); do
    kill "$pid" 2>/dev/null || true
  done
  for pid in ${FAKES[@]+"${FAKES[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  pkill -f -- "bogus-${RUN}" 2>/dev/null || true
  rm -rf "$BASE"
}
trap cleanup EXIT

# Counts session $1's holds, of holder $2 when given.
count_holds() {
  "${CLAFF[@]}" list | awk -F'\t' -v s="$1" -v h="${2:-}" \
    '$2 == s && (h == "" || $3 == h) { n++ } END { print n + 0 }'
}

# Waits up to $3 seconds for count_holds $1 $2 to reach 0.
wait_gone() {
  local i=0
  while [ "$(count_holds "$1" "$2")" != 0 ]; do
    i=$((i + 1))
    [ "$i" -le $(($3 * 10)) ] || return 1
    sleep 0.1
  done
}

# The reason logged for session $1's holder $2, the latest.
logged_reason() {
  grep " session=$1 holder=$2 " "$CLAFFEINATE_LOG" 2>/dev/null | tail -n 1 |
    sed -n 's/.* reason=\([^ ]*\) .*/\1/p'
}

# ---------------------------------------------------------------------------
# Stubs for ioreg, pmset and sw_vers, driven by STUB_* variables
# ---------------------------------------------------------------------------
STUBS="${BASE}/stubs"
mkdir -p "$STUBS"
cat >"${STUBS}/ioreg" <<'EOF'
#!/usr/bin/env bash
case " $* " in
*AppleSmartBattery*)
  [ "${STUB_BATTERY:-yes}" = yes ] || exit 0
  cat <<OUT
      "CurrentCapacity" = ${STUB_PCT:-64}
      "Amperage" = ${STUB_AMP:-18446744073709551066}
      "AppleRawCurrentCapacity" = ${STUB_CUR:-3200}
      "ExternalConnected" = ${STUB_EXT:-No}
      "BatteryInstalled" = Yes
      "AppleRawMaxCapacity" = ${STUB_MAX:-5000}
OUT
  ;;
*IOHIDSystem*) printf '    | |     "HIDIdleTime" = %s\n' "${STUB_IDLE_NS:-40000000000}" ;;
esac
EOF
cat >"${STUBS}/pmset" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"-g custom")
  printf 'Battery Power:\n displaysleep         %s\n sleep                1\n disksleep            10\n' "${STUB_DS_BATT:-5}"
  printf 'AC Power:\n displaysleep         %s\n sleep                1\n disksleep            10\n' "${STUB_DS_AC:-10}"
  ;;
"-g batt") printf "Now drawing from '%s'\n" "${STUB_SOURCE:-Battery Power}" ;;
"-g assertions")
  printf 'Assertion status system-wide:\n   PreventUserIdleSystemSleep     1\nListed by owning process:\n'
  printf '   pid 598(powerd): [0x1] 01:38:02 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"\n'
  printf '   pid 2972(WindowServer): [0x2] 00:02:28 UserIsActive named: "tickle"\n'
  [ -z "${STUB_OTHER:-}" ] || printf '   pid 312(%s): [0x3] 00:01:00 PreventUserIdleSystemSleep named: "audio"\n' "$STUB_OTHER"
  printf 'Kernel Assertions: 0x4=USB\n   id=1  level=255 0x4=USB description=usb owner=Hub\n'
  ;;
esac
EOF
printf '#!/usr/bin/env bash\necho 15.6.1\n' >"${STUBS}/sw_vers"
chmod +x "${STUBS}"/*

# Runs claffeinate with the stubs first on PATH.
stubbed() {
  PATH="${STUBS}:${REAL_PATH}" "${CLAFF[@]}" "$@"
}

# Runs claffeinate with the stubs and an empty process table, so status
# shows no holds whatever runs on the Mac.
stubbed_no_holds() {
  local dir="${BASE}/stubs-noproc"
  mkdir -p "$dir"
  printf '#!/bin/sh\nexit 0\n' >"${dir}/ps"
  chmod +x "${dir}/ps"
  PATH="${dir}:${STUBS}:${REAL_PATH}" "${CLAFF[@]}" "$@"
}

# ---------------------------------------------------------------------------
# start, stop and the holder's one hold
# ---------------------------------------------------------------------------
test_start_and_stop() {
  needs_exec start_and_stop || return
  local sid="${RUN}-ss" claude pid line r
  claude=$(fake_process)
  FAKES+=("$claude")
  pid=$("${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude") || {
    fail start_and_stop "start failed: $pid"
    return
  }
  line=$(ps -A -ww -o ppid=,command= | awk -v p="$pid" '$1 == p && $2 ~ /^caffeinate--claffeinate--/')
  if [[ $line != *" caffeinate--claffeinate--session-${sid}--holder-turn--claude-${claude}--max-14400--floor-20--at-"*" -i -w ${claude}" ]]; then
    fail start_and_stop "watcher $pid has no caffeinate -i -w $claude named for its tag: '$line'"
    return
  fi
  if ! ps -ww -p "$pid" -o command= | grep -q "^claffeinate-watch--session-${sid}--holder-turn--"; then
    fail start_and_stop "watcher $pid isn't named claffeinate-watch--<tag>"
    return
  fi
  "${CLAFF[@]}" stop --holder turn --session "$sid" || {
    fail start_and_stop "stop failed"
    return
  }
  if ! wait_gone "$sid" turn 3; then
    fail start_and_stop "hold still running after stop"
    return
  fi
  r=$(logged_reason "$sid" turn)
  if [ "$r" != ended ]; then
    fail start_and_stop "expected reason=ended in the log, got '$r'"
    return
  fi
  "${CLAFF[@]}" stop --holder turn --session "$sid"
  if [ "$?" != 3 ]; then
    fail start_and_stop "stop with no hold should exit 3"
    return
  fi
  pid=$("${CLAFF[@]}" start --session "$sid" --claude-pid "$claude" --keep-display-on)
  line=$(ps -A -ww -o ppid=,command= | awk -v p="$pid" '$1 == p && $2 ~ /^caffeinate--claffeinate--/')
  "${CLAFF[@]}" stop --session "$sid"
  if [[ $line != *" -di -w ${claude}" ]]; then
    fail start_and_stop "--keep-display-on should run caffeinate -di: '$line'"
    return
  fi
  pass start_and_stop
}

test_start_repeat_noop() {
  needs_exec start_repeat_noop || return
  local sid="${RUN}-rep" claude a b
  claude=$(fake_process)
  FAKES+=("$claude")
  a=$("${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude")
  b=$("${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude")
  if [ -z "$a" ] || [ "$a" != "$b" ] || [ "$(count_holds "$sid" turn)" != 1 ]; then
    fail start_repeat_noop "second start should return the same hold: '$a' vs '$b'"
    return
  fi
  "${CLAFF[@]}" kill-session --session "$sid"
  pass start_repeat_noop
}

test_start_concurrent() {
  needs_exec start_concurrent || return
  local sid="${RUN}-conc" claude pids=() n
  claude=$(fake_process)
  FAKES+=("$claude")
  for _ in 1 2 3 4 5 6 7 8; do
    "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" >/dev/null 2>&1 &
    pids+=("$!")
  done
  wait "${pids[@]}"
  n=$(count_holds "$sid" turn)
  "${CLAFF[@]}" kill-session --session "$sid"
  if [ "$n" != 1 ]; then
    fail start_concurrent "8 concurrent starts left $n holds, expected 1"
    return
  fi
  if ls "${CLAFFEINATE_RUN_DIR}locks/"*"${sid}"* >/dev/null 2>&1; then
    fail start_concurrent "a lock was left behind"
    return
  fi
  pass start_concurrent
}

# A subagent's hold is its own, and outlives the turn's.
test_subagent_outlives_turn() {
  needs_exec subagent_outlives_turn || return
  local sid="${RUN}-sub" claude
  claude=$(fake_process)
  FAKES+=("$claude")
  "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" >/dev/null
  "${CLAFF[@]}" start --holder subagent-a1b2 --session "$sid" --claude-pid "$claude" >/dev/null
  "${CLAFF[@]}" stop --holder turn --session "$sid"
  wait_gone "$sid" turn 3
  if [ "$(count_holds "$sid" subagent-a1b2)" != 1 ]; then
    fail subagent_outlives_turn "the subagent's hold ended with the turn's"
    return
  fi
  "${CLAFF[@]}" stop --holder subagent-a1b2 --session "$sid"
  if ! wait_gone "$sid" subagent-a1b2 3; then
    fail subagent_outlives_turn "the subagent's hold didn't stop"
    return
  fi
  pass subagent_outlives_turn
}

# ---------------------------------------------------------------------------
# The limits: the shell or claude exiting, the cap, the battery floor
# ---------------------------------------------------------------------------
test_wait_pid_ends_hold() {
  needs_exec wait_pid_ends_hold || return
  local sid="${RUN}-wait" claude shell r
  claude=$(fake_process)
  FAKES+=("$claude")
  (exec /bin/sleep 1) </dev/null >/dev/null 2>&1 &
  shell=$!
  "${CLAFF[@]}" start --holder shell-xyz --session "$sid" --claude-pid "$claude" --wait-pid "$shell" >/dev/null
  if ! wait_gone "$sid" shell-xyz 4; then
    fail wait_pid_ends_hold "the hold outlived its shell"
    return
  fi
  r=$(logged_reason "$sid" shell-xyz)
  if [ "$r" != ended ]; then
    fail wait_pid_ends_hold "expected reason=ended, got '$r'"
    return
  fi
  pass wait_pid_ends_hold
}

test_claude_exit_ends_hold() {
  needs_exec claude_exit_ends_hold || return
  local sid="${RUN}-cx" claude r
  claude=$(fake_process)
  "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" >/dev/null
  kill "$claude"
  if ! wait_gone "$sid" turn 3; then
    fail claude_exit_ends_hold "the hold outlived its claude"
    return
  fi
  r=$(logged_reason "$sid" turn)
  if [ "$r" != claude-exited ]; then
    fail claude_exit_ends_hold "expected reason=claude-exited, got '$r'"
    return
  fi
  pass claude_exit_ends_hold
}

test_cap_ends_hold() {
  needs_exec cap_ends_hold || return
  local sid="${RUN}-cap" claude r
  claude=$(fake_process)
  FAKES+=("$claude")
  "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" --awake-max-duration 2s >/dev/null
  sleep 0.5
  if [ "$(count_holds "$sid" turn)" != 1 ]; then
    fail cap_ends_hold "the hold ended before its 2s cap"
    return
  fi
  if ! wait_gone "$sid" turn 4; then
    fail cap_ends_hold "the hold outlived its 2s cap"
    return
  fi
  r=$(logged_reason "$sid" turn)
  if [ "$r" != cap ]; then
    fail cap_ends_hold "expected reason=cap, got '$r'"
    return
  fi
  pass cap_ends_hold
}

test_battery_floor_ends_hold() {
  needs_exec battery_floor_ends_hold || return
  local sid="${RUN}-bat" claude r
  claude=$(fake_process)
  FAKES+=("$claude")
  # On AC power too: the battery can drain while plugged in.
  export STUB_PCT=15 STUB_EXT=Yes
  stubbed start --holder turn --session "$sid" --claude-pid "$claude" --awake-min-battery 10 >/dev/null
  stubbed start --holder subagent-low --session "$sid" --claude-pid "$claude" --awake-min-battery 20 >/dev/null
  unset STUB_PCT STUB_EXT
  if ! wait_gone "$sid" subagent-low 3; then
    "${CLAFF[@]}" kill-session --session "$sid"
    fail battery_floor_ends_hold "a hold with a 20% floor kept running at 15%"
    return
  fi
  if [ "$(count_holds "$sid" turn)" != 1 ]; then
    fail battery_floor_ends_hold "a hold with a 10% floor ended at 15%"
    return
  fi
  r=$(logged_reason "$sid" subagent-low)
  "${CLAFF[@]}" kill-session --session "$sid"
  if [ "$r" != battery ]; then
    fail battery_floor_ends_hold "expected reason=battery, got '$r'"
    return
  fi
  pass battery_floor_ends_hold
}

# ---------------------------------------------------------------------------
# kill-session and kill-orphans
# ---------------------------------------------------------------------------
test_kill_session() {
  needs_exec kill_session || return
  local sid="${RUN}-km" other="${RUN}-km2" claude r
  claude=$(fake_process)
  FAKES+=("$claude")
  "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" >/dev/null
  "${CLAFF[@]}" start --holder subagent-q --session "$sid" --claude-pid "$claude" >/dev/null
  "${CLAFF[@]}" start --holder turn --session "$other" --claude-pid "$claude" >/dev/null
  "${CLAFF[@]}" kill-session --session "$sid"
  if ! wait_gone "$sid" "" 3; then
    fail kill_session "the session's holds survived kill-session"
    return
  fi
  if [ "$(count_holds "$other")" != 1 ]; then
    fail kill_session "kill-session ended another session's hold"
    return
  fi
  r=$(logged_reason "$sid" subagent-q)
  "${CLAFF[@]}" kill-session --session "$other"
  if [ "$r" != killed ]; then
    fail kill_session "expected reason=killed, got '$r'"
    return
  fi
  "${CLAFF[@]}" kill-session --session "$sid"
  if [ "$?" != 3 ]; then
    fail kill_session "kill-session with no holds should exit 3"
    return
  fi
  pass kill_session
}

test_kill_orphans() {
  needs_exec kill_orphans || return
  local sid="${RUN}-ko" claude gone shell out old live want
  claude=$(fake_process)
  FAKES+=("$claude")
  gone=$(fake_process)
  shell=$(fake_process)
  FAKES+=("$shell")
  old=$(($(date +%s) - 60))
  # A live hold, which must survive.
  live=$("${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude")
  # A hold whose claude exits while its watcher sleeps for a minute.
  CLAFFEINATE_WATCH_INTERVAL=60 "${CLAFF[@]}" start --holder shell-orph --session "$sid" \
    --claude-pid "$gone" --wait-pid "$shell" >/dev/null
  kill "$gone"
  # A caffeinate without a watcher, and a watcher without a caffeinate.
  (exec -a "caffeinate--claffeinate--session-${sid}--holder-manual--claude-0--max-60--floor-0--at-${old}" /bin/sleep 600) </dev/null >/dev/null 2>&1 &
  (exec -a "claffeinate-watch--session-${sid}--holder-subagent-x--claude-0--max-60--floor-0--at-${old}" /bin/sleep 600) </dev/null >/dev/null 2>&1 &
  # 0.2.0's heartbeat loop.
  # shellcheck disable=SC2016 # body runs under sh -c
  (sh -c 'while true; do printf "[%s] awake (full-dir=%s)\n" "$(date +%T)" "$1"; sleep 60; done' \
    sh "bogus-${RUN}" >/dev/null 2>&1 &)
  # A session settings file whose claude has exited.
  mkdir -p "${CLAFFEINATE_STATE_DIR}/sessions"
  printf 'claude-pid = %s\n' "$gone" >"${CLAFFEINATE_STATE_DIR}/sessions/${sid}.conf"
  sleep 0.3

  out=$("${CLAFF[@]}" kill-orphans --dry-run)
  if [ "$(printf '%s\n' "$out" | grep -c '^would kill ')" -lt 4 ] ||
    [ "$(count_holds "$sid")" != 3 ]; then
    fail kill_orphans "--dry-run should list the 4 orphans and stop none: $out"
    return
  fi
  out=$("${CLAFF[@]}" kill-orphans)
  sleep 0.5
  for want in "holder-shell-orph--.*(claude $gone exited)" \
    "caffeinate--claffeinate--session-${sid}--holder-manual.*(no watcher)" \
    "holder-subagent-x--.*(no caffeinate)" "heartbeat (0.2.0 heartbeat)" "^deleted .*${sid}.conf"; do
    if ! printf '%s\n' "$out" | grep -q -- "$want"; then
      fail kill_orphans "no line matching '$want' in: $out"
      return
    fi
  done
  if [[ $out == *"killed $live "* ]] || [ "$(count_holds "$sid" turn)" != 1 ]; then
    fail kill_orphans "the live hold was touched: $out"
    return
  fi
  # shellcheck disable=SC2009 # matches argv, which pgrep -f also would, but across holders
  if ps -A -ww -o command= | grep -Eq -- "session-${sid}--holder-(manual|subagent-x|shell-orph)" ||
    pgrep -f -- "bogus-${RUN}" >/dev/null; then
    fail kill_orphans "an orphan is still running"
    return
  fi
  if [ "$(logged_reason "$sid" manual)" != killed ]; then
    fail kill_orphans "the watcherless caffeinate wasn't logged as killed"
    return
  fi
  "${CLAFF[@]}" kill-session --session "$sid"
  pass kill_orphans
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
test_config_precedence() {
  local sid="${RUN}-cfg" out
  source_of() {
    "${CLAFF[@]}" config --session "$sid" | awk -v k="$1" '$1 == k { print $2, $3 }'
  }
  out=$(source_of awake-max-duration)
  [ "$out" = "4h default" ] || {
    fail config_precedence "default: $out"
    return
  }
  "${CLAFF[@]}" config set --global awake-max-duration 3h >/dev/null
  out=$(source_of awake-max-duration)
  [ "$out" = "3h config" ] || {
    fail config_precedence "config file: $out"
    return
  }
  out=$(CLAFFEINATE_AWAKE_MAX_DURATION=2h source_of awake-max-duration)
  [ "$out" = "2h env" ] || {
    fail config_precedence "variable over config: $out"
    return
  }
  "${CLAFF[@]}" config set --session "$sid" awake-max-duration 1h >/dev/null
  out=$(CLAFFEINATE_AWAKE_MAX_DURATION=2h source_of awake-max-duration)
  [ "$out" = "1h session" ] || {
    fail config_precedence "session over variable: $out"
    return
  }
  out=$(CLAFFEINATE_AWAKE_MAX_DURATION=bogus "${CLAFF[@]}" config --session "${sid}-none" 2>&1)
  if [[ $out != *"bad value 'bogus'"* ]] || ! printf '%s\n' "$out" | grep -q '^awake-max-duration  *3h  *config$'; then
    fail config_precedence "a bad variable should warn and fall through: $out"
    return
  fi
  "${CLAFF[@]}" config unset --global awake-max-duration >/dev/null
  "${CLAFF[@]}" config unset --session "$sid" awake-max-duration >/dev/null
  out=$(source_of awake-max-duration)
  [ "$out" = "4h default" ] || {
    fail config_precedence "after unset: $out"
    return
  }
  if "${CLAFF[@]}" config set awake-max-duration 1h >/dev/null 2>&1 ||
    "${CLAFF[@]}" config set --global awake-min-battery 101 >/dev/null 2>&1 ||
    "${CLAFF[@]}" config set --global no-such 1 >/dev/null 2>&1; then
    fail config_precedence "set without a layer, a bad value or an unknown setting should fail"
    return
  fi
  if [ "$SYSTEM_EXEC_BLOCKED" = 0 ]; then
    # The flag beats everything, and the hold's tag records what applied.
    local claude
    claude=$(fake_process)
    FAKES+=("$claude")
    "${CLAFF[@]}" config set --session "$sid" awake-min-battery 35 >/dev/null
    CLAFFEINATE_AWAKE_MAX_DURATION=2h "${CLAFF[@]}" start --holder turn --session "$sid" \
      --claude-pid "$claude" --awake-max-duration 90m >/dev/null
    out=$("${CLAFF[@]}" list | awk -F'\t' -v s="$sid" '$2 == s { print $7, $8 }')
    "${CLAFF[@]}" kill-session --session "$sid"
    if [ "$out" != "5400 35" ]; then
      fail config_precedence "the hold should record max 5400 floor 35: '$out'"
      return
    fi
  fi
  pass config_precedence
}

test_start_rejects_bad_values() {
  local bad out rc
  for bad in "--awake-max-duration 1x" "--awake-max-duration 30ms" "--awake-max-duration 1m1h" \
    "--awake-max-duration 0s" "--awake-min-battery 101" "--awake-min-battery x" \
    "--holder bogus" "--holder shell-a--b" "--session a--b" "--wait-pid x"; do
    # shellcheck disable=SC2086 # flag and value
    out=$("${CLAFF[@]}" start --session "${RUN}-bad" $bad 2>&1)
    rc=$?
    if [ "$rc" != 2 ]; then
      "${CLAFF[@]}" kill-session --session "${RUN}-bad" >/dev/null 2>&1
      fail start_rejects_bad_values "'$bad': expected exit 2, got $rc: $out"
      return
    fi
  done
  out=$("${CLAFF[@]}" start --timeout 1h 2>&1)
  if [[ $out != *"--timeout is now --awake-max-duration"* ]]; then
    fail start_rejects_bad_values "--timeout should point at --awake-max-duration: $out"
    return
  fi
  out=$("${CLAFF[@]}" start --display 2>&1)
  if [[ $out != *"--display is now --keep-display-on"* ]]; then
    fail start_rejects_bad_values "--display should point at --keep-display-on: $out"
    return
  fi
  out=$("${CLAFF[@]}" kill-mine 2>&1)
  if [[ $out != *"kill-mine is now kill-session"* ]]; then
    fail start_rejects_bad_values "kill-mine should point at kill-session: $out"
    return
  fi
  pass start_rejects_bad_values
}

# ---------------------------------------------------------------------------
# Help, JSON and other output
# ---------------------------------------------------------------------------
test_per_command_help() {
  local cmd out via_help rc
  for cmd in start stop list status kill-session kill-orphans config; do
    out=$("${CLAFF[@]}" "$cmd" --help 2>&1)
    rc=$?
    if [ "$rc" != "0" ] || [[ $out != "Usage: claffeinate $cmd"* ]]; then
      fail per_command_help "'$cmd --help': exit $rc, output: $out"
      return
    fi
    via_help=$("${CLAFF[@]}" help "$cmd" 2>&1)
    if [ "$via_help" != "$out" ]; then
      fail per_command_help "'help $cmd' differs from '$cmd --help'"
      return
    fi
    out=$("${CLAFF[@]}" "$cmd" --no-such-flag 2>&1)
    rc=$?
    if [ "$rc" != "2" ] || [[ $out != *"claffeinate $cmd --help"* ]]; then
      fail per_command_help "'$cmd --no-such-flag': exit $rc, output: $out"
      return
    fi
  done
  "${CLAFF[@]}" help no-such-command >/dev/null 2>&1
  rc=$?
  if [ "$rc" != "2" ]; then
    fail per_command_help "'help no-such-command': expected exit 2, got $rc"
    return
  fi
  pass per_command_help
}

test_json_parses() {
  needs_exec json_parses || return
  local sid="${RUN}-json" claude json cmd
  claude=$(fake_process)
  FAKES+=("$claude")
  "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" >/dev/null
  for cmd in list status; do
    json=$(stubbed "$cmd" --json 2>&1) || {
      fail json_parses "$cmd --json failed: $json"
      return
    }
    if ! printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      fail json_parses "$cmd --json is not valid JSON: $json"
      return
    fi
  done
  "${CLAFF[@]}" kill-session --session "$sid"
  if [ "$(printf '%s' "$json" | jq -r --arg s "$sid" '.holds[] | select(.session == $s) | .holder')" != turn ] ||
    [ "$(printf '%s' "$json" | jq -r '.macos.displaysleep_minutes')" != 5 ]; then
    fail json_parses "status --json is missing the hold or the macos block: $json"
    return
  fi
  pass json_parses
}

test_json_without_jq_fails() {
  local stub_dir out rc
  stub_dir=$(mktemp -d)
  printf '#!/bin/sh\nexit 127\n' >"${stub_dir}/jq"
  chmod +x "${stub_dir}/jq"
  out=$(PATH="${stub_dir}:${PATH}" "${CLAFF[@]}" list --json 2>&1)
  rc=$?
  rm -rf "$stub_dir"
  if [ "$rc" != "4" ] || [[ $out != *"jq"* ]]; then
    fail json_without_jq_fails "expected exit 4 naming jq, got $rc: $out"
    return
  fi
  pass json_without_jq_fails
}

# Every emoji is one code point, drawn 2 columns wide everywhere.
test_emoji_are_terminal_safe() {
  local list
  list=$(sed -n '/^emoji_for() {/,/^}/p' "${ROOT_DIR}/bin/claffeinate" |
    sed -n "s/.*printf '\\(..*\\)' ;;/\\1/p")
  if [ "$(printf '%s\n' "$list" | wc -l | tr -d ' ')" -lt 10 ]; then
    fail emoji_are_terminal_safe "found too few emoji in emoji_for: $list"
    return
  fi
  if ! printf '%s\n' "$list" | python3 -c '
import sys, unicodedata
bad = [l for l in sys.stdin.read().split() if len(l) != 1 or unicodedata.east_asian_width(l) != "W" or unicodedata.category(l) != "So"]
sys.exit(1 if bad else 0)'; then
    fail emoji_are_terminal_safe "an emoji isn't a single wide symbol: $list"
    return
  fi
  pass emoji_are_terminal_safe
}

# The display width of each line of stdin, an emoji counting 2.
display_widths() {
  python3 -c '
import sys, unicodedata
for line in sys.stdin.read().splitlines():
    print(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in line))'
}

# The status forecast and tables, in their fixed shape, from stubs.
test_status_shape() {
  needs_exec status_shape || return
  local now got want plain plain_c log="${BASE}/shape.log"
  now=$(python3 -c 'import calendar; print(calendar.timegm((2026, 10, 16, 15, 30, 0)))')
  printf '2026-10-16T13:40:00+0000 session=9a1e2b77-bbbb holder=subagent-a8fce5d reason=battery ran=22m start=%s stop=%s\n' \
    $((now - 6600 - 1320)) $((now - 6600)) >"$log"
  printf '2026-10-16T14:02:00+0000 session=0f311c94-aaaa holder=turn reason=ended ran=1h02m start=%s stop=%s\n' \
    $((now - 5280 - 3720)) $((now - 5280)) >>"$log"
  printf '{"type":"ai-title","aiTitle":"Old title","sessionId":"0f311c94-aaaa"}\n{"type":"custom-title","customTitle":"Claffeinate","sessionId":"0f311c94-aaaa"}\n' \
    >"${CLAUDE_CONFIG_DIR}/projects/-test/0f311c94-aaaa.jsonl"
  printf '{"type":"ai-title","aiTitle":"Converting project to Claude plugin","sessionId":"9a1e2b77-bbbb"}\n' \
    >"${CLAUDE_CONFIG_DIR}/projects/-test/9a1e2b77-bbbb.jsonl"
  got=$(TZ=UTC CLAFFEINATE_NOW=$now CLAFFEINATE_LOG="$log" stubbed_no_holds status)
  want=$(
    cat <<'EOF'
claffeinate  2026-10-16 15:30  macOS 15.6.1  power=battery  holds=0
💤 sleep    15:34  +4m     by=macos
⏳ time     -      -       cap=4h
🔋 battery  -      -       now=64% floor=20% rate=-11%/h
💻 macos    15:34  +4m     input=15:29(-40s) display=5m sleep=1m other=-

PID    SESSION   NAME                    HOLDER                         CLAUDE  STATE     STARTED          ENDS
(none)

STOPPED          SESSION   NAME                    HOLDER                         REASON            RAN
14:02    -1h28m  0f311c94  Claffeinate             💬 turn                        ✅ ended          1h02m
13:40    -1h50m  9a1e2b77  Converting project to…  🤖 subagent-a8fce5d            🔋 battery        22m
EOF
  )
  if [ "$got" != "$want" ]; then
    fail status_shape "status differs from its fixed shape:
--- got
$got
--- want
$want"
    return
  fi
  # Without emoji, each line keeps its width, so the columns don't move.
  plain=$(TZ=UTC CLAFFEINATE_NOW=$now CLAFFEINATE_LOG="$log" stubbed_no_holds status --no-emoji)
  plain_c=$(TZ=UTC CLAFFEINATE_NOW=$now CLAFFEINATE_LOG="$log" LANG=C stubbed_no_holds status)
  if [[ $plain == *"💤"* ]] ||
    [ "$(printf '%s\n' "$plain" | display_widths)" != "$(printf '%s\n' "$got" | display_widths)" ]; then
    fail status_shape "--no-emoji should keep every line's width:
$plain"
    return
  fi
  if [ "$plain_c" != "$plain" ]; then
    fail status_shape "a non-UTF-8 locale should turn emoji off:
$plain_c"
    return
  fi
  pass status_shape
}

# How the macOS model reads the display, idle time and other assertions.
test_status_macos_model() {
  needs_exec status_macos_model || return
  local now out
  now=$(date +%s)
  # Display on: sleep comes 10 minutes after the last input, on AC.
  out=$(CLAFFEINATE_NOW=$now STUB_SOURCE="AC Power" STUB_IDLE_NS=60000000000 stubbed_no_holds status | grep '^💻 macos ')
  if [[ $out != *" +9m "*"display=10m sleep=1m other=-" ]]; then
    fail status_macos_model "display on, 1m idle on AC: $out"
    return
  fi
  # Display off: idle longer than displaysleep, so it sleeps at once.
  out=$(CLAFFEINATE_NOW=$now STUB_IDLE_NS=900000000000 stubbed_no_holds status | grep '^💻 macos ')
  if [[ $out != *" +0s "*"(-15m)"* ]]; then
    fail status_macos_model "display off, 15m idle: $out"
    return
  fi
  # Another app's assertion: no sleep forecast, and the app is named.
  out=$(CLAFFEINATE_NOW=$now STUB_OTHER=coreaudiod stubbed_no_holds status)
  if ! printf '%s\n' "$out" | grep -q '^💤 sleep    -      -       by=macos other=coreaudiod:312$' ||
    ! printf '%s\n' "$out" | grep -q '^💻 macos    -      -  .* other=coreaudiod:312$'; then
    fail status_macos_model "another app's assertion: $out"
    return
  fi
  # A desktop Mac has no battery.
  out=$(CLAFFEINATE_NOW=$now STUB_BATTERY=no stubbed_no_holds status | grep '^🔋 battery ')
  if [[ $out != *"-      -       none" ]]; then
    fail status_macos_model "no battery: $out"
    return
  fi
  pass status_macos_model
}

# With holds, the forecast names the limit that decides it.
test_status_forecast() {
  needs_exec status_forecast || return
  local sid="${RUN}-fc" claude out
  claude=$(fake_process)
  FAKES+=("$claude")
  "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" --awake-max-duration 3h >/dev/null
  # 64% of 5000 mAh at 550 mA, to a 20% floor: 2200 mAh in 4h.
  out=$(STUB_IDLE_NS=0 stubbed status)
  if ! printf '%s\n' "$out" | grep -q '^💤 sleep .* by=time$' ||
    ! printf '%s\n' "$out" | grep -Eq '^🔋 battery .* \+(4h|3h59m) .*now=64% floor=20% rate=-11%/h$' ||
    ! printf '%s\n' "$out" | grep -Eq "^[0-9]+ +${sid:0:8} .*💬 turn .*🟢 alive .* \\+(3h|2h59m)  *⏳ time$"; then
    "${CLAFF[@]}" kill-session --session "$sid"
    fail status_forecast "a 3h cap should come before a 4h battery: $out"
    return
  fi
  # At 1100 mA the battery reaches the floor in 2h, before the cap.
  out=$(STUB_IDLE_NS=0 STUB_AMP=-1100 stubbed status)
  "${CLAFF[@]}" kill-session --session "$sid"
  if ! printf '%s\n' "$out" | grep -Eq '^💤 sleep .* \+(2h|1h59m) .*by=battery$' ||
    ! printf '%s\n' "$out" | grep -q '🔋 battery$'; then
    fail status_forecast "a 2h battery should come before a 3h cap: $out"
    return
  fi
  pass status_forecast
}

test_log_trim() {
  needs_exec log_trim || return
  local sid="${RUN}-trim" claude n
  # Its own log and state, which no earlier test's watcher still writes to.
  local CLAFFEINATE_LOG="${BASE}/trim/claffeinate.log" CLAFFEINATE_STATE_DIR="${BASE}/trim/state"
  export CLAFFEINATE_LOG CLAFFEINATE_STATE_DIR
  mkdir -p "${BASE}/trim"
  claude=$(fake_process)
  FAKES+=("$claude")
  awk 'BEGIN { for (i = 0; i < 2000; i++) print "2026-01-01T00:00:00+0000 session=old holder=turn reason=ended ran=1s start=0 stop=1" }' \
    >"$CLAFFEINATE_LOG"
  "${CLAFF[@]}" start --holder turn --session "$sid" --claude-pid "$claude" >/dev/null
  "${CLAFF[@]}" stop --holder turn --session "$sid"
  wait_gone "$sid" turn 3
  sleep 0.2
  n=$(wc -l <"$CLAFFEINATE_LOG" | tr -d ' ')
  if [ "$n" != 1000 ] || [ "$(logged_reason "$sid" turn)" != ended ]; then
    fail log_trim "a log past 2000 lines should keep the last 1000, newest included: $n lines"
    return
  fi
  if [ "$(readlink "${CLAFFEINATE_STATE_DIR}/claffeinate.log")" != "$CLAFFEINATE_LOG" ]; then
    fail log_trim "the state directory should link to the log"
    return
  fi
  pass log_trim
}

# ---------------------------------------------------------------------------
# The plugin's hook
# ---------------------------------------------------------------------------

# Runs the hook for event $1 with payload $2, as claude $3 would.
run_hook() {
  printf '%s' "$2" | CLAUDE_PID="$3" "$BASH" "$HOOK" "$1" 2>&1
}

test_hook_events() {
  needs_exec hook_events || return
  local sid="${RUN}-hook" claude out
  claude=$(fake_process)
  FAKES+=("$claude")
  out=$(run_hook prompt "{\"session_id\":\"$sid\",\"prompt\":\"hi\"}" "$claude")
  if [ -n "$out" ] || [ "$(count_holds "$sid" turn)" != 1 ]; then
    fail hook_events "prompt should start the turn's hold, silently: '$out'"
    return
  fi
  run_hook subagent-start "{\"session_id\":\"$sid\",\"agent_id\":\"a8fce5d\",\"agent_type\":\"Explore\"}" "$claude"
  run_hook stop "{\"session_id\":\"$sid\",\"stop_hook_active\":false}" "$claude"
  wait_gone "$sid" turn 3
  if [ "$(count_holds "$sid" subagent-a8fce5d)" != 1 ]; then
    fail hook_events "the subagent's hold should outlive stop"
    return
  fi
  run_hook subagent-stop "{\"session_id\":\"$sid\",\"agent_id\":\"a8fce5d\"}" "$claude"
  if ! wait_gone "$sid" subagent-a8fce5d 3; then
    fail hook_events "subagent-stop should end the subagent's hold"
    return
  fi
  # A Monitor never gets a hold, nor does a foreground Bash.
  run_hook post-tool "{\"session_id\":\"$sid\",\"tool_name\":\"Monitor\",\"tool_input\":{\"command\":\"tail -f x\"},\"tool_response\":{\"taskId\":\"m1\"}}" "$claude"
  run_hook post-tool "{\"session_id\":\"$sid\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_response\":{\"stdout\":\"\"}}" "$claude"
  if [ "$(count_holds "$sid")" != 0 ]; then
    fail hook_events "a Monitor or foreground Bash got a hold"
    return
  fi
  run_hook prompt "{\"session_id\":\"$sid\"}" "$claude"
  out=$(run_hook session-end "{\"session_id\":\"$sid\",\"reason\":\"exit\"}" "$claude")
  if [ -n "$out" ] || ! wait_gone "$sid" "" 3; then
    fail hook_events "session-end should end every hold, silently: '$out'"
    return
  fi
  if ! out=$(run_hook no-such-event "{\"session_id\":\"$sid\"}" "$claude") || [ -n "$out" ]; then
    fail hook_events "an unknown event should exit 0 silently: $out"
    return
  fi
  pass hook_events
}

# A background Bash's hold waits on the shell writing tasks/<id>.output,
# found among claude's children.
test_hook_background_shell() {
  needs_exec hook_background_shell || return
  local sid="${RUN}-bg" task="bmnsyo3e4" tasks shell
  tasks="${BASE}/claude-tmp/${sid}/tasks"
  mkdir -p "$tasks"
  # This test shell plays claude: the fake shell is its child.
  (exec /bin/sleep 600) </dev/null >"${tasks}/${task}.output" 2>/dev/null &
  shell=$!
  FAKES+=("$shell")
  run_hook post-tool "{\"session_id\":\"$sid\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\",\"run_in_background\":true},\"tool_response\":{\"backgroundTaskId\":\"$task\"}}" "$$"
  if [ "$(count_holds "$sid" "shell-$task")" != 1 ]; then
    kill "$shell"
    fail hook_background_shell "a background Bash should get a hold"
    return
  fi
  local procs
  # shellcheck disable=SC2009 # the whole argv, -w PID included
  procs=$(ps -A -ww -o command= | grep -- "session-${sid}--")
  if ! printf '%s\n' "$procs" | grep -q "^caffeinate--claffeinate--session-${sid}--holder-shell-${task}--.* -w ${shell}$"; then
    kill "$shell"
    "${CLAFF[@]}" kill-session --session "$sid"
    fail hook_background_shell "the hold should wait on the shell, PID $shell: $procs"
    return
  fi
  kill "$shell"
  if ! wait_gone "$sid" "shell-$task" 3; then
    "${CLAFF[@]}" kill-session --session "$sid"
    fail hook_background_shell "the hold should end with the shell"
    return
  fi
  pass hook_background_shell
}

test_hook_noop_without_caffeinate() {
  local stubs out rc
  stubs=$(mktemp -d)
  # A PATH holding only a uname stub: first Darwin with no caffeinate, then
  # Linux with a caffeinate that must never run.
  printf '#!%s\necho Darwin\n' "$BASH" >"${stubs}/uname"
  chmod +x "${stubs}/uname"
  out=$(printf '{}' | PATH="$stubs" "$BASH" "$HOOK" prompt 2>&1)
  rc=$?
  if [ "$rc" != "0" ] || [ -n "$out" ]; then
    rm -rf "$stubs"
    fail hook_noop_without_caffeinate "no caffeinate: exit $rc, output: $out"
    return
  fi
  printf '#!%s\necho Linux\n' "$BASH" >"${stubs}/uname"
  printf '#!%s\n: >"%s/ran"\n' "$BASH" "$stubs" >"${stubs}/caffeinate"
  chmod +x "${stubs}/caffeinate"
  out=$(printf '{}' | PATH="$stubs" "$BASH" "$HOOK" prompt 2>&1)
  rc=$?
  if [ "$rc" != "0" ] || [ -n "$out" ] || [ -e "${stubs}/ran" ]; then
    rm -rf "$stubs"
    fail hook_noop_without_caffeinate "Linux: exit $rc, output: $out"
    return
  fi
  rm -rf "$stubs"
  pass hook_noop_without_caffeinate
}

# Every hooks.json entry runs the hook with an action it handles.
test_hooks_json_structure() {
  local hooks_json="${ROOT_DIR}/hooks/hooks.json"
  local known="UserPromptSubmit SubagentStart SubagentStop PostToolUse Stop StopFailure SessionEnd"
  # shellcheck disable=SC2016 # the literal text hooks.json holds
  local prefix='bash "${CLAUDE_PLUGIN_ROOT}/hooks/claffeinate-hook.sh" '
  local event command timeout action seen=""
  while IFS=$'\t' read -r event command timeout; do
    if [[ " $known " != *" $event "* ]]; then
      fail hooks_json_structure "unexpected hook event: $event"
      return
    fi
    seen+=" $event"
    if [[ $command != "$prefix"* ]]; then
      fail hooks_json_structure "$event runs an unexpected command: $command"
      return
    fi
    action="${command#"$prefix"}"
    if ! grep -Eq "^  ([a-z-]+ \| )*${action}( \| [a-z-]+)*\)" "$HOOK"; then
      fail hooks_json_structure "$event uses action '$action', which the hook does not handle"
      return
    fi
    # Must outlast start's wait for the holder's lock, about 10 seconds.
    if [ "$timeout" -lt 15 ]; then
      fail hooks_json_structure "$event times out after ${timeout}s, under 15s"
      return
    fi
  done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[] | [$e, .command, .timeout] | @tsv' "$hooks_json")
  for event in $known; do
    if [[ " $seen " != *" $event "* ]]; then
      fail hooks_json_structure "no hook for $event"
      return
    fi
  done
  if [ "$(jq -r '.hooks.PostToolUse[0].matcher' "$hooks_json")" != Bash ]; then
    fail hooks_json_structure "PostToolUse should match only Bash"
    return
  fi
  pass hooks_json_structure
}

# Off macOS every command but help fails with a clear error.
test_non_macos_error() {
  local stubs out rc
  stubs=$(mktemp -d)
  printf '#!%s\necho Linux\n' "$BASH" >"${stubs}/uname"
  chmod +x "${stubs}/uname"
  out=$(PATH="${stubs}:$PATH" "$BASH" "${ROOT_DIR}/bin/claffeinate" start 2>&1)
  rc=$?
  if [ "$rc" != "1" ] || [ "$out" != "error: claffeinate needs macOS caffeinate(1)" ]; then
    rm -rf "$stubs"
    fail non_macos_error "start should exit 1 with the macOS error: exit $rc, output: $out"
    return
  fi
  if ! PATH="${stubs}:$PATH" "$BASH" "${ROOT_DIR}/bin/claffeinate" start --help >/dev/null 2>&1; then
    rm -rf "$stubs"
    fail non_macos_error "start --help should still work"
    return
  fi
  rm -rf "$stubs"
  pass non_macos_error
}

# ---------------------------------------------------------------------------
# Run: every test, or only those named on the command line
# ---------------------------------------------------------------------------
TESTS=(
  start_and_stop
  start_repeat_noop
  start_concurrent
  subagent_outlives_turn
  wait_pid_ends_hold
  claude_exit_ends_hold
  cap_ends_hold
  battery_floor_ends_hold
  kill_session
  kill_orphans
  config_precedence
  start_rejects_bad_values
  per_command_help
  json_parses
  json_without_jq_fails
  emoji_are_terminal_safe
  status_shape
  status_macos_model
  status_forecast
  log_trim
  hook_events
  hook_background_shell
  hook_noop_without_caffeinate
  hooks_json_structure
  non_macos_error
)
for name in "${TESTS[@]}"; do
  if [ $# -eq 0 ] || [[ " $* " == *" $name "* ]]; then
    "test_$name"
  fi
done

printf '\n%d passed, %d failed, %d skipped\n' "$PASSES" "$FAILS" "$SKIPS"
[ "$FAILS" -eq 0 ]
