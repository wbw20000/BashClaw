#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

# Ensure sqlite3 is on PATH (Windows: /c/sqlite)
export PATH="/c/sqlite:${PATH}"

_load_bashclaw() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export BASHCLAW_LIB="${LIB_DIR}"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  export BASHCLAW_LOG_LEVEL="error"
  source "${TEST_ROOT}/bashclaw.sh"
}

test_stats_command_exists() {
  _load_bashclaw
  local output
  output=$(bashclaw_main stats 2>&1) || true
  assert_not_contains "${output}" "Unknown command" "stats should be recognized"
}

test_stats_returns_json() {
  _load_bashclaw
  local output
  output=$(bashclaw_main stats 2>/dev/null) || true
  echo "${output}" | jq . > /dev/null 2>&1 || {
    echo "stats should output valid JSON, got: ${output}" >&2; return 1
  }
}

test_stats_includes_knowledge_metrics() {
  _load_bashclaw
  source "${LIB_DIR}/store.sh"
  store_init "${TEST_TMP}/.bashclaw"
  store_card_insert "Test" "test" "do X" "because Y" '["test"]' "logic_bug"
  local output
  output=$(bashclaw_main stats 2>/dev/null) || true
  local cards
  cards=$(echo "${output}" | jq -r '.active_cards // 0')
  assert_eq "1" "${cards}" "Should show 1 active card"
}

test_stats_in_usage() {
  _load_bashclaw
  local output
  output=$(bashclaw_main --help 2>&1) || true
  assert_contains "${output}" "stats" "Usage should mention stats"
}

echo "== test_stats_command.sh =="
run_test test_stats_command_exists
run_test test_stats_returns_json
run_test test_stats_includes_knowledge_metrics
run_test test_stats_in_usage
print_report "test_stats_command.sh"
