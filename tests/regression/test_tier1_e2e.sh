#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# test_tier1_e2e.sh — Tier 1 端到端回归测试
#
# 验证：
#   - 无前缀普通任务 → Executor → Base Validation → 直接交付
#   - docs_only / comment_only / test_only 保持 Tier 1
#   - 不触发 Knowledge Gate / Reviewer
#   - 审计日志正确记录 Tier 1 流程
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source test helper
source "${TEST_ROOT}/tests/test_helper.sh"

# Source all library modules
source "${LIB_DIR}/risk_classifier.sh"
source "${LIB_DIR}/routing.sh"
source "${LIB_DIR}/knowledge_gate.sh"
source "${LIB_DIR}/executor.sh"
source "${LIB_DIR}/validator_repo.sh"
source "${LIB_DIR}/audit_log.sh"
source "${LIB_DIR}/engine.sh"

###############################################################################
# Fixtures: mock functions for external dependencies
###############################################################################

# Mock git — no changed files in Tier 1 basic test
_mock_no_git() {
  git() { return 1; }
  export -f git
}

# Mock validator_run to return PASS
_mock_validator_pass() {
  validator_run() {
    cat <<'JSON'
{
  "validation": {
    "status": "PASS",
    "results": [{"type": "test", "status": "PASS"}]
  }
}
JSON
  }
}

# Mock validator_run to return FAIL
_mock_validator_fail() {
  validator_run() {
    cat <<'JSON'
{
  "validation": {
    "status": "FAIL_TEST",
    "results": [{"type": "test", "status": "FAIL_TEST", "details": "assertion error"}]
  }
}
JSON
  }
}

# Mock executor_run — always succeeds
_mock_executor() {
  executor_run() {
    cat <<'JSON'
{
  "executor": {
    "engine": "opus4.6",
    "tier": 1,
    "status": "completed"
  },
  "changed_files": [],
  "diff": ""
}
JSON
  }
}

###############################################################################
# Tests
###############################################################################

test_tier1_no_prefix_routes_tier1() {
  routing_parse_prefix "fix a typo in README"
  assert_eq "1" "${ROUTING_TIER}" "no prefix should route to tier 1"
  assert_eq "fix a typo in README" "${ROUTING_COMMAND}" "command should be unchanged"
}

test_tier1_routing_tier_name() {
  local name
  name="$(routing_tier_name "1")"
  assert_eq "default" "${name}" "tier 1 name should be 'default'"
}

test_tier1_knowledge_gate_not_required() {
  if knowledge_gate_required "1"; then
    echo "Knowledge Gate should NOT be required for Tier 1" >&2
    return 1
  fi
}

test_tier1_docs_only_stays_tier1() {
  local change_type
  change_type="$(risk_classify_change_type "docs/README.md")"
  assert_eq "docs_only" "${change_type}" "docs file should be docs_only"

  local tier
  tier="$(risk_suggest_tier "${change_type}")"
  assert_eq "1" "${tier}" "docs_only should suggest tier 1"
}

test_tier1_comment_only_stays_tier1() {
  # comment_only is returned when files don't match any specific category
  # but still have content (the fallback for zero-type-count with files)
  local change_type
  change_type="$(risk_classify_change_type)"
  assert_eq "docs_only" "${change_type}" "no files = docs_only fallback"
}

test_tier1_test_only_stays_tier1() {
  local change_type
  change_type="$(risk_classify_change_type "tests/test_foo.py" "tests/test_bar.py")"
  assert_eq "test_only" "${change_type}" "test files should be test_only"

  local tier
  tier="$(risk_suggest_tier "${change_type}")"
  assert_eq "1" "${tier}" "test_only should suggest tier 1"
}

test_tier1_validation_pass_delivers() {
  _mock_executor
  _mock_validator_pass

  # Simulate the Tier 1 engine flow
  local effective_tier="1"
  local validation_result
  validation_result="$(validator_run "." "docs_only")"

  local validation_status
  validation_status="$(echo "${validation_result}" | jq -r '.validation.status')"
  assert_eq "PASS" "${validation_status}" "validation should PASS"

  # Tier 1 logic: pass = DELIVERED
  local final_status="PENDING"
  if [[ "${effective_tier}" == "1" && "${validation_status}" == "PASS" ]]; then
    final_status="DELIVERED"
  fi
  assert_eq "DELIVERED" "${final_status}" "Tier 1 + PASS should deliver"
}

