#!/usr/bin/env bash
###############################################################################
# test_reviewer.sh — Reviewer 模块测试
#
# 测试清单（对照统一实施文档第10节）：
#   - 6个必须输出字段
#   - issue_type 7种枚举
#   - 匿名化（grep不到模型名称）
#   - severity分级
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/reviewer.sh"

###############################################################################
# 1. 6个必须输出字段
###############################################################################
test_validate_issue_all_fields_present() {
  local issue='{"location":"auth/session.py:84","issue_type":"security_risk","severity":"major","risk_statement":"Token refresh does not check tenant boundary","why_it_matters":"Cross-tenant session pollution possible","verification_plan":"Generate cross-tenant access test case, expect 403"}'
  validate_issue "${issue}"
  assert_eq "0" "$?" "包含所有必须字段的issue应验证通过"
}

test_validate_issue_missing_location() {
  local issue='{"issue_type":"security_risk","severity":"major","risk_statement":"problem","why_it_matters":"impact","verification_plan":"test plan here with steps"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "缺少location应验证失败"
}

test_validate_issue_missing_issue_type() {
  local issue='{"location":"file.py:10","severity":"major","risk_statement":"problem","why_it_matters":"impact","verification_plan":"test plan here with steps"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "缺少issue_type应验证失败"
}

test_validate_issue_missing_risk_statement() {
  local issue='{"location":"file.py:10","issue_type":"logic_bug","severity":"major","why_it_matters":"impact","verification_plan":"test plan here with steps"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "缺少risk_statement应验证失败"
}

test_validate_issue_missing_why_it_matters() {
  local issue='{"location":"file.py:10","issue_type":"logic_bug","severity":"major","risk_statement":"problem","verification_plan":"test plan here with steps"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "缺少why_it_matters应验证失败"
}

test_validate_issue_missing_verification_plan() {
  local issue='{"location":"file.py:10","issue_type":"logic_bug","severity":"major","risk_statement":"problem","why_it_matters":"impact"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "缺少verification_plan应验证失败"
}

test_validate_issue_missing_severity() {
  local issue='{"location":"file.py:10","issue_type":"logic_bug","risk_statement":"problem","why_it_matters":"impact","verification_plan":"test plan here with steps"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "缺少severity应验证失败"
}

###############################################################################
# 2. issue_type 7种枚举
###############################################################################
test_validate_issue_type_runtime_bug() {
  assert_true "runtime_bug应是有效枚举" validate_issue_type "runtime_bug"
}

test_validate_issue_type_logic_bug() {
  assert_true "logic_bug应是有效枚举" validate_issue_type "logic_bug"
}

test_validate_issue_type_missing_test() {
  assert_true "missing_test应是有效枚举" validate_issue_type "missing_test"
}

test_validate_issue_type_security_risk() {
  assert_true "security_risk应是有效枚举" validate_issue_type "security_risk"
}

test_validate_issue_type_regression_risk() {
  assert_true "regression_risk应是有效枚举" validate_issue_type "regression_risk"
}

test_validate_issue_type_requirement_conflict() {
  assert_true "requirement_conflict应是有效枚举" validate_issue_type "requirement_conflict"
}

test_validate_issue_type_design_concern() {
  assert_true "design_concern应是有效枚举" validate_issue_type "design_concern"
}

test_validate_issue_type_invalid() {
  assert_false "unknown_type不应是有效枚举" validate_issue_type "unknown_type"
  assert_false "空字符串不应是有效枚举" validate_issue_type ""
  assert_false "任意字符串不应是有效枚举" validate_issue_type "not_a_real_type"
}

###############################################################################
# 3. 匿名化（grep不到模型名称）
###############################################################################
test_anonymize_removes_opus() {
  local result
  result=$(anonymize_content "This is Opus output")
  assert_not_contains "${result}" "Opus" "不应包含Opus"
  assert_contains "${result}" "[Model]" "应替换为[Model]"
}

test_anonymize_removes_codex() {
  local result
  result=$(anonymize_content "Codex generated this code")
  assert_not_contains "${result}" "Codex" "不应包含Codex"
}

test_anonymize_removes_claude() {
  local result
  result=$(anonymize_content "Claude suggested this fix")
  assert_not_contains "${result}" "Claude" "不应包含Claude"
}

test_anonymize_removes_gpt() {
  local result
  result=$(anonymize_content "GPT wrote this function")
  assert_not_contains "${result}" "GPT" "不应包含GPT"
}

test_anonymize_removes_gemini() {
  local result
  result=$(anonymize_content "Gemini reviewed the code")
  assert_not_contains "${result}" "Gemini" "不应包含Gemini"
}

test_anonymize_removes_openai() {
  local result
  result=$(anonymize_content "OpenAI model output")
  assert_not_contains "${result}" "OpenAI" "不应包含OpenAI"
}

test_anonymize_removes_anthropic() {
  local result
  result=$(anonymize_content "Anthropic model result")
  assert_not_contains "${result}" "Anthropic" "不应包含Anthropic"
}

