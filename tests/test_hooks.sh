#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

export PATH="/c/sqlite:${PATH}"

_load_hooks() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  mkdir -p "${TEST_TMP}/lib"
  cp "${LIB_DIR}/store_schema.sql" "${TEST_TMP}/lib/"
  cp "${LIB_DIR}/store.sh" "${TEST_TMP}/lib/"
  cp "${LIB_DIR}/hook_helpers.sh" "${TEST_TMP}/lib/"
  source "${LIB_DIR}/store.sh"
  store_init "${TEST_TMP}/.bashclaw"
  source "${LIB_DIR}/hook_helpers.sh"
}

test_hook_tag_commit() {
  _load_hooks
  hook_tag_commit "abc123def" "high" '["auth","token"]'
  local level
  level=$(sqlite3 "${BASHCLAW_DB}" "SELECT risk_level FROM commit_risk WHERE commit_hash='abc123def'")
  assert_eq "high" "${level}" "Commit should be tagged high"
}

test_hook_get_high_risk_commits() {
  _load_hooks
  hook_tag_commit "aaa111" "high" '["auth"]'
  hook_tag_commit "bbb222" "low" '[]'
  hook_tag_commit "ccc333" "medium" '["deploy"]'
  local result
  result=$(hook_get_high_risk_commits)
  assert_contains "${result}" "aaa111" "Should include high-risk commit"
  assert_contains "${result}" "ccc333" "Should include medium-risk commit"
  assert_not_contains "${result}" "bbb222" "Should not include low-risk commit"
}

test_hook_clear_pushed_commits() {
  _load_hooks
  hook_tag_commit "ddd444" "high" '["migration"]'
  hook_clear_pushed_commits
  local result
  result=$(hook_get_high_risk_commits)
  # After clearing, no unreviewed commits
  [[ "${result}" == "[]" || -z "${result}" ]] || {
    echo "Should have no unreviewed commits after clear, got: ${result}" >&2; return 1
  }
}

echo "== test_hooks.sh =="
run_test test_hook_tag_commit
run_test test_hook_get_high_risk_commits
run_test test_hook_clear_pushed_commits
print_report "test_hooks.sh"
