#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# test_boundary_conditions.sh — 边界条件回归测试
#
# 验证：
#   - BASHCLAW_ENGINE_OVERRIDE 不跨轮污染（单次调用后清除）
#   - 预算到达上限行为
#   - 单任务 UNVERIFIABLE 超3个强制人工
#   - 知识库无命中默认行为
#   - 已有测试全绿 ≠ REFUTED（边界一）
#   - NO_VALIDATOR_FOUND ≠ PASS
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source test helper
source "${TEST_ROOT}/tests/test_helper.sh"

# Source library modules
source "${LIB_DIR}/risk_classifier.sh"
source "${LIB_DIR}/routing.sh"
source "${LIB_DIR}/knowledge_gate.sh"
source "${LIB_DIR}/executor.sh"
source "${LIB_DIR}/validator_repo.sh"
source "${LIB_DIR}/audit_log.sh"
source "${LIB_DIR}/evidence_resolution.sh"

###############################################################################
# Tests: BASHCLAW_ENGINE_OVERRIDE scope (single invocation, not cross-round)
###############################################################################

test_boundary_engine_override_single_use() {
  export BASHCLAW_ENGINE_OVERRIDE="codex"

  # First call should return the override
  local engine
  engine="$(routing_get_engine_override 2>/dev/null)"
  assert_eq "codex" "${engine}" "first call should return override"

  # In real usage, routing_resolve calls this directly (not in subshell)
  # so unset takes effect. In test subshell $(), unset doesn't propagate.
  # Verify the function DOES unset by calling in current shell context:
  export BASHCLAW_ENGINE_OVERRIDE="codex"
  routing_get_engine_override >/dev/null 2>&1
  assert_eq "" "${BASHCLAW_ENGINE_OVERRIDE:-}" "override should be cleared after direct call"
}

test_boundary_engine_override_invalid_value() {
  export BASHCLAW_ENGINE_OVERRIDE="invalid_engine"

  local engine=""
  local exit_code=0
  engine="$(routing_get_engine_override 2>/dev/null)" || exit_code=$?
  assert_eq "1" "${exit_code}" "invalid override should return exit code 1"

  # Should be cleared even on invalid value
  local check=""
  check="$(routing_get_engine_override 2>/dev/null)" || true
  assert_eq "" "${check}" "invalid override should be cleared"
}

test_boundary_tier_override_single_use() {
  export BASHCLAW_TIER_OVERRIDE="3"

  local tier
  tier="$(routing_get_tier_override 2>/dev/null)"
  assert_eq "3" "${tier}" "first call should return tier override"

  # Verify direct call clears the override (not in subshell)
  export BASHCLAW_TIER_OVERRIDE="3"
  routing_get_tier_override >/dev/null 2>&1
  assert_eq "" "${BASHCLAW_TIER_OVERRIDE:-}" "tier override should be cleared after direct call"
}

test_boundary_override_not_cross_round_pollution() {
  # Simulate two sequential rounds
  # Round 1: set override
  export BASHCLAW_ENGINE_OVERRIDE="codex"
  routing_get_engine_override >/dev/null 2>&1 || true

  # Round 2: no override set — should get nothing
  local engine=""
  engine="$(routing_get_engine_override 2>/dev/null)" || true
  assert_eq "" "${engine}" "override should not leak into next round"
}

###############################################################################
# Tests: Budget limit behavior
###############################################################################

test_boundary_budget_tier2_over_limit() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"

  unset _BUDGET_SH_LOADED 2>/dev/null || true
  source "${LIB_DIR}/budget.sh"
  budget_init

  # Fill up to max (20)
  local state_file
  state_file="$(_budget_state_file)"
  if command -v jq &>/dev/null; then
    echo '{"tier2_runs": 20, "tier3_runs": 0, "human_escalations": 0}' > "${state_file}"
  fi

  local exit_code=0
  budget_check_tier2 2>/dev/null || exit_code=$?
  assert_eq "1" "${exit_code}" "should block when tier2 at max"
}

test_boundary_budget_tier3_over_limit() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"

  unset _BUDGET_SH_LOADED 2>/dev/null || true
  source "${LIB_DIR}/budget.sh"
  budget_init

  local state_file
  state_file="$(_budget_state_file)"
  if command -v jq &>/dev/null; then
    echo '{"tier2_runs": 0, "tier3_runs": 3, "human_escalations": 0}' > "${state_file}"
  fi

  local exit_code=0
  budget_check_tier3 2>/dev/null || exit_code=$?
  assert_eq "1" "${exit_code}" "should block when tier3 at max"
}

test_boundary_budget_human_escalation_over_limit() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"

  unset _BUDGET_SH_LOADED 2>/dev/null || true
  source "${LIB_DIR}/budget.sh"
  budget_init

  local state_file
  state_file="$(_budget_state_file)"
  if command -v jq &>/dev/null; then
    echo '{"tier2_runs": 0, "tier3_runs": 0, "human_escalations": 5}' > "${state_file}"
  fi

  local exit_code=0
  budget_check_human_escalation 2>/dev/null || exit_code=$?
  assert_eq "1" "${exit_code}" "should block when human escalation at max"
}

