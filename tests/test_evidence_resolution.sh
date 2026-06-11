#!/usr/bin/env bash
###############################################################################
# test_evidence_resolution.sh — 证据驱动裁决协议测试（最关键）
#
# 测试清单（对照统一实施文档第11节）：
#   - CONFIRMED路径
#   - REFUTED路径（必须是针对性反证，不是"测试全绿"）
#   - UNVERIFIABLE路径
#   - REQUIREMENT_CONFLICT路径
#   - 边界：已有测试全绿不等于REFUTED
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/evidence_resolution.sh"

###############################################################################
# 辅助：构造测试数据
###############################################################################
_make_issue() {
  local issue_type="${1:-logic_bug}"
  local severity="${2:-major}"
  local location="${3:-file.py:10}"
  echo "{\"location\":\"${location}\",\"issue_type\":\"${issue_type}\",\"severity\":\"${severity}\",\"risk_statement\":\"Test issue\",\"why_it_matters\":\"Test impact\",\"verification_plan\":\"Run targeted test with specific inputs\"}"
}

###############################################################################
# 1. CONFIRMED 路径
###############################################################################
test_verdict_confirmed_on_targeted_test_failure() {
  local issue
  issue=$(_make_issue "logic_bug" "major")
  # 模拟：targeted test 失败 → issue 被确认
  local evidence='[{"method":"targeted_test","status":"FAIL"},{"method":"static_rule","status":"NO_FINDINGS"},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "CONFIRMED" "targeted test 失败应导致CONFIRMED"
  assert_json_field "${result}" ".action" "executor_must_fix" "CONFIRMED的action应为executor_must_fix"
}

test_verdict_confirmed_on_static_finding() {
  local issue
  issue=$(_make_issue "logic_bug" "major")
  # 模拟：静态分析发现问题
  local evidence='[{"method":"targeted_test","status":"NOT_AVAILABLE"},{"method":"static_rule","status":"FOUND","supports_issue":true},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "CONFIRMED" "静态分析发现应导致CONFIRMED"
}

test_verdict_confirmed_on_repro() {
  local issue
  issue=$(_make_issue "runtime_bug" "critical")
  # 模拟：复现成功
  local evidence='[{"method":"targeted_test","status":"NOT_AVAILABLE"},{"method":"static_rule","status":"INCONCLUSIVE"},{"method":"repro_step","status":"REPRODUCED"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "CONFIRMED" "复现成功应导致CONFIRMED"
}

###############################################################################
# 2. REFUTED 路径（必须是针对性反证）
###############################################################################
test_verdict_refuted_on_targeted_test_pass() {
  local issue
  issue=$(_make_issue "logic_bug" "major")
  # 模拟：针对性测试通过（专门为该issue设计的测试）
  local evidence='[{"method":"targeted_test","status":"PASS"},{"method":"static_rule","status":"NO_FINDINGS"},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "REFUTED" "针对性测试通过应导致REFUTED"
  assert_json_field "${result}" ".action" "record_and_skip" "REFUTED的action应为record_and_skip"
}

test_refuted_downgraded_with_historical_conflict() {
  local issue
  issue=$(_make_issue "security_risk" "major")
  # 模拟：针对性测试通过但历史知识支持该issue → 应降级为UNVERIFIABLE
  local evidence='[{"method":"targeted_test","status":"PASS"},{"method":"static_rule","status":"NO_FINDINGS"},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"FOUND","confidence":"high"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "UNVERIFIABLE" "有历史证据冲突时应降级为UNVERIFIABLE（边界规则2）"
}

test_refuted_downgraded_with_policy_conflict() {
  local issue
  issue=$(_make_issue "security_risk" "major" "auth/session.py:84")
  # 模拟：针对性测试通过但风险策略匹配
  local evidence='[{"method":"targeted_test","status":"PASS"},{"method":"static_rule","status":"NO_FINDINGS"},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"MATCHED","policies":[{"policy":"SECURITY_IN_AUTH_PATH","action":"supports_issue"}]}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "UNVERIFIABLE" "有策略冲突时应降级为UNVERIFIABLE"
}

###############################################################################
# 3. UNVERIFIABLE 路径
###############################################################################
test_verdict_unverifiable_all_inconclusive() {
  local issue
  issue=$(_make_issue "design_concern" "minor")
  # 所有证据都不确定
  local evidence='[{"method":"targeted_test","status":"NOT_AVAILABLE"},{"method":"static_rule","status":"INCONCLUSIVE"},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "UNVERIFIABLE" "全部不确定应为UNVERIFIABLE"
  assert_json_field "${result}" ".action" "escalate_human" "UNVERIFIABLE应升级人工"
}