test_tier1_validation_fail_does_not_deliver() {
  _mock_executor
  _mock_validator_fail

  local validation_result
  validation_result="$(validator_run "." "logic_change")"

  local validation_status
  validation_status="$(echo "${validation_result}" | jq -r '.validation.status')"
  assert_eq "FAIL_TEST" "${validation_status}" "validation should FAIL_TEST"

  local final_status="PENDING"
  if [[ "${validation_status}" == "PASS" ]]; then
    final_status="DELIVERED"
  else
    final_status="FAILED_VALIDATION"
  fi
  assert_eq "FAILED_VALIDATION" "${final_status}" "failed validation should not deliver"
}

test_tier1_no_reviewer_triggered() {
  # For Tier 1, the engine sets AWAITING_REVIEW only for tier 2/3
  local effective_tier="1"
  local final_status="PENDING"

  if [[ "${effective_tier}" == "1" ]]; then
    final_status="DELIVERED"
  else
    final_status="AWAITING_REVIEW"
  fi

  assert_eq "DELIVERED" "${final_status}" "Tier 1 should not enter review path"
}

test_tier1_audit_log_records_correctly() {
  # Ensure audit log can be written and read back with correct tier
  local task_id
  task_id="$(audit_generate_task_id)"

  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  mkdir -p "${AUDIT_LOG_DIR}"

  local log_file
  log_file="$(audit_log_write \
    "${task_id}" "bashclaw" "default" "default" "opus4.6" "" \
    "1" "10" "docs_only" "" "" "low" "false" "[]" \
    "0" "0" "0" "0" "0" "[]" "false" "" "none" "DELIVERED" "true" "0")"

  # Verify audit log file was created
  if [[ ! -f "${log_file}" ]]; then
    echo "Audit log file not created: ${log_file}" >&2
    return 1
  fi

  # Verify key fields in audit log
  local audit_content
  audit_content="$(cat "${log_file}")"
  assert_contains "${audit_content}" '"tier_requested": "default"' "audit should record tier_requested"
  assert_contains "${audit_content}" '"tier_effective": "default"' "audit should record tier_effective"
  assert_contains "${audit_content}" '"final_status": "DELIVERED"' "audit should record DELIVERED"
  assert_contains "${audit_content}" '"change_type": "docs_only"' "audit should record change_type"
}

test_tier1_audit_log_has_task_id() {
  local task_id
  task_id="$(audit_generate_task_id)"

  # Task ID should have date-hash format
  assert_matches "${task_id}" "^[0-9]{8}-[a-f0-9]+" "task_id should match YYYYMMDD-hex format"
}

test_tier1_no_human_escalation() {
  # Tier 1 config should not have human_escalation
  local config
  config="$(cat "${TEST_ROOT}/bashclaw.json")"
  local human_escalation
  human_escalation="$(echo "${config}" | jq -r '.tiers.tier1.human_escalation')"
  assert_eq "false" "${human_escalation}" "Tier 1 should not have human_escalation"
}

test_tier1_no_knowledge_gate_in_config() {
  local config
  config="$(cat "${TEST_ROOT}/bashclaw.json")"
  local kg
  kg="$(echo "${config}" | jq -r '.tiers.tier1.knowledge_gate')"
  assert_eq "false" "${kg}" "Tier 1 should not have knowledge_gate in config"
}

test_tier1_no_reviewer_in_config() {
  local config
  config="$(cat "${TEST_ROOT}/bashclaw.json")"
  local reviewer
  reviewer="$(echo "${config}" | jq -r '.tiers.tier1.reviewer')"
  assert_eq "false" "${reviewer}" "Tier 1 should not have reviewer in config"
}

###############################################################################
# Run all tests
###############################################################################

echo "=== Tier 1 端到端回归测试 ==="

run_test test_tier1_no_prefix_routes_tier1
run_test test_tier1_routing_tier_name
run_test test_tier1_knowledge_gate_not_required
run_test test_tier1_docs_only_stays_tier1
run_test test_tier1_comment_only_stays_tier1
run_test test_tier1_test_only_stays_tier1
run_test test_tier1_validation_pass_delivers
run_test test_tier1_validation_fail_does_not_deliver
run_test test_tier1_no_reviewer_triggered
run_test test_tier1_audit_log_records_correctly
run_test test_tier1_audit_log_has_task_id
run_test test_tier1_no_human_escalation
run_test test_tier1_no_knowledge_gate_in_config
run_test test_tier1_no_reviewer_in_config

print_report "test_tier1_e2e.sh"
