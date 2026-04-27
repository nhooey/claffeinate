#!/usr/bin/env bash
#
# Acceptance tests for claffeinate. Invokes bin/claffeinate as a subprocess.
# Each test prints "PASS <name>" or "FAIL <name>: <reason>"; exits non-zero
# if any test fails.
#
# To minimize collisions with the user's real claffeinate processes, every
# test runs with a synthetic TERM_SESSION_ID and (where applicable) a
# synthetic CLAUDE_CODE_SSE_PORT. The "real" env vars are saved up front
# for tests that need to resolve a real claude process (test 6).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# CLAFF is an array so we can invoke claffeinate.sh through `bash` rather
# than relying on the kernel to exec the script directly. Some sandboxes
# (Garnix Darwin) block exec on the build volume even though writes are
# fine; bash-as-loader bypasses that.
if [ -n "${CLAFFEINATE_BIN:-}" ]; then
  CLAFF=("$CLAFFEINATE_BIN")
else
  CLAFF=(bash "${ROOT_DIR}/bin/claffeinate.sh")
fi

# RUN_DIR mirrors the script's: defaults to /tmp/claffeinate/, but can be
# overridden via $CLAFFEINATE_RUN_DIR for sandboxed CI. Trailing "/" required.
RUN_DIR="${CLAFFEINATE_RUN_DIR:-/tmp/claffeinate/}"
TAG_DIR="${RUN_DIR}symlinks/"
export CLAFFEINATE_RUN_DIR="$RUN_DIR"

REAL_TERM_SID="${TERM_SESSION_ID:-}"
REAL_SSE_PORT="${CLAUDE_CODE_SSE_PORT:-}"

TEST_TERM_SID="claffeinate-test-$$-$(date +%s)"
TEST_SSE_PORT="65$(printf '%03d' $((RANDOM % 1000)))"

FAILS=0
PASSES=0
SKIPS=0

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

# Returns 0 if a live `claude` process exists for the given (sid, port).
# Used by tests that need a real Claude Code session to run; in CI/sandbox
# environments without one, those tests skip rather than fail.
have_live_claude() {
  local sid="$1" port="$2" pids pid env_line
  [ -z "$sid" ] && return 1
  [ -z "$port" ] && return 1
  pids=$(pgrep -a -x claude 2>/dev/null) || return 1
  for pid in $pids; do
    env_line=$(ps -E -p "$pid" -o command= 2>/dev/null) || continue
    if printf '%s\n' "$env_line" | tr ' ' '\n' | grep -qx "TERM_SESSION_ID=$sid" &&
      printf '%s\n' "$env_line" | tr ' ' '\n' | grep -qx "CLAUDE_CODE_SSE_PORT=$port"; then
      return 0
    fi
  done
  return 1
}

