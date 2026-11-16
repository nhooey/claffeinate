#!/usr/bin/env bash
#
# Tests for scripts/claff-dev's argument parsing, through --dry-run and
# --help, so nothing it would run is run. Prints "PASS <name>" or
# "FAIL <name>: <reason>"; exits non-zero if any test fails.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL=(bash "$ROOT/scripts/claff-dev")
failures=0

pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# expect NAME STATUS EXPECTED_STDOUT ARGS...: run the tool with ARGS and
# compare its exit status and stdout.
expect() {
  local name="$1" status="$2" want="$3" out rc
  shift 3
  out=$("${TOOL[@]}" "$@" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne "$status" ]; then
    fail "$name" "exit $rc, want $status"
  elif [ "$out" != "$want" ]; then
    fail "$name" "stdout '$out', want '$want'"
  else
    pass "$name"
  fi
}

# expect_status NAME STATUS ARGS...: compare only the exit status.
expect_status() {
  local name="$1" status="$2" rc
  shift 2
  "${TOOL[@]}" "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$status" ]; then pass "$name"; else fail "$name" "exit $rc, want $status"; fi
}

q() { printf '%q' "$1"; }
R=$(q "$ROOT")

help=$("${TOOL[@]}" --help)
missing=""
for token in lint test build validate-plugin try-plugin --dry-run --help; do
  grep -qE -- "^  (-[a-z], )?$token( |$)" <<<"$help" || missing="$missing $token"
done
if [ -z "$missing" ]; then pass help_lists_tokens; else fail help_lists_tokens "missing:$missing"; fi

for token in lint test build validate-plugin try-plugin; do
  if out=$("${TOOL[@]}" "$token" --help) && grep -q "^Usage: claff-dev $token" <<<"$out"; then
    pass "command_help_$token"
  else
    fail "command_help_$token" "got '$out'"
  fi
done

expect dry_run_lint 0 \
  "shellcheck $R/bin/claffeinate $R/hooks/claffeinate-hook.sh $R/scripts/claff-dev $R/tests/test.sh $R/tests/claff-dev.sh" \
  --dry-run lint
expect dry_run_test_all 0 "bash $R/tests/test.sh" -n test
expect dry_run_test_named 0 "bash $R/tests/test.sh start_basic status_json" \
  -n test start_basic status_json
expect dry_run_build 0 "nix build $R -L" -n build -L
expect dry_run_validate_plugin 0 "claude plugin validate --strict $R" -n validate-plugin
expect dry_run_try_plugin_quotes 0 "claude --plugin-dir $R -p $(q 'say "hi" now')" \
  -n try-plugin 'say "hi" now'
expect dry_run_after_double_dash 0 "bash $R/tests/test.sh" -n -- test

expect_status no_command 2
expect_status unknown_command 2 bogus
expect_status unknown_command_help 2 bogus --help
expect_status unknown_option 2 --bogus lint
expect_status lint_rejects_args 2 -n lint extra
expect_status validate_plugin_rejects_args 2 -n validate-plugin extra
expect_status try_plugin_needs_prompt 2 -n try-plugin

[ "$failures" -eq 0 ]