test_anonymize_case_sensitive_variants() {
  local result
  result=$(anonymize_content "opus and codex and claude and gpt and gemini and openai and anthropic")
  assert_not_contains "${result}" "opus" "不应包含opus(小写)"
  assert_not_contains "${result}" "codex" "不应包含codex(小写)"
  assert_not_contains "${result}" "claude" "不应包含claude(小写)"
  assert_not_contains "${result}" "gpt" "不应包含gpt(小写)"
}

test_anonymize_replaces_model_output() {
  local result
  result=$(anonymize_content "Model A output shows bugs")
  assert_contains "${result}" "Patch A" "应将'Model A output'替换为'Patch A'"
}

test_anonymize_replaces_validation_result() {
  local result
  result=$(anonymize_content "The validation result is PASS")
  assert_contains "${result}" "Validation Output" "应将'validation result'替换为'Validation Output'"
}

test_anonymize_no_model_names_in_review_context() {
  local result
  result=$(build_review_context \
    "Fix the Opus-generated authentication bug" \
    "diff with Codex changes" \
    '{"status":"PASS"}' \
    "Claude knowledge note" \
    "auth" \
    "logic_change")
  assert_not_contains "${result}" "Opus" "review上下文不应包含Opus"
  assert_not_contains "${result}" "Codex" "review上下文不应包含Codex"
  assert_not_contains "${result}" "Claude" "review上下文不应包含Claude"
}

###############################################################################
# 4. severity 分级
###############################################################################
test_validate_severity_minor() {
  assert_true "minor应是有效severity" validate_severity "minor"
}

test_validate_severity_major() {
  assert_true "major应是有效severity" validate_severity "major"
}

test_validate_severity_critical() {
  assert_true "critical应是有效severity" validate_severity "critical"
}

test_validate_severity_invalid() {
  assert_false "unknown不应是有效severity" validate_severity "unknown"
  assert_false "high不应是有效severity" validate_severity "high"
  assert_false "空字符串不应是有效severity" validate_severity ""
}

###############################################################################
# 5. 拒绝空洞意见
###############################################################################
test_reject_vague_risk_statement_cn() {
  local issue='{"location":"file.py:10","issue_type":"logic_bug","severity":"major","risk_statement":"感觉有问题","why_it_matters":"impact","verification_plan":"test plan here with steps"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "空洞中文意见应被拒绝"
}

test_reject_vague_risk_statement_en() {
  local issue='{"location":"file.py:10","issue_type":"logic_bug","severity":"major","risk_statement":"seems off to me","why_it_matters":"impact","verification_plan":"test plan here with steps"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "空洞英文意见应被拒绝"
}

test_reject_short_verification_plan() {
  local issue='{"location":"file.py:10","issue_type":"logic_bug","severity":"major","risk_statement":"Null pointer when input is empty array","why_it_matters":"Crash in production","verification_plan":"run test"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "过短的verification_plan应被拒绝"
}

###############################################################################
# 6. location 格式验证
###############################################################################
test_validate_location_with_line() {
  local issue='{"location":"auth/session.py:84","issue_type":"logic_bug","severity":"minor","risk_statement":"Missing null check for session data","why_it_matters":"Potential crash","verification_plan":"Run unit test with null session input"}'
  validate_issue "${issue}" 2>/dev/null
  assert_eq "0" "$?" "file:line 格式应通过验证"
}

test_validate_location_without_line() {
  local issue='{"location":"auth/session.py","issue_type":"logic_bug","severity":"minor","risk_statement":"Missing null check for session data","why_it_matters":"Potential crash","verification_plan":"Run unit test with null session input"}'
  local result=0
  validate_issue "${issue}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "缺少行号的location应验证失败"
}

###############################################################################
# 7. parse_review_output 解析
###############################################################################
test_parse_valid_review_output() {
  local raw_output='{"issues":[{"location":"file.py:10","issue_type":"logic_bug","severity":"major","risk_statement":"Missing boundary check","why_it_matters":"Could crash","verification_plan":"Run test with edge case inputs and verify no crash"}]}'
  local result
  result=$(parse_review_output "${raw_output}" 2>/dev/null)
  assert_json_field "${result}" ".valid_count" "1" "应有1个有效issue"
}

test_parse_empty_issues() {
  local raw_output='{"issues":[]}'
  local result
  result=$(parse_review_output "${raw_output}" 2>/dev/null)
  assert_json_field "${result}" ".valid_count" "0" "空issues应有0个有效issue"
}

test_parse_invalid_json() {
  local raw_output='not json at all'
  local result=0
  parse_review_output "${raw_output}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "无效JSON应返回错误"
}