test_verdict_unverifiable_no_evidence() {
  local issue
  issue=$(_make_issue "design_concern" "major")
  local evidence='[{"method":"targeted_test","status":"FAILED"},{"method":"static_rule","status":"FAILED"},{"method":"repro_step","status":"FAILED"},{"method":"historical_decision_match","status":"FAILED"},{"method":"risk_policy_match","status":"FAILED"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "UNVERIFIABLE" "所有证据收集失败应为UNVERIFIABLE"
}

###############################################################################
# 4. REQUIREMENT_CONFLICT 路径
###############################################################################
test_verdict_requirement_conflict() {
  local issue
  issue=$(_make_issue "requirement_conflict" "major")
  # requirement_conflict 无论证据如何都直接升级
  local evidence='[{"method":"targeted_test","status":"PASS"},{"method":"static_rule","status":"NO_FINDINGS"},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "REQUIREMENT_CONFLICT" "requirement_conflict应直接判定"
  assert_json_field "${result}" ".action" "escalate_human" "REQUIREMENT_CONFLICT应升级人工"
}

test_requirement_conflict_ignores_evidence() {
  local issue
  issue=$(_make_issue "requirement_conflict" "critical")
  # 即使有确认性证据，requirement_conflict仍直接升级
  local evidence='[{"method":"targeted_test","status":"FAIL"},{"method":"static_rule","status":"FOUND","supports_issue":true},{"method":"repro_step","status":"REPRODUCED"},{"method":"historical_decision_match","status":"FOUND"},{"method":"risk_policy_match","status":"MATCHED"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  assert_json_field "${result}" ".verdict" "REQUIREMENT_CONFLICT" "requirement_conflict即使有证据也应直接判定"
}

###############################################################################
# 5. 边界：已有测试全绿不等于REFUTED
###############################################################################
test_existing_tests_pass_not_refuted() {
  local issue
  issue=$(_make_issue "security_risk" "major")
  # 模拟：只有静态分析无发现（相当于"已有测试全绿"），没有针对性反证
  # 这不应构成REFUTED
  local evidence='[{"method":"targeted_test","status":"NOT_AVAILABLE"},{"method":"static_rule","status":"NO_FINDINGS","reason":"no relevant static analysis findings"},{"method":"repro_step","status":"NOT_APPLICABLE"},{"method":"historical_decision_match","status":"NO_MATCH"},{"method":"risk_policy_match","status":"NO_MATCH"}]'
  local result
  result=$(phase3_render_verdict "${issue}" "${evidence}")
  local verdict
  verdict=$(echo "${result}" | jq -r '.verdict')
  [[ "${verdict}" != "REFUTED" ]] || {
    echo "FAIL: 没有针对性反证不应判定为REFUTED（边界规则1）" >&2
    return 1
  }
  assert_eq "UNVERIFIABLE" "${verdict}" "没有针对性反证应为UNVERIFIABLE"
}

###############################################################################
# 6. Phase 1 — 收集 issues
###############################################################################
test_phase1_extracts_issues() {
  local review_result='{"issues":[{"location":"a.py:1","issue_type":"logic_bug"},{"location":"b.py:2","issue_type":"security_risk"}]}'
  local issues
  issues=$(phase1_collect_issues "${review_result}")
  local count
  count=$(echo "${issues}" | jq 'length')
  assert_eq "2" "${count}" "应提取2个issues"
}

test_phase1_no_issues_returns_error() {
  local review_result='{"issues":[]}'
  local result=0
  phase1_collect_issues "${review_result}" >/dev/null || result=$?
  assert_eq "1" "${result}" "无issues应返回错误码1"
}

###############################################################################
# 7. Phase 4 — 驱动动作
###############################################################################
test_phase4_action_plan_structure() {
  local verdicts='[
    {"verdict":"CONFIRMED","issue":{"location":"a.py:1","issue_type":"logic_bug","severity":"major","risk_statement":"test"},"evidence":[],"action":"executor_must_fix"},
    {"verdict":"REFUTED","issue":{"location":"b.py:2","issue_type":"design_concern","risk_statement":"test"},"evidence":[],"reasoning":"refuted","action":"record_and_skip"},
    {"verdict":"UNVERIFIABLE","issue":{"location":"c.py:3","issue_type":"security_risk","severity":"critical","risk_statement":"test"},"evidence":[],"reasoning":"unverifiable","action":"escalate_human"}
  ]'
  local plan
  plan=$(phase4_drive_actions "${verdicts}")
  assert_json_field "${plan}" ".summary.confirmed" "1" "应有1个CONFIRMED"
  assert_json_field "${plan}" ".summary.refuted" "1" "应有1个REFUTED"
  assert_json_field "${plan}" ".summary.unverifiable" "1" "应有1个UNVERIFIABLE"
  assert_json_field "${plan}" ".needs_executor_fix" "true" "有CONFIRMED时应需要修复"
  assert_json_field "${plan}" ".needs_human_escalation" "true" "有UNVERIFIABLE时应需要人工"
}

