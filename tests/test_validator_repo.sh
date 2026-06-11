#!/usr/bin/env bash
###############################################################################
# test_validator_repo.sh — Base Validation 模块测试
#
# 测试清单（对照统一实施文档第9节）：
#   - Python验证优先级
#   - JS/TS验证优先级
#   - Shell验证
#   - 结果枚举7种
#   - NO_VALIDATOR_FOUND ≠ PASS
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/validator_repo.sh"

###############################################################################
# 1. 结果枚举7种 — validator_aggregate_status
###############################################################################
test_aggregate_pass() {
  local result
  result=$(validator_aggregate_status '{"status":"PASS"}' '{"status":"PASS"}')
  assert_eq "PASS" "${result}" "全PASS应聚合为PASS"
}

test_aggregate_fail_test() {
  local result
  result=$(validator_aggregate_status '{"status":"PASS"}' '{"status":"FAIL_TEST"}')
  assert_eq "FAIL_TEST" "${result}" "存在FAIL_TEST应返回FAIL_TEST"
}

test_aggregate_fail_lint() {
  local result
  result=$(validator_aggregate_status '{"status":"PASS"}' '{"status":"FAIL_LINT"}')
  assert_eq "FAIL_LINT" "${result}" "存在FAIL_LINT应返回FAIL_LINT"
}

test_aggregate_fail_typecheck() {
  local result
  result=$(validator_aggregate_status '{"status":"PASS"}' '{"status":"FAIL_TYPECHECK"}')
  assert_eq "FAIL_TYPECHECK" "${result}" "存在FAIL_TYPECHECK应返回FAIL_TYPECHECK"
}

test_aggregate_fail_repro() {
  local result
  result=$(validator_aggregate_status '{"status":"FAIL_REPRO"}' '{"status":"PASS"}')
  assert_eq "FAIL_REPRO" "${result}" "FAIL_REPRO应是终止性的"
}

test_aggregate_fail_validate() {
  local result
  result=$(validator_aggregate_status '{"status":"PASS"}' '{"status":"FAIL_VALIDATE"}')
  assert_eq "FAIL_VALIDATE" "${result}" "存在FAIL_VALIDATE应返回FAIL_VALIDATE"
}

test_aggregate_no_validator_found() {
  local result
  result=$(validator_aggregate_status '{"status":"NO_VALIDATOR_FOUND"}')
  assert_eq "NO_VALIDATOR_FOUND" "${result}" "无验证器应返回NO_VALIDATOR_FOUND"
}

###############################################################################
# 2. NO_VALIDATOR_FOUND ≠ PASS
###############################################################################
test_no_validator_is_not_pass() {
  local result
  result=$(validator_aggregate_status '{"status":"NO_VALIDATOR_FOUND"}')
  [[ "${result}" != "PASS" ]] || {
    echo "NO_VALIDATOR_FOUND 不应等于 PASS" >&2
    return 1
  }
}

test_no_validator_worse_than_pass() {
  # NO_VALIDATOR_FOUND 应比 PASS 更差
  local result
  result=$(validator_aggregate_status '{"status":"PASS"}' '{"status":"NO_VALIDATOR_FOUND"}')
  assert_eq "NO_VALIDATOR_FOUND" "${result}" "PASS+NO_VALIDATOR_FOUND应聚合为NO_VALIDATOR_FOUND"
}

###############################################################################
# 3. 聚合优先级
###############################################################################
test_aggregate_test_failure_is_terminal() {
  local result
  result=$(validator_aggregate_status '{"status":"FAIL_LINT"}' '{"status":"FAIL_TEST"}' '{"status":"FAIL_TYPECHECK"}')
  assert_eq "FAIL_TEST" "${result}" "FAIL_TEST应是最高优先级（终止性）"
}

test_aggregate_repro_failure_is_terminal() {
  local result
  result=$(validator_aggregate_status '{"status":"FAIL_LINT"}' '{"status":"FAIL_REPRO"}')
  assert_eq "FAIL_REPRO" "${result}" "FAIL_REPRO应是终止性"
}

test_aggregate_typecheck_over_lint() {
  local result
  result=$(validator_aggregate_status '{"status":"FAIL_LINT"}' '{"status":"FAIL_TYPECHECK"}')
  assert_eq "FAIL_TYPECHECK" "${result}" "FAIL_TYPECHECK优先级高于FAIL_LINT"
}