test_parse_filters_invalid_issues() {
  # One valid, one missing location
  local raw_output='{"issues":[{"location":"file.py:10","issue_type":"logic_bug","severity":"major","risk_statement":"Valid issue with details","why_it_matters":"Impact described","verification_plan":"Run targeted test with specific inputs"},{"issue_type":"logic_bug","severity":"major","risk_statement":"No location","why_it_matters":"impact","verification_plan":"test plan detail here"}]}'
  local result
  result=$(parse_review_output "${raw_output}" 2>/dev/null)
  local valid_count
  valid_count=$(echo "${result}" | jq -r '.valid_count')
  assert_eq "1" "${valid_count}" "应只有1个有效issue（另一个缺location）"
  local rejected_count
  rejected_count=$(echo "${result}" | jq -r '.rejected_count')
  assert_eq "1" "${rejected_count}" "应有1个被拒绝的issue"
}

###############################################################################
# 8. run_review 集成 (mock 模式)
###############################################################################
test_run_review_mock_mode() {
  export BASHCLAW_REVIEW_MOCK_OUTPUT='{"issues":[{"location":"app.py:42","issue_type":"runtime_bug","severity":"critical","risk_statement":"Unhandled exception when database connection fails","why_it_matters":"Application crashes in production","verification_plan":"Simulate database connection failure and verify graceful handling"}]}'
  local result
  result=$(run_review "fix db bug" "diff content" '{"status":"PASS"}' "knowledge" "auth" "logic_change" 2>/dev/null)
  assert_json_has_field "${result}" ".issues" "应包含issues字段"
  assert_json_field "${result}" ".status" "COMPLETED" "状态应为COMPLETED"
  unset BASHCLAW_REVIEW_MOCK_OUTPUT
}

test_run_review_no_model_configured() {
  unset BASHCLAW_REVIEWER_CMD 2>/dev/null || true
  unset BASHCLAW_REVIEW_MOCK_OUTPUT 2>/dev/null || true
  # 临时屏蔽 CLI 和 API key，模拟无任何模型可用
  local old_path="${PATH}"
  PATH="/usr/bin:/bin"
  unset ANTHROPIC_API_KEY 2>/dev/null || true
  unset OPENAI_API_KEY 2>/dev/null || true
  local result=0
  run_review "test" "diff" '{"status":"PASS"}' "" "" "logic_change" 2>/dev/null || result=$?
  PATH="${old_path}"
  assert_eq "1" "${result}" "无模型配置时应返回错误"
}

###############################################################################
# 9. has_critical_issues / has_requirement_conflicts
###############################################################################
test_has_critical_issues_true() {
  local result='{"issues":[{"severity":"critical","issue_type":"security_risk"}]}'
  assert_true "应检测到critical issues" has_critical_issues "${result}"
}

test_has_critical_issues_false() {
  local result='{"issues":[{"severity":"minor","issue_type":"logic_bug"}]}'
  assert_false "无critical issues" has_critical_issues "${result}"
}

test_has_requirement_conflicts_true() {
  local result='{"issues":[{"severity":"major","issue_type":"requirement_conflict"}]}'
  assert_true "应检测到requirement_conflict" has_requirement_conflicts "${result}"
}

test_has_requirement_conflicts_false() {
  local result='{"issues":[{"severity":"major","issue_type":"logic_bug"}]}'
  assert_false "无requirement_conflict" has_requirement_conflicts "${result}"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_reviewer.sh =="

run_test test_validate_issue_all_fields_present
run_test test_validate_issue_missing_location
run_test test_validate_issue_missing_issue_type
run_test test_validate_issue_missing_risk_statement
run_test test_validate_issue_missing_why_it_matters
run_test test_validate_issue_missing_verification_plan
run_test test_validate_issue_missing_severity
run_test test_validate_issue_type_runtime_bug
run_test test_validate_issue_type_logic_bug
run_test test_validate_issue_type_missing_test
run_test test_validate_issue_type_security_risk
run_test test_validate_issue_type_regression_risk
run_test test_validate_issue_type_requirement_conflict
run_test test_validate_issue_type_design_concern
run_test test_validate_issue_type_invalid
run_test test_anonymize_removes_opus
run_test test_anonymize_removes_codex
run_test test_anonymize_removes_claude
run_test test_anonymize_removes_gpt
run_test test_anonymize_removes_gemini
run_test test_anonymize_removes_openai
run_test test_anonymize_removes_anthropic
run_test test_anonymize_case_sensitive_variants
run_test test_anonymize_replaces_model_output
run_test test_anonymize_replaces_validation_result
run_test test_anonymize_no_model_names_in_review_context
run_test test_validate_severity_minor
run_test test_validate_severity_major
run_test test_validate_severity_critical
run_test test_validate_severity_invalid
run_test test_reject_vague_risk_statement_cn
run_test test_reject_vague_risk_statement_en
run_test test_reject_short_verification_plan
run_test test_validate_location_with_line
run_test test_validate_location_without_line
run_test test_parse_valid_review_output
run_test test_parse_empty_issues
run_test test_parse_invalid_json
run_test test_parse_filters_invalid_issues
run_test test_run_review_mock_mode
run_test test_run_review_no_model_configured
run_test test_has_critical_issues_true
run_test test_has_critical_issues_false
run_test test_has_requirement_conflicts_true
run_test test_has_requirement_conflicts_false

print_report "test_reviewer.sh"
