#!/usr/bin/env bash
###############################################################################
# test_human_escalation.sh — Human Escalation 模块测试
#
# 测试清单（对照统一实施文档第12节）：
#   - 6种触发条件
#   - 结构化上下文完整性
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_escalation() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export ESCALATION_DIR="${TEST_TMP}/.bashclaw/escalations"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  mkdir -p "${ESCALATION_DIR}"
  source "${LIB_DIR}/human_escalation.sh"
}

# 创建标准 issues JSON 文件
_make_issues_file() {
  local filepath="$1"
  shift
  echo "$@" > "${filepath}"
}

###############################################################################
# 1. 触发条件 — UNVERIFIABLE
###############################################################################
test_trigger_unverifiable() {
  _load_escalation
  local f="${TEST_TMP}/issues.json"
  _make_issues_file "${f}" '[{"verdict":"UNVERIFIABLE","severity":"major","risk_tags":"logic"}]'
  local reasons
  reasons=$(escalation_should_trigger "${f}" 2>/dev/null)
  local result=$?
  assert_eq "0" "${result}" "存在UNVERIFIABLE应触发升级"
  assert_contains "${reasons}" "UNVERIFIABLE" "原因应包含UNVERIFIABLE"
}

###############################################################################
# 2. 触发条件 — REQUIREMENT_CONFLICT
###############################################################################
test_trigger_requirement_conflict() {
  _load_escalation
  local f="${TEST_TMP}/issues.json"
  _make_issues_file "${f}" '[{"verdict":"REQUIREMENT_CONFLICT","severity":"major","risk_tags":"api"}]'
  local reasons
  reasons=$(escalation_should_trigger "${f}" 2>/dev/null)
  local result=$?
  assert_eq "0" "${result}" "存在REQUIREMENT_CONFLICT应触发升级"
  assert_contains "${reasons}" "REQUIREMENT_CONFLICT" "原因应包含REQUIREMENT_CONFLICT"
}

###############################################################################
# 3. 触发条件 — 高风险域未裁决
###############################################################################
test_trigger_high_risk_unresolved() {
  _load_escalation
  local f="${TEST_TMP}/issues.json"
  _make_issues_file "${f}" '[{"verdict":"UNVERIFIABLE","severity":"critical","risk_tags":"auth,token"}]'
  local reasons
  reasons=$(escalation_should_trigger "${f}" 2>/dev/null)
  local result=$?
  assert_eq "0" "${result}" "高风险域未裁决应触发"
  assert_contains "${reasons}" "HIGH_RISK_UNRESOLVED" "应包含HIGH_RISK_UNRESOLVED"
}

###############################################################################
# 4. 触发条件 — 证据冲突
###############################################################################
test_trigger_evidence_conflict() {
  _load_escalation
  local f="${TEST_TMP}/issues.json"
  _make_issues_file "${f}" '[{"verdict":"CONFIRMED","evidence_conflict":true,"severity":"major","risk_tags":"api"}]'
  local reasons
  reasons=$(escalation_should_trigger "${f}" 2>/dev/null)
  local result=$?
  assert_eq "0" "${result}" "证据冲突应触发升级"
  assert_contains "${reasons}" "EVIDENCE_CONFLICT" "应包含EVIDENCE_CONFLICT"
}

###############################################################################
# 5. 触发条件 — validation 不可靠
###############################################################################
test_trigger_validation_unreliable() {
  _load_escalation
  local f="${TEST_TMP}/issues.json"
  _make_issues_file "${f}" '[{"verdict":"CONFIRMED","validation_unreliable":true,"severity":"major","risk_tags":"api"}]'
  local reasons
  reasons=$(escalation_should_trigger "${f}" 2>/dev/null)
  local result=$?
  assert_eq "0" "${result}" "validation不可靠应触发升级"
  assert_contains "${reasons}" "VALIDATION_UNRELIABLE" "应包含VALIDATION_UNRELIABLE"
}

###############################################################################
# 6. 触发条件 — 累积风险过高
###############################################################################
test_trigger_accumulated_risk() {
  _load_escalation
  local f="${TEST_TMP}/issues.json"
  _make_issues_file "${f}" '[{"verdict":"UNVERIFIABLE","risk_tags":"api"},{"verdict":"UNVERIFIABLE","risk_tags":"db"},{"verdict":"REQUIREMENT_CONFLICT","risk_tags":"ui"}]'
  local reasons
  reasons=$(escalation_should_trigger "${f}" 2>/dev/null)
  local result=$?
  assert_eq "0" "${result}" "3个以上未裁决应触发累积风险"
  assert_contains "${reasons}" "ACCUMULATED_RISK" "应包含ACCUMULATED_RISK"
}