test_phase4_no_escalation_when_all_resolved() {
  local verdicts='[
    {"verdict":"CONFIRMED","issue":{"location":"a.py:1","issue_type":"logic_bug","severity":"minor","risk_statement":"test"},"evidence":[],"action":"executor_must_fix"},
    {"verdict":"REFUTED","issue":{"location":"b.py:2","issue_type":"design_concern","risk_statement":"test"},"evidence":[],"reasoning":"refuted","action":"record_and_skip"}
  ]'
  local plan
  plan=$(phase4_drive_actions "${verdicts}")
  assert_json_field "${plan}" ".needs_human_escalation" "false" "全部已裁决不应需要人工"
}

###############################################################################
# 8. 裁决结果枚举完整性
###############################################################################
test_verdict_enums_defined() {
  assert_eq "CONFIRMED" "${VERDICT_CONFIRMED}" "VERDICT_CONFIRMED应定义"
  assert_eq "REFUTED" "${VERDICT_REFUTED}" "VERDICT_REFUTED应定义"
  assert_eq "UNVERIFIABLE" "${VERDICT_UNVERIFIABLE}" "VERDICT_UNVERIFIABLE应定义"
  assert_eq "REQUIREMENT_CONFLICT" "${VERDICT_REQUIREMENT_CONFLICT}" "VERDICT_REQUIREMENT_CONFLICT应定义"
}

test_evidence_method_enums_defined() {
  assert_eq "targeted_test" "${EVIDENCE_TARGETED_TEST}" "应定义targeted_test"
  assert_eq "static_rule" "${EVIDENCE_STATIC_RULE}" "应定义static_rule"
  assert_eq "repro_step" "${EVIDENCE_REPRO_STEP}" "应定义repro_step"
  assert_eq "historical_decision_match" "${EVIDENCE_HISTORICAL_MATCH}" "应定义historical_decision_match"
  assert_eq "risk_policy_match" "${EVIDENCE_RISK_POLICY}" "应定义risk_policy_match"
}

###############################################################################
# 9. risk_policy 匹配
###############################################################################
test_risk_policy_security_in_auth() {
  local issue
  issue=$(_make_issue "security_risk" "major" "auth/session.py:10")
  local result
  result=$(attempt_risk_policy "${issue}" "")
  assert_contains "${result}" "MATCHED" "auth路径的security_risk应匹配策略"
  assert_contains "${result}" "SECURITY_IN_AUTH_PATH" "应匹配SECURITY_IN_AUTH_PATH策略"
}

test_risk_policy_requirement_conflict_always_escalates() {
  local issue
  issue=$(_make_issue "requirement_conflict" "major" "src/api.py:10")
  local result
  result=$(attempt_risk_policy "${issue}" "")
  assert_contains "${result}" "MATCHED" "requirement_conflict应匹配策略"
  assert_contains "${result}" "escalate_human" "应包含escalate_human动作"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_evidence_resolution.sh =="

run_test test_verdict_confirmed_on_targeted_test_failure
run_test test_verdict_confirmed_on_static_finding
run_test test_verdict_confirmed_on_repro
run_test test_verdict_refuted_on_targeted_test_pass
run_test test_refuted_downgraded_with_historical_conflict
run_test test_refuted_downgraded_with_policy_conflict
run_test test_verdict_unverifiable_all_inconclusive
run_test test_verdict_unverifiable_no_evidence
run_test test_verdict_requirement_conflict
run_test test_requirement_conflict_ignores_evidence
run_test test_existing_tests_pass_not_refuted
run_test test_phase1_extracts_issues
run_test test_phase1_no_issues_returns_error
run_test test_phase4_action_plan_structure
run_test test_phase4_no_escalation_when_all_resolved
run_test test_verdict_enums_defined
run_test test_evidence_method_enums_defined
run_test test_risk_policy_security_in_auth
run_test test_risk_policy_requirement_conflict_always_escalates

print_report "test_evidence_resolution.sh"
