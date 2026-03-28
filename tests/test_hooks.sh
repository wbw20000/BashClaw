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
  hook_tag_commit "abc123d" "high" '["auth","token"]'
  local level
  level=$(sqlite3 "${BASHCLAW_DB}" "SELECT risk_level FROM commit_risk WHERE commit_hash='abc123d'")
  assert_eq "high" "${level}" "Commit should be tagged high"
}

test_hook_get_high_risk_commits() {
  _load_hooks
  hook_tag_commit "aaa1111" "high" '["auth"]'
  hook_tag_commit "bbb2222" "low" '[]'
  hook_tag_commit "ccc3333" "medium" '["deploy"]'
  local result
  result=$(hook_get_high_risk_commits)
  assert_contains "${result}" "aaa1111" "Should include high-risk commit"
  assert_contains "${result}" "ccc3333" "Should include medium-risk commit"
  assert_not_contains "${result}" "bbb2222" "Should not include low-risk commit"
}

test_hook_clear_pushed_commits() {
  _load_hooks
  hook_tag_commit "ddd4444" "high" '["migration"]'
  hook_clear_pushed_commits
  local result
  result=$(hook_get_high_risk_commits)
  # After clearing, no unreviewed commits
  [[ "${result}" == "[]" || -z "${result}" ]] || {
    echo "Should have no unreviewed commits after clear, got: ${result}" >&2; return 1
  }
}

test_hook_classify_rejects_invalid_hash() {
  _load_hooks
  # Attempt command injection via commit hash — should fail
  local exit_code=0
  hook_classify_commit "not-a-valid-hash!" >/dev/null 2>&1 || exit_code=$?
  [[ ${exit_code} -ne 0 ]] || {
    echo "Should reject invalid commit hash" >&2; return 1
  }
  # Test with spaces (potential command injection)
  exit_code=0
  hook_classify_commit "abc123 ; rm -rf /" >/dev/null 2>&1 || exit_code=$?
  [[ ${exit_code} -ne 0 ]] || {
    echo "Should reject hash with spaces" >&2; return 1
  }
}

test_hook_tag_rejects_invalid_hash() {
  _load_hooks
  local exit_code=0
  hook_tag_commit "invalid!hash" "high" '["auth"]' >/dev/null 2>&1 || exit_code=$?
  [[ ${exit_code} -ne 0 ]] || {
    echo "Should reject invalid commit hash in tag" >&2; return 1
  }
}

echo "== test_hooks.sh =="
run_test test_hook_tag_commit
run_test test_hook_get_high_risk_commits
run_test test_hook_clear_pushed_commits
run_test test_hook_classify_rejects_invalid_hash
run_test test_hook_tag_rejects_invalid_hash
print_report "test_hooks.sh"