###############################################################################
# 7. 不触发 — 全部已裁决
###############################################################################
test_no_trigger_all_resolved() {
  _load_escalation
  local f="${TEST_TMP}/issues.json"
  _make_issues_file "${f}" '[{"verdict":"CONFIRMED","severity":"major","risk_tags":"api"},{"verdict":"REFUTED","severity":"minor","risk_tags":"ui"}]'
  local result=0
  escalation_should_trigger "${f}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "全部已裁决不应触发升级"
}

###############################################################################
# 8. 结构化上下文完整性
###############################################################################
test_escalation_context_has_all_sections() {
  _load_escalation

  # 准备 reviewer issues 文件
  local issues_file="${TEST_TMP}/reviewer_issues.json"
  echo '[{"issue_type":"security_risk","location":"auth.py:10","risk_statement":"Missing validation","severity":"critical"}]' > "${issues_file}"

  # 准备 resolution results 文件
  local resolution_file="${TEST_TMP}/resolution.json"
  echo '[{"verdict":"UNVERIFIABLE","id":"I-1","risk_statement":"Cannot verify"}]' > "${resolution_file}"

  local context
  context=$(escalation_build_context \
    "task-001" \
    "Fix authentication bug" \
    "KB-101 hit: similar auth issue" \
    "Modified auth/session.py (+20/-5)" \
    "pytest: PASS, ruff: PASS" \
    "${issues_file}" \
    "${resolution_file}" \
    "[UNVERIFIABLE] 1 issue cannot be verified")

  assert_contains "${context}" "原始需求" "应包含原始需求区域"
  assert_contains "${context}" "Knowledge 预检" "应包含知识预检区域"
  assert_contains "${context}" "Patch 摘要" "应包含Patch摘要区域"
  assert_contains "${context}" "Base Validation" "应包含Base Validation区域"
  assert_contains "${context}" "Reviewer Issues" "应包含Reviewer Issues区域"
  assert_contains "${context}" "裁决状态" "应包含裁决状态区域"
  assert_contains "${context}" "推荐动作" "应包含推荐动作区域"
  assert_contains "${context}" "升级原因" "应包含升级原因区域"
  assert_contains "${context}" "Fix authentication bug" "应包含原始需求内容"
  assert_contains "${context}" "task-001" "应包含task_id"
}

###############################################################################
# 9. escalation_execute 流程
###############################################################################
test_escalation_execute_creates_report() {
  _load_escalation
  local issues_file="${TEST_TMP}/issues.json"
  echo '[]' > "${issues_file}"
  local resolution_file="${TEST_TMP}/resolution.json"
  echo '[]' > "${resolution_file}"

  local report
  report=$(escalation_execute \
    "task-002" \
    "Test requirement" \
    "No knowledge hits" \
    "Small patch" \
    "All pass" \
    "${issues_file}" \
    "${resolution_file}" 2>/dev/null)

  assert_contains "${report}" "Human Escalation Report" "应生成报告"
  assert_contains "${report}" "task-002" "报告应包含task_id"
}

###############################################################################
# 10. escalation_record_decision
###############################################################################
test_record_decision() {
  _load_escalation
  local decision_file
  decision_file=$(escalation_record_decision "task-003" "ACCEPT" "Approved with minor fix" 2>/dev/null)
  [[ -f "${decision_file}" ]] || { echo "决策文件未创建" >&2; return 1; }
  local content
  content=$(cat "${decision_file}")
  assert_contains "${content}" "ACCEPT" "应包含决策"
  assert_contains "${content}" "task-003" "应包含task_id"
}

###############################################################################
# 11. 推荐动作
###############################################################################
test_recommend_actions_for_unverifiable() {
  _load_escalation
  local actions
  actions=$(escalation_recommend_actions "" "[UNVERIFIABLE] 2 issues")
  assert_contains "${actions}" "UNVERIFIABLE" "应包含针对UNVERIFIABLE的建议"
}

test_recommend_actions_for_requirement_conflict() {
  _load_escalation
  local actions
  actions=$(escalation_recommend_actions "" "[REQUIREMENT_CONFLICT] 1 issue")
  assert_contains "${actions}" "需求" "应包含针对需求冲突的建议"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_human_escalation.sh =="

run_test test_trigger_unverifiable
run_test test_trigger_requirement_conflict
run_test test_trigger_high_risk_unresolved
run_test test_trigger_evidence_conflict
run_test test_trigger_validation_unreliable
run_test test_trigger_accumulated_risk
run_test test_no_trigger_all_resolved
run_test test_escalation_context_has_all_sections
run_test test_escalation_execute_creates_report
run_test test_record_decision
run_test test_recommend_actions_for_unverifiable
run_test test_recommend_actions_for_requirement_conflict

print_report "test_human_escalation.sh"