cleanup() {
  TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" kill-mine >/dev/null 2>&1 || true
  if [ -n "$REAL_TERM_SID" ] && [ -n "$REAL_SSE_PORT" ]; then
    TERM_SESSION_ID="$REAL_TERM_SID" CLAUDE_CODE_SSE_PORT="$REAL_SSE_PORT" \
      "${CLAFF[@]}" kill-mine >/dev/null 2>&1 || true
  fi
  # Reap any leftover test fakes by tag pattern.
  pkill -f -- "caffeinate--claffeinate--tab-${TEST_TERM_SID}-" 2>/dev/null || true
  pkill -f -- "caffeinate--claffeinate--tab-bogus-test-" 2>/dev/null || true
  rm -f "${RUN_DIR}"*"${TEST_TERM_SID}"* 2>/dev/null || true
  rm -f "${TAG_DIR}"*"${TEST_TERM_SID}"* 2>/dev/null || true
  rm -f "${RUN_DIR}"*"bogus-test"* 2>/dev/null || true
  rm -f "${TAG_DIR}"*"bogus-test"* 2>/dev/null || true
  if [ -n "$REAL_TERM_SID" ]; then
    rm -f "${RUN_DIR}"*"${REAL_TERM_SID}"*.log 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test 1: start is idempotent
# ---------------------------------------------------------------------------
test_start_idempotent() {
  local out1 out2 tagged_count
  out1=$(TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" start 2>&1) || {
    fail start_idempotent "first start failed: $out1"
    return
  }
  sleep 0.3
  out2=$(TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" start 2>&1) || {
    fail start_idempotent "second start failed: $out2"
    return
  }
  if [[ $out2 != *"already running"* ]]; then
    fail start_idempotent "second start did not say 'already running': $out2"
    return
  fi
  tagged_count=$(pgrep -a -f -- "caffeinate--claffeinate--tab-${TEST_TERM_SID}-${TEST_SSE_PORT}--" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$tagged_count" != "1" ]; then
    fail start_idempotent "expected 1 tagged process, found $tagged_count"
    return
  fi
  pass start_idempotent
}

# ---------------------------------------------------------------------------
# Test 2: list shows the instance
# ---------------------------------------------------------------------------
test_list_shows_instance() {
  local out
  out=$(TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" list 2>&1)
  if printf '%s' "$out" | awk -F'\t' -v sid="$TEST_TERM_SID" -v port="$TEST_SSE_PORT" '
       $2 == sid && $3 == port { found = 1 }
       END { exit !found }
     '; then
    pass list_shows_instance
  else
    fail list_shows_instance "no row for ${TEST_TERM_SID}/${TEST_SSE_PORT} in: $out"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: kill-mine removes it
# ---------------------------------------------------------------------------
test_kill_mine() {
  local out tag
  TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" kill-mine >/dev/null 2>&1 || {
    fail kill_mine "kill-mine returned non-zero"
    return
  }
  sleep 0.4
  out=$(TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" list 2>&1)
  if printf '%s' "$out" | awk -F'\t' -v sid="$TEST_TERM_SID" -v port="$TEST_SSE_PORT" '
       $2 == sid && $3 == port { found = 1 }
       END { exit found ? 1 : 0 }
     '; then
    : # no row found, good
  else
    fail kill_mine "row still present after kill-mine: $out"
    return
  fi
  # Build the tag the same way the script does.
  tag="caffeinate--claffeinate--tab-${TEST_TERM_SID}-${TEST_SSE_PORT}--dir-$(basename "$PWD")"
  if [ -e "${RUN_DIR}${tag}.pid" ]; then
    fail kill_mine "pidfile still exists at ${RUN_DIR}${tag}.pid"
    return
  fi
  if [ -e "${TAG_DIR}${tag}" ]; then
    fail kill_mine "symlink still exists at ${TAG_DIR}${tag}"
    return
  fi
  pass kill_mine
}

# ---------------------------------------------------------------------------
# Test 4: kill-orphans is a no-op when alive
# ---------------------------------------------------------------------------
test_kill_orphans_alive_noop() {
  if ! have_live_claude "$REAL_TERM_SID" "$REAL_SSE_PORT"; then
    skip kill_orphans_alive_noop "no live claude for current session (sandbox/CI)"
    return
  fi
  # Start with the REAL env so this instance is bound to the live claude.
  local out
  out=$(TERM_SESSION_ID="$REAL_TERM_SID" CLAUDE_CODE_SSE_PORT="$REAL_SSE_PORT" \
    "${CLAFF[@]}" start 2>&1) || {
    fail kill_orphans_alive_noop "start failed: $out"
    return
  }
  sleep 0.3
  out=$(TERM_SESSION_ID="$REAL_TERM_SID" CLAUDE_CODE_SSE_PORT="$REAL_SSE_PORT" \
    "${CLAFF[@]}" kill-orphans --dry-run 2>&1) || true
  local matched
  matched=$(printf '%s\n' "$out" | grep -c "tab-${REAL_TERM_SID}-${REAL_SSE_PORT}--" || true)
  # Clean up first
  TERM_SESSION_ID="$REAL_TERM_SID" CLAUDE_CODE_SSE_PORT="$REAL_SSE_PORT" \
    "${CLAFF[@]}" kill-mine >/dev/null 2>&1 || true
  if [ "$matched" -gt 0 ]; then
    fail kill_orphans_alive_noop "dry-run flagged our live instance: $out"
    return
  fi
  pass kill_orphans_alive_noop
}

# ---------------------------------------------------------------------------
# Test 5: kill-orphans reaps fakes
# ---------------------------------------------------------------------------
test_kill_orphans_reaps_fakes() {
  local fake_sid="bogus-test-$$"
  local fake_port="9999"
  local fake_dir="orphandir"
  local tag="caffeinate--claffeinate--tab-${fake_sid}-${fake_port}--dir-${fake_dir}"
  mkdir -p "$RUN_DIR" "$TAG_DIR"
  # Symlink is the kill-orphans cleanup target. We don't exec it -- some
  # sandboxes (Garnix Darwin runners) block exec on the build volume.
  # Use `exec -a` to set argv[0] to the symlink path, which is what
  # tag_for_pid / pgrep -f match against.
  ln -sf /bin/sleep "${TAG_DIR}${tag}"
  (exec -a "${TAG_DIR}${tag}" /bin/sleep 600) &
  local fake_pid=$!
  printf '%s\n' "$fake_pid" >"${RUN_DIR}${tag}.pid"
  disown "$fake_pid" 2>/dev/null || true
  sleep 0.3

  if ! kill -0 "$fake_pid" 2>/dev/null; then
    fail kill_orphans_reaps_fakes "could not start fake process"
    return
  fi

  local out
  out=$(TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" kill-orphans 2>&1) || true
  sleep 0.3

  # Reap our own backgrounded child if it's already exited so kill -0 below
  # doesn't see a zombie. wait succeeds for live or exited children, exits
  # nonzero only when the PID is unknown to job control -- in either case
  # the kernel state is sane afterwards.
  wait "$fake_pid" 2>/dev/null || true
  if pgrep -af -- "$tag" >/dev/null 2>&1; then
    pkill -f -- "$tag" 2>/dev/null || true
    fail kill_orphans_reaps_fakes "fake tagged process still alive: $out"
    return
  fi
  if [ -e "${RUN_DIR}${tag}.pid" ]; then
    fail kill_orphans_reaps_fakes "fake pidfile not removed"
    return
  fi
  if [ -e "${TAG_DIR}${tag}" ]; then
    fail kill_orphans_reaps_fakes "fake symlink not removed"
    return
  fi
  pass kill_orphans_reaps_fakes
}

# ---------------------------------------------------------------------------
# Test 6: claude-pid resolves
# ---------------------------------------------------------------------------
test_claude_pid_resolves() {
  if ! have_live_claude "$REAL_TERM_SID" "$REAL_SSE_PORT"; then
    skip claude_pid_resolves "no live claude for current session (sandbox/CI)"
    return
  fi
  local pid comm
  pid=$("${CLAFF[@]}" claude-pid --term-session-id "$REAL_TERM_SID" --sse-port "$REAL_SSE_PORT" 2>&1) || {
    fail claude_pid_resolves "claude-pid failed: $pid"
    return
  }
  comm=$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename)
  if [ "$comm" != "claude" ]; then
    fail claude_pid_resolves "PID $pid is not 'claude' (got '$comm')"
    return
  fi
  pass claude_pid_resolves
}

# ---------------------------------------------------------------------------
# Test 7: --json parses
# ---------------------------------------------------------------------------
test_json_parses() {
  if ! command -v jq >/dev/null 2>&1; then
    fail json_parses "jq not installed"
    return
  fi
  local json
  json=$(TERM_SESSION_ID="$TEST_TERM_SID" CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" list --json 2>&1) || {
    fail json_parses "list --json failed: $json"
    return
  }
  if printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass json_parses
  else
    fail json_parses "output is not valid JSON: $json"
  fi
}

# ---------------------------------------------------------------------------
# Test 8: --json without jq fails cleanly
# ---------------------------------------------------------------------------
test_json_without_jq_fails() {
  local stub_dir stub_path out rc
  stub_dir=$(mktemp -d)
  stub_path="${stub_dir}/jq"
  cat >"$stub_path" <<'EOF'
#!/bin/sh
exit 127
EOF
  chmod +x "$stub_path"

  out=$(PATH="${stub_dir}:${PATH}" TERM_SESSION_ID="$TEST_TERM_SID" \
    CLAUDE_CODE_SSE_PORT="$TEST_SSE_PORT" \
    "${CLAFF[@]}" list --json 2>&1)
  rc=$?
  rm -rf "$stub_dir"

  if [ "$rc" != "4" ]; then
    fail json_without_jq_fails "expected exit 4, got $rc; output: $out"
    return
  fi
  if [[ $out != *"jq"* ]]; then
    fail json_without_jq_fails "error did not mention jq: $out"
    return
  fi
  if printf '%s' "$out" | grep -qE '^\[|^\{'; then
    fail json_without_jq_fails "JSON-like output emitted: $out"
    return
  fi
  pass json_without_jq_fails
}

# ---------------------------------------------------------------------------
# Test 9: short options still work
# ---------------------------------------------------------------------------
test_short_options() {
  # Use a unique sid+port so we don't collide with test 1's instance.
  local short_sid="${TEST_TERM_SID}-short"
  local short_port
  short_port="$(printf '65%03d' $((RANDOM % 1000)))"
  local out long_out short_out
  out=$(TERM_SESSION_ID="$short_sid" CLAUDE_CODE_SSE_PORT="$short_port" \
    "${CLAFF[@]}" start -d 2>&1) || {
    fail short_options "start -d failed: $out"
    return
  }
  sleep 0.3
  long_out=$(TERM_SESSION_ID="$short_sid" CLAUDE_CODE_SSE_PORT="$short_port" \
    "${CLAFF[@]}" list 2>&1)
  short_out=$(TERM_SESSION_ID="$short_sid" CLAUDE_CODE_SSE_PORT="$short_port" \
    "${CLAFF[@]}" list -j 2>&1) || {
    fail short_options "list -j failed: $short_out"
    return
  }
  TERM_SESSION_ID="$short_sid" CLAUDE_CODE_SSE_PORT="$short_port" \
    "${CLAFF[@]}" kill-mine >/dev/null 2>&1 || true
  pkill -f -- "caffeinate--claffeinate--tab-${short_sid}-" 2>/dev/null || true
  if ! printf '%s' "$long_out" | grep -q "$short_sid"; then
    fail short_options "list (no flags) missing instance: $long_out"
    return
  fi
  if ! printf '%s' "$short_out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    fail short_options "list -j is not valid JSON: $short_out"
    return
  fi
  pass short_options
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
test_start_idempotent
test_list_shows_instance
test_kill_mine
test_kill_orphans_alive_noop
test_kill_orphans_reaps_fakes
test_claude_pid_resolves
test_json_parses
test_json_without_jq_fails
test_short_options

printf '\n%d passed, %d failed, %d skipped\n' "$PASSES" "$FAILS" "$SKIPS"
[ "$FAILS" -eq 0 ]