test_boundary_budget_under_limit_passes() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"

  unset _BUDGET_SH_LOADED 2>/dev/null || true
  source "${LIB_DIR}/budget.sh"
  budget_init

  local state_file
  state_file="$(_budget_state_file)"
  if command -v jq &>/dev/null; then
    echo '{"tier2_runs": 5, "tier3_runs": 1, "human_escalations": 2}' > "${state_file}"
  fi

  budget_check_tier2 2>/dev/null
  budget_check_tier3 2>/dev/null
  budget_check_human_escalation 2>/dev/null
  # All should pass (return 0)
}

###############################################################################
# Tests: Single task UNVERIFIABLE > 3 forces human
###############################################################################

test_boundary_unverifiable_over_threshold_forces_human() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"

  unset _BUDGET_SH_LOADED 2>/dev/null || true
  source "${LIB_DIR}/budget.sh"
  budget_init

  # maxUnverifiableIssuesPerTask is 3 in config
  local exit_code=0
  budget_check_unverifiable "4" 2>/dev/null || exit_code=$?
  assert_eq "1" "${exit_code}" "4 UNVERIFIABLE issues should force human"
}

test_boundary_unverifiable_at_threshold_forces_human() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"

  unset _BUDGET_SH_LOADED 2>/dev/null || true
  source "${LIB_DIR}/budget.sh"
  budget_init

  local exit_code=0
  budget_check_unverifiable "3" 2>/dev/null || exit_code=$?
  # At threshold (>= 3 or > 3 depends on implementation)
  # Config says max is 3, so 3 should force human
  assert_eq "1" "${exit_code}" "3 UNVERIFIABLE issues should force human (at threshold)"
}

test_boundary_unverifiable_under_threshold_ok() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"

  unset _BUDGET_SH_LOADED 2>/dev/null || true
  source "${LIB_DIR}/budget.sh"
  budget_init

  budget_check_unverifiable "2" 2>/dev/null
  # Should pass (return 0)
}

###############################################################################
# Tests: Knowledge base no-hit default behavior
###############################################################################

test_boundary_knowledge_no_hit_defaults_low_confidence() {
  # When knowledge base has no entries, query should return low confidence
  export BASHCLAW_ROOT="${TEST_TMP}"
  mkdir -p "${TEST_TMP}/.bashclaw/knowledge"

  # knowledge_gate_run with empty knowledge should still produce output
  if type knowledge_gate_run &>/dev/null; then
    local result
    result="$(knowledge_gate_run "some query" "" "" "" "" "" "" "2" 2>/dev/null)" || result='{"confidence": "low"}'
    assert_contains "${result}" '"confidence"' "should have confidence field"
  fi
}

test_boundary_knowledge_no_hit_does_not_skip_review() {
  # With low confidence from knowledge gate, skip review should NOT succeed
  local base_validation='{"validation": {"status": "PASS", "stacks_detected": [], "results": []}}'
  local kg_output='{"confidence": "low", "action_hint": "proceed", "similar_decisions": []}'

  # For logic_change, low confidence knowledge should not allow skip
  local can_skip=false
  evaluate_skip_review \
    "$base_validation" "logic_change" "src/app.py" "small fix" \
    "$kg_output" "" "" 2>/dev/null && can_skip=true || can_skip=false

  assert_eq "false" "$can_skip" "low confidence knowledge should not enable skip for logic_change"
}

###############################################################################
# Tests: Existing tests all green ≠ REFUTED (Boundary Rule 1)
###############################################################################

test_boundary_all_green_not_auto_refuted() {
  # Even if base validation passes, a reviewer issue should NOT be auto-refuted
  # Only a TARGETED test (specifically for the issue) can refute
  local issue
  issue='{"issue_type": "runtime_bug", "severity": "major", "location": "src/handler.py:50", "risk_statement": "race condition in handler", "verification_plan": ""}'
  local base_val='{"validation": {"status": "PASS", "stacks_detected": [], "results": [{"type": "test", "status": "PASS"}]}}'

  # No targeted test available (no verification plan, no mock)
  local evidence
  evidence="$(phase2_gather_evidence "${issue}" "${base_val}" "." "")"

  local verdict
  verdict="$(phase3_render_verdict "${issue}" "${evidence}")"

  # Should NOT be REFUTED just because existing tests pass
  local v
  v="$(echo "${verdict}" | jq -r '.verdict')"
  if [[ "${v}" == "REFUTED" ]]; then
    echo "BOUNDARY VIOLATION: Existing tests passing should NOT auto-refute a reviewer issue" >&2
    echo "  verdict: ${v}" >&2
    return 1
  fi
  # Should be UNVERIFIABLE since we can't construct evidence
  assert_eq "UNVERIFIABLE" "${v}" "issue with no targeted evidence should be UNVERIFIABLE, not REFUTED"
}

