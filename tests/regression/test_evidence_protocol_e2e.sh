#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# test_evidence_protocol_e2e.sh — 证据裁决协议端到端回归测试
#
# 验证：
#   - 完整 CONFIRMED 路径（targeted test → 失败 → CONFIRMED）
#   - 完整 REFUTED 路径（targeted test → 通过 → REFUTED）
#   - UNVERIFIABLE → Human Escalation 路径
#   - REQUIREMENT_CONFLICT → Human Escalation 路径
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source test helper
source "${TEST_ROOT}/tests/test_helper.sh"

# Source library modules
source "${LIB_DIR}/risk_classifier.sh"
source "${LIB_DIR}/knowledge_gate.sh"
source "${LIB_DIR}/audit_log.sh"
source "${LIB_DIR}/evidence_resolution.sh"

###############################################################################
# Fixtures
###############################################################################

_fixture_runtime_bug_issue() {
  cat <<'JSON'
{
  "location": "auth/session.py:84",
  "issue_type": "runtime_bug",
  "severity": "major",
  "risk_statement": "Null pointer when session is expired",
  "why_it_matters": "Production crash on expired sessions",
  "verification_plan": "Test with expired session token"
}
JSON
}

_fixture_security_issue() {
  cat <<'JSON'
{
  "location": "auth/token.py:42",
  "issue_type": "security_risk",
  "severity": "critical",
  "risk_statement": "Token not validated against tenant boundary",
  "why_it_matters": "Cross-tenant session hijacking possible",
  "verification_plan": "Test cross-tenant access with tenant A token on tenant B resource"
}
JSON
}

_fixture_design_concern_issue() {
  cat <<'JSON'
{
  "location": "src/service.py:100",
  "issue_type": "design_concern",
  "severity": "minor",
  "risk_statement": "This pattern may be hard to maintain in future",
  "why_it_matters": "Tech debt accumulation",
  "verification_plan": ""
}
JSON
}

_fixture_requirement_conflict_issue() {
  cat <<'JSON'
{
  "location": "src/access.py:20",
  "issue_type": "requirement_conflict",
  "severity": "major",
  "risk_statement": "Business rule says allow, security policy says deny",
  "why_it_matters": "Contradicting requirements",
  "verification_plan": ""
}
JSON
}

# 修复 Critical #2: 测试 fixture 与 validator_run 实际输出结构对齐
_fixture_base_validation_pass() {
  echo '{"validation": {"status": "PASS", "stacks_detected": [], "results": [{"type": "test", "status": "PASS"}]}}'
}

###############################################################################
# Tests: Phase 1 — Collect Issues
###############################################################################

test_evidence_phase1_collects_issues() {
  local review_result='{"issues": [{"location": "a.py:1", "issue_type": "runtime_bug"}]}'
  local issues
  issues="$(phase1_collect_issues "${review_result}")"
  local count
  count="$(echo "${issues}" | jq 'length')"
  assert_eq "1" "${count}" "should collect 1 issue"
}

test_evidence_phase1_no_issues_returns_empty() {
  local review_result='{"issues": []}'
  local exit_code=0
  phase1_collect_issues "${review_result}" >/dev/null || exit_code=$?
  assert_eq "1" "${exit_code}" "should return 1 when no issues"
}

###############################################################################
# Tests: CONFIRMED path (targeted test fails → issue confirmed)
###############################################################################

test_evidence_confirmed_via_targeted_test_fail() {
  # Mock targeted validation to return FAIL
  run_targeted_validation() {
    echo '{"method": "targeted_test", "status": "FAIL", "reason": "test confirmed the bug"}'
  }
  export -f run_targeted_validation

  local issue
  issue="$(_fixture_runtime_bug_issue)"
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  # Gather evidence
  local evidence
  evidence="$(phase2_gather_evidence "${issue}" "${base_val}" "." "")"

  # Render verdict
  local verdict
  verdict="$(phase3_render_verdict "${issue}" "${evidence}")"

  assert_json_field "${verdict}" '.verdict' 'CONFIRMED' "should be CONFIRMED when targeted test fails"
  assert_json_field "${verdict}" '.action' 'executor_must_fix' "action should be executor_must_fix"
}

test_evidence_confirmed_full_pipeline() {
  run_targeted_validation() {
    echo '{"method": "targeted_test", "status": "FAIL", "reason": "bug reproduced"}'
  }
  export -f run_targeted_validation

  local review_result
  review_result='{"issues": ['"$(_fixture_runtime_bug_issue)"']}'
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  local result
  result="$(run_evidence_resolution "${review_result}" "${base_val}" "." "" 2>/dev/null)" || true

  assert_contains "${result}" '"verdict": "CONFIRMED"' "full pipeline should produce CONFIRMED"
  assert_contains "${result}" '"needs_executor_fix": true' "should need executor fix"
}

