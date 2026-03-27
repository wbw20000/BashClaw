#!/usr/bin/env bash
###############################################################################
# test_skip_review.sh — Skip Review 判定测试
#
# 测试清单（对照统一实施文档第17节）：
#   - 9条件全满足 → skip
#   - 任一不满足 → 不skip
#   - logic_change即使改动小也不skip
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/skip_review.sh"

###############################################################################
# 辅助
###############################################################################
# 修复 Critical #2: 测试数据与 validator_run 实际输出结构对齐
_pass_validation='{"validation":{"status":"PASS","stacks_detected":[],"results":[]}}'
_fail_validation='{"validation":{"status":"FAIL_TEST","stacks_detected":[],"results":[{"status":"FAIL_TEST"}]}}'
_small_diff="fix a typo in comment"
_large_diff=$(printf '%.0sline\n' {1..100})

###############################################################################
# 1. 9条件全满足 → skip (docs_only 场景)
###############################################################################
test_all_conditions_met_skip() {
  local kg_output='{"confidence":"high","action_hint":"proceed"}'
  local result
  result=$(evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "README.md" \
    "${_small_diff}" \
    "${kg_output}" \
    "" \
    "" 2>/dev/null) || true
  local decision
  decision=$(echo "${result}" | jq -r '.decision')
  assert_eq "SKIP_REVIEW" "${decision}" "9条件全满足应跳过review"
}

###############################################################################
# 2. 条件(a): Base Validation 失败 → 不skip
###############################################################################
test_base_validation_fail_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_fail_validation}" \
    "docs_only" \
    "README.md" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "Base Validation失败不应skip"
}

###############################################################################
# 3. 条件(b): 非低风险changeType → 不skip
###############################################################################
test_logic_change_no_skip_without_signal() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "logic_change" \
    "src/main.py" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "logic_change不应轻易skip"
}

test_config_change_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "config_change" \
    "config.json" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "config_change不应轻易skip"
}

test_schema_change_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "schema_change" \
    "db/schema.sql" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "schema_change不应skip"
}

test_infra_change_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "infra_change" \
    "Dockerfile" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "infra_change不应skip"
}

test_mixed_change_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "mixed_change" \
    "src/main.py" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "mixed_change不应skip"
}

###############################################################################
# 4. 条件(c): 高风险路径/diff → 不skip
###############################################################################
test_high_risk_path_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "auth/config.md" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "auth路径不应skip"
}

test_high_risk_diff_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "README.md" \
    "updated jwt token handling" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "diff含jwt不应skip"
}

###############################################################################
# 5. 条件(d): 大规模变更 → 不skip
###############################################################################
test_large_change_no_skip() {
  local many_files="file1.md
file2.md
file3.md"
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "${many_files}" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "超过2个文件不应skip"
}

test_large_diff_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "README.md" \
    "${_large_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "超过80行diff不应skip"
}

###############################################################################
# 6. 条件(e): 新增依赖 → 不skip
###############################################################################
test_new_dependency_no_skip() {
  local dep_diff='+  "dependencies": { "lodash": "^4.0" }'
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "package.json" \
    "${dep_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "新增依赖不应skip"
}

###############################################################################
# 7. 条件(f): 敏感域 → 不skip
###############################################################################
test_sensitive_domain_deploy_no_skip() {
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "deploy/config.md" \
    "${_small_diff}" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "deploy域不应skip"
}

###############################################################################
# 8. 条件(i): 需求冲突 → 不skip
###############################################################################
test_requirement_conflicts_no_skip() {
  local task_ctx='{"requirement_conflicts":true}'
  local kg_output='{"confidence":"high","action_hint":"proceed"}'
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "README.md" \
    "${_small_diff}" \
    "${kg_output}" \
    "" \
    "${task_ctx}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "有需求冲突不应skip"
}

###############################################################################
# 9. logic_change 即使改动小也不skip
###############################################################################
test_logic_change_small_still_no_skip() {
  # logic_change + 小改动 + 全通过，但没有正向信号
  local result=0
  evaluate_skip_review \
    "${_pass_validation}" \
    "logic_change" \
    "src/util.py" \
    "fix typo" \
    "" "" "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "logic_change即使改动小也不应仅凭此skip"
}

###############################################################################
# 10. 子条件检查函数
###############################################################################
test_check_low_risk_change_types() {
  assert_true "docs_only是低风险" check_low_risk_change_type "docs_only"
  assert_true "comment_only是低风险" check_low_risk_change_type "comment_only"
  assert_true "test_only是低风险" check_low_risk_change_type "test_only"
  assert_false "logic_change非低风险" check_low_risk_change_type "logic_change"
}

test_check_no_high_risk_paths_clean() {
  assert_true "普通路径无风险" check_no_high_risk_paths "src/utils.py" "simple change"
}

test_check_no_high_risk_paths_auth() {
  assert_false "auth路径有风险" check_no_high_risk_paths "src/auth/login.py" ""
}

test_check_small_change_small() {
  assert_true "小改动" check_small_change "file.py" "one line"
}

test_check_no_new_deps_clean() {
  assert_true "无新依赖" check_no_new_dependencies "simple fix"
}

test_check_no_new_deps_with_import() {
  assert_false "有新import" check_no_new_dependencies "+import requests"
}

test_check_no_sensitive_domains_clean() {
  assert_true "无敏感域" check_no_sensitive_domains "src/utils.py" "simple fix"
}

test_check_no_sensitive_domains_auth() {
  assert_false "auth是敏感域" check_no_sensitive_domains "auth/login.py" ""
}

###############################################################################
# 11. 输出结构
###############################################################################
test_skip_review_output_structure() {
  local result
  result=$(evaluate_skip_review \
    "${_pass_validation}" \
    "docs_only" \
    "README.md" \
    "${_small_diff}" \
    '{"confidence":"high","action_hint":"proceed"}' \
    "" "" 2>/dev/null) || true
  assert_json_has_field "${result}" ".decision" "应包含decision"
  assert_json_has_field "${result}" ".conditions" "应包含conditions"
  assert_json_has_field "${result}" ".change_type" "应包含change_type"
  assert_json_has_field "${result}" ".timestamp" "应包含timestamp"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_skip_review.sh =="

run_test test_all_conditions_met_skip
run_test test_base_validation_fail_no_skip
run_test test_logic_change_no_skip_without_signal
run_test test_config_change_no_skip
run_test test_schema_change_no_skip
run_test test_infra_change_no_skip
run_test test_mixed_change_no_skip
run_test test_high_risk_path_no_skip
run_test test_high_risk_diff_no_skip
run_test test_large_change_no_skip
run_test test_large_diff_no_skip
run_test test_new_dependency_no_skip
run_test test_sensitive_domain_deploy_no_skip
run_test test_requirement_conflicts_no_skip
run_test test_logic_change_small_still_no_skip
run_test test_check_low_risk_change_types
run_test test_check_no_high_risk_paths_clean
run_test test_check_no_high_risk_paths_auth
run_test test_check_small_change_small
run_test test_check_no_new_deps_clean
run_test test_check_no_new_deps_with_import
run_test test_check_no_sensitive_domains_clean
run_test test_check_no_sensitive_domains_auth
run_test test_skip_review_output_structure

print_report "test_skip_review.sh"