###############################################################################
# 4. Python 栈检测
###############################################################################
test_detect_python_by_pyproject() {
  mkdir -p "${TEST_TMP}/repo"
  touch "${TEST_TMP}/repo/pyproject.toml"
  local stacks
  stacks=$(validator_detect_stack "${TEST_TMP}/repo")
  assert_contains "${stacks}" "python" "应检测到python栈"
}

test_detect_python_by_requirements() {
  mkdir -p "${TEST_TMP}/repo"
  touch "${TEST_TMP}/repo/requirements.txt"
  local stacks
  stacks=$(validator_detect_stack "${TEST_TMP}/repo")
  assert_contains "${stacks}" "python" "应通过requirements.txt检测python"
}

###############################################################################
# 5. JS/TS 栈检测
###############################################################################
test_detect_js_by_package_json() {
  mkdir -p "${TEST_TMP}/repo"
  echo '{}' > "${TEST_TMP}/repo/package.json"
  local stacks
  stacks=$(validator_detect_stack "${TEST_TMP}/repo")
  assert_contains "${stacks}" "js" "应检测到js栈"
}

test_detect_ts_by_tsconfig() {
  mkdir -p "${TEST_TMP}/repo"
  echo '{}' > "${TEST_TMP}/repo/package.json"
  echo '{}' > "${TEST_TMP}/repo/tsconfig.json"
  local stacks
  stacks=$(validator_detect_stack "${TEST_TMP}/repo")
  assert_contains "${stacks}" "ts" "应检测到ts栈"
}

###############################################################################
# 6. Shell 栈检测
###############################################################################
test_detect_shell_by_sh_files() {
  mkdir -p "${TEST_TMP}/repo"
  echo '#!/bin/bash' > "${TEST_TMP}/repo/test.sh"
  local stacks
  stacks=$(validator_detect_stack "${TEST_TMP}/repo")
  assert_contains "${stacks}" "shell" "应检测到shell栈"
}

###############################################################################
# 7. Docker 栈检测
###############################################################################
test_detect_docker_by_dockerfile() {
  mkdir -p "${TEST_TMP}/repo"
  echo 'FROM alpine' > "${TEST_TMP}/repo/Dockerfile"
  local stacks
  stacks=$(validator_detect_stack "${TEST_TMP}/repo")
  assert_contains "${stacks}" "docker" "应检测到docker栈"
}

###############################################################################
# 8. Unknown 栈
###############################################################################
test_detect_unknown_stack() {
  mkdir -p "${TEST_TMP}/empty_repo"
  local stacks
  stacks=$(validator_detect_stack "${TEST_TMP}/empty_repo")
  assert_eq "unknown" "${stacks}" "空项目应检测为unknown"
}

###############################################################################
# 9. docs_only 快捷路径
###############################################################################
test_validator_run_docs_only() {
  mkdir -p "${TEST_TMP}/repo"
  echo "# README" > "${TEST_TMP}/repo/README.md"
  local result
  result=$(validator_run "${TEST_TMP}/repo" "docs_only")
  assert_contains "${result}" "status" "应返回包含status的结果"
  # docs_only 不应跑重测试
  assert_not_contains "${result}" "FAIL_TEST" "docs_only不应有FAIL_TEST"
}

###############################################################################
# 10. 无验证器返回 NO_VALIDATOR_FOUND
###############################################################################
test_validator_run_no_validators() {
  mkdir -p "${TEST_TMP}/empty_repo"
  local result
  result=$(validator_run "${TEST_TMP}/empty_repo" "logic_change")
  assert_contains "${result}" "NO_VALIDATOR_FOUND" "无验证器应返回NO_VALIDATOR_FOUND"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_validator_repo.sh =="

run_test test_aggregate_pass
run_test test_aggregate_fail_test
run_test test_aggregate_fail_lint
run_test test_aggregate_fail_typecheck
run_test test_aggregate_fail_repro
run_test test_aggregate_fail_validate
run_test test_aggregate_no_validator_found
run_test test_no_validator_is_not_pass
run_test test_no_validator_worse_than_pass
run_test test_aggregate_test_failure_is_terminal
run_test test_aggregate_repro_failure_is_terminal
run_test test_aggregate_typecheck_over_lint
run_test test_detect_python_by_pyproject
run_test test_detect_python_by_requirements
run_test test_detect_js_by_package_json
run_test test_detect_ts_by_tsconfig
run_test test_detect_shell_by_sh_files
run_test test_detect_docker_by_dockerfile
run_test test_detect_unknown_stack
run_test test_validator_run_docs_only
run_test test_validator_run_no_validators

print_report "test_validator_repo.sh"