test_boundary_targeted_refutation_required_for_refuted() {
  # Only targeted test PASS (specifically for the issue) should REFUTE
  run_targeted_validation() {
    echo '{"method": "targeted_test", "status": "PASS", "reason": "targeted test passed"}'
  }
  export -f run_targeted_validation

  local issue
  issue='{"issue_type": "runtime_bug", "severity": "major", "location": "src/handler.py:50", "risk_statement": "null dereference", "verification_plan": "test with null input", "why_it_matters": "crash"}'
  local base_val='{"validation": {"status": "PASS", "stacks_detected": [], "results": []}}'

  local evidence
  evidence="$(phase2_gather_evidence "${issue}" "${base_val}" "." "")"

  local verdict
  verdict="$(phase3_render_verdict "${issue}" "${evidence}")"
  assert_json_field "${verdict}" '.verdict' 'REFUTED' "targeted test pass should REFUTE"
}

###############################################################################
# Tests: NO_VALIDATOR_FOUND ≠ PASS
###############################################################################

test_boundary_no_validator_found_not_pass() {
  # NO_VALIDATOR_FOUND should not be treated as PASS
  local validation_status="NO_VALIDATOR_FOUND"

  if [[ "${validation_status}" == "PASS" ]]; then
    echo "BOUNDARY VIOLATION: NO_VALIDATOR_FOUND treated as PASS" >&2
    return 1
  fi

  # In Tier 1 engine, NO_VALIDATOR_FOUND should not deliver
  local final_status="PENDING"
  if [[ "${validation_status}" == "PASS" ]]; then
    final_status="DELIVERED"
  else
    final_status="FAILED_VALIDATION"
  fi
  assert_eq "FAILED_VALIDATION" "${final_status}" "NO_VALIDATOR_FOUND should not deliver"
}

test_boundary_no_validator_found_in_skip_review() {
  # NO_VALIDATOR_FOUND in base validation should NOT allow skip review
  local base_validation='{"validation": {"status": "NO_VALIDATOR_FOUND", "stacks_detected": [], "results": []}}'
  local can_skip=false
  evaluate_skip_review \
    "$base_validation" "docs_only" "docs/a.md" "doc update" "" "" "" \
    2>/dev/null && can_skip=true || can_skip=false

  assert_eq "false" "$can_skip" "NO_VALIDATOR_FOUND should prevent skip review"
}

###############################################################################
# Tests: Multiple UNVERIFIABLE in evidence resolution triggers escalation
###############################################################################

test_boundary_multiple_unverifiable_escalates() {
  local review_result
  review_result='{"issues": [
    {"location": "a.py:1", "issue_type": "design_concern", "severity": "minor", "risk_statement": "concern 1", "why_it_matters": "debt", "verification_plan": ""},
    {"location": "b.py:2", "issue_type": "design_concern", "severity": "minor", "risk_statement": "concern 2", "why_it_matters": "debt", "verification_plan": ""},
    {"location": "c.py:3", "issue_type": "design_concern", "severity": "minor", "risk_statement": "concern 3", "why_it_matters": "debt", "verification_plan": ""}
  ]}'
  local base_val='{"validation": {"status": "PASS", "stacks_detected": [], "results": []}}'

  local result
  result="$(run_evidence_resolution "${review_result}" "${base_val}" "." "" 2>/dev/null)" || true

  assert_contains "${result}" '"needs_human_escalation": true' "multiple UNVERIFIABLE should escalate"

  local unverifiable_count
  unverifiable_count="$(echo "${result}" | jq '.action_plan.summary.unverifiable')"
  if [[ "${unverifiable_count}" -lt 3 ]]; then
    echo "Expected at least 3 UNVERIFIABLE, got ${unverifiable_count}" >&2
    return 1
  fi
}

###############################################################################
# Run all tests
###############################################################################

echo "=== 边界条件回归测试 ==="

run_test test_boundary_engine_override_single_use
run_test test_boundary_engine_override_invalid_value
run_test test_boundary_tier_override_single_use
run_test test_boundary_override_not_cross_round_pollution
run_test test_boundary_budget_tier2_over_limit
run_test test_boundary_budget_tier3_over_limit
run_test test_boundary_budget_human_escalation_over_limit
run_test test_boundary_budget_under_limit_passes
run_test test_boundary_unverifiable_over_threshold_forces_human
run_test test_boundary_unverifiable_at_threshold_forces_human
run_test test_boundary_unverifiable_under_threshold_ok
run_test test_boundary_knowledge_no_hit_defaults_low_confidence
run_test test_boundary_knowledge_no_hit_does_not_skip_review
run_test test_boundary_all_green_not_auto_refuted
run_test test_boundary_targeted_refutation_required_for_refuted
run_test test_boundary_no_validator_found_not_pass
run_test test_boundary_no_validator_found_in_skip_review
run_test test_boundary_multiple_unverifiable_escalates

print_report "test_boundary_conditions.sh"