###############################################################################
# Tests: REFUTED path (targeted test passes → issue refuted)
###############################################################################

test_evidence_refuted_via_targeted_test_pass() {
  # Mock targeted validation to return PASS
  run_targeted_validation() {
    echo '{"method": "targeted_test", "status": "PASS", "reason": "issue not reproduced"}'
  }
  export -f run_targeted_validation

  local issue
  issue="$(_fixture_runtime_bug_issue)"
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  local evidence
  evidence="$(phase2_gather_evidence "${issue}" "${base_val}" "." "")"

  local verdict
  verdict="$(phase3_render_verdict "${issue}" "${evidence}")"

  assert_json_field "${verdict}" '.verdict' 'REFUTED' "should be REFUTED when targeted test passes"
  assert_json_field "${verdict}" '.action' 'record_and_skip' "action should be record_and_skip"
}

test_evidence_refuted_full_pipeline() {
  run_targeted_validation() {
    echo '{"method": "targeted_test", "status": "PASS", "reason": "test passed"}'
  }
  export -f run_targeted_validation

  local review_result
  review_result='{"issues": ['"$(_fixture_runtime_bug_issue)"']}'
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  local result
  result="$(run_evidence_resolution "${review_result}" "${base_val}" "." "" 2>/dev/null)" || true

  assert_contains "${result}" '"verdict": "REFUTED"' "full pipeline should produce REFUTED"
  assert_contains "${result}" '"needs_executor_fix": false' "should not need executor fix"
}

###############################################################################
# Tests: UNVERIFIABLE → Human Escalation
###############################################################################

test_evidence_unverifiable_design_concern() {
  local issue
  issue="$(_fixture_design_concern_issue)"
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  local evidence
  evidence="$(phase2_gather_evidence "${issue}" "${base_val}" "." "")"

  local verdict
  verdict="$(phase3_render_verdict "${issue}" "${evidence}")"

  assert_json_field "${verdict}" '.verdict' 'UNVERIFIABLE' "design concern should be UNVERIFIABLE"
  assert_json_field "${verdict}" '.action' 'escalate_human' "action should be escalate_human"
}

test_evidence_unverifiable_triggers_escalation_in_pipeline() {
  local review_result
  review_result='{"issues": ['"$(_fixture_design_concern_issue)"']}'
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  local result
  local exit_code=0
  result="$(run_evidence_resolution "${review_result}" "${base_val}" "." "" 2>/dev/null)" || exit_code=$?

  assert_contains "${result}" '"needs_human_escalation": true' "UNVERIFIABLE should trigger human escalation"
  # Exit code 1 means needs human escalation
  assert_eq "1" "${exit_code}" "should return exit code 1 for human escalation"
}

###############################################################################
# Tests: REQUIREMENT_CONFLICT → Human Escalation
###############################################################################

test_evidence_requirement_conflict_always_escalates() {
  local issue
  issue="$(_fixture_requirement_conflict_issue)"
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  local evidence
  evidence="$(phase2_gather_evidence "${issue}" "${base_val}" "." "")"

  local verdict
  verdict="$(phase3_render_verdict "${issue}" "${evidence}")"

  assert_json_field "${verdict}" '.verdict' 'REQUIREMENT_CONFLICT' "should be REQUIREMENT_CONFLICT"
  assert_json_field "${verdict}" '.action' 'escalate_human' "action should be escalate_human"
}

test_evidence_requirement_conflict_full_pipeline() {
  local review_result
  review_result='{"issues": ['"$(_fixture_requirement_conflict_issue)"']}'
  local base_val
  base_val="$(_fixture_base_validation_pass)"

  local result
  result="$(run_evidence_resolution "${review_result}" "${base_val}" "." "" 2>/dev/null)" || true

  assert_contains "${result}" '"verdict": "REQUIREMENT_CONFLICT"' "pipeline should produce REQUIREMENT_CONFLICT"
  assert_contains "${result}" '"needs_human_escalation": true' "should need human escalation"
}

###############################################################################
# Tests: Phase 4 — action plan aggregation
###############################################################################

test_evidence_phase4_mixed_verdicts() {
  local verdicts
  verdicts='[
    {"verdict": "CONFIRMED", "issue": {"location": "a.py:1", "issue_type": "runtime_bug", "severity": "major", "risk_statement": "bug"}, "evidence": [], "action": "executor_must_fix"},
    {"verdict": "REFUTED", "issue": {"location": "b.py:2", "issue_type": "logic_bug", "severity": "minor", "risk_statement": "false alarm"}, "evidence": [], "action": "record_and_skip"},
    {"verdict": "UNVERIFIABLE", "issue": {"location": "c.py:3", "issue_type": "design_concern", "severity": "minor", "risk_statement": "unclear"}, "evidence": [], "action": "escalate_human"}
  ]'

  local action_plan
  action_plan="$(phase4_drive_actions "${verdicts}")"

  assert_json_field "${action_plan}" '.summary.confirmed' '1' "should have 1 confirmed"
  assert_json_field "${action_plan}" '.summary.refuted' '1' "should have 1 refuted"
  assert_json_field "${action_plan}" '.summary.unverifiable' '1' "should have 1 unverifiable"
  assert_json_field "${action_plan}" '.needs_executor_fix' 'true' "should need executor fix"
  assert_json_field "${action_plan}" '.needs_human_escalation' 'true' "should need human escalation"
}

test_evidence_phase4_all_refuted_no_action() {
  local verdicts
  verdicts='[
    {"verdict": "REFUTED", "issue": {"location": "a.py:1", "issue_type": "runtime_bug", "severity": "minor", "risk_statement": "false alarm"}, "evidence": [], "action": "record_and_skip"}
  ]'

  local action_plan
  action_plan="$(phase4_drive_actions "${verdicts}")"

  assert_json_field "${action_plan}" '.needs_executor_fix' 'false' "all refuted should not need fix"
  assert_json_field "${action_plan}" '.needs_human_escalation' 'false' "all refuted should not need escalation"
}

###############################################################################
# Tests: 5 evidence gathering methods
###############################################################################

test_evidence_attempt_targeted_test_no_plan() {
  local issue='{"issue_type": "runtime_bug", "verification_plan": ""}'
  local result
  result="$(attempt_targeted_test "${issue}" "." 2>/dev/null)" || true
  assert_contains "${result}" '"NOT_APPLICABLE"' "no verification plan should be NOT_APPLICABLE"
}

test_evidence_attempt_static_rule_inconclusive() {
  local issue='{"issue_type": "security_risk", "location": "auth/foo.py:10"}'
  local base_val='{"validation": {"status": "PASS", "stacks_detected": [], "results": []}}'
  local result
  result="$(attempt_static_rule "${issue}" "${base_val}" 2>/dev/null)" || true
  assert_contains "${result}" '"INCONCLUSIVE"' "security_risk with no findings should be INCONCLUSIVE"
}

test_evidence_attempt_repro_not_applicable() {
  local issue='{"issue_type": "design_concern"}'
  local result
  result="$(attempt_repro_step "${issue}" "." 2>/dev/null)" || true
  assert_contains "${result}" '"NOT_APPLICABLE"' "design_concern should not use repro"
}

test_evidence_attempt_historical_no_match() {
  local issue='{"risk_statement": "something unique", "issue_type": "runtime_bug", "location": "x.py:1"}'
  local result
  result="$(attempt_historical_match "${issue}" 2>/dev/null)" || true
  assert_contains "${result}" '"NO_MATCH"' "should have no historical match"
}

test_evidence_attempt_risk_policy_requirement_conflict() {
  local issue='{"issue_type": "requirement_conflict", "location": "x.py:1"}'
  local result
  result="$(attempt_risk_policy "${issue}" "" 2>/dev/null)" || true
  assert_contains "${result}" '"MATCHED"' "requirement_conflict should match policy"
  assert_contains "${result}" '"REQUIREMENT_CONFLICT_ESCALATION"' "should match escalation policy"
}

test_evidence_attempt_risk_policy_security_in_auth() {
  local issue='{"issue_type": "security_risk", "location": "auth/session.py:10"}'
  local result
  result="$(attempt_risk_policy "${issue}" "" 2>/dev/null)" || true
  assert_contains "${result}" '"MATCHED"' "security_risk in auth should match"
  assert_contains "${result}" '"SECURITY_IN_AUTH_PATH"' "should match auth security policy"
}

###############################################################################
# Run all tests
###############################################################################

echo "=== 证据裁决协议端到端回归测试 ==="

run_test test_evidence_phase1_collects_issues
run_test test_evidence_phase1_no_issues_returns_empty
run_test test_evidence_confirmed_via_targeted_test_fail
run_test test_evidence_confirmed_full_pipeline
run_test test_evidence_refuted_via_targeted_test_pass
run_test test_evidence_refuted_full_pipeline
run_test test_evidence_unverifiable_design_concern
run_test test_evidence_unverifiable_triggers_escalation_in_pipeline
run_test test_evidence_requirement_conflict_always_escalates
run_test test_evidence_requirement_conflict_full_pipeline
run_test test_evidence_phase4_mixed_verdicts
run_test test_evidence_phase4_all_refuted_no_action
run_test test_evidence_attempt_targeted_test_no_plan
run_test test_evidence_attempt_static_rule_inconclusive
run_test test_evidence_attempt_repro_not_applicable
run_test test_evidence_attempt_historical_no_match
run_test test_evidence_attempt_risk_policy_requirement_conflict
run_test test_evidence_attempt_risk_policy_security_in_auth

print_report "test_evidence_protocol_e2e.sh"
