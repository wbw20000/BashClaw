#!/usr/bin/env bash
###############################################################################
# test_targeted_validation.sh — Targeted Validation 模块测试
#
# 测试清单（对照统一实施文档第11节 Phase 2）：
#   - 测试框架检测
#   - 测试生成（mock模式）
#   - 测试执行与结果枚举
#   - 完整流程 run_targeted_validation
#   - execute_repro_step
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/targeted_validation.sh"

###############################################################################
# 1. 结果枚举定义
###############################################################################
test_tv_result_enums_defined() {
  assert_eq "PASS" "${TV_PASS}" "TV_PASS应定义"
  assert_eq "FAIL" "${TV_FAIL}" "TV_FAIL应定义"
  assert_eq "ERROR" "${TV_ERROR}" "TV_ERROR应定义"
  assert_eq "NOT_EXECUTABLE" "${TV_NOT_EXECUTABLE}" "TV_NOT_EXECUTABLE应定义"
  assert_eq "TIMEOUT" "${TV_TIMEOUT}" "TV_TIMEOUT应定义"
}

test_default_timeout_defined() {
  assert_eq "60" "${DEFAULT_VALIDATION_TIMEOUT}" "默认超时应为60秒"
}

###############################################################################
# 2. detect_test_framework — 测试框架检测
###############################################################################
test_detect_framework_empty_repo() {
  mkdir -p "${TEST_TMP}/empty_repo"
  local frameworks
  frameworks=$(detect_test_framework "${TEST_TMP}/empty_repo")
  local count
  count=$(echo "${frameworks}" | jq 'length')
  assert_eq "0" "${count}" "空仓库应检测到0个框架"
}

test_detect_framework_python_pyproject() {
  mkdir -p "${TEST_TMP}/py_repo"
  echo "[tool.pytest]" > "${TEST_TMP}/py_repo/pyproject.toml"
  local frameworks
  frameworks=$(detect_test_framework "${TEST_TMP}/py_repo")
  # 如果系统有 pytest，应检测到
  if command -v pytest &>/dev/null; then
    assert_contains "${frameworks}" "pytest" "应检测到pytest框架"
  fi
}

test_detect_framework_js_package_json() {
  mkdir -p "${TEST_TMP}/js_repo"
  echo '{"scripts":{"test":"jest"}}' > "${TEST_TMP}/js_repo/package.json"
  local frameworks
  frameworks=$(detect_test_framework "${TEST_TMP}/js_repo")
  assert_contains "${frameworks}" "npm_test" "应检测到npm_test框架"
}

test_detect_framework_js_pnpm() {
  mkdir -p "${TEST_TMP}/pnpm_repo"
  echo '{"scripts":{"test":"vitest"}}' > "${TEST_TMP}/pnpm_repo/package.json"
  touch "${TEST_TMP}/pnpm_repo/pnpm-lock.yaml"
  local frameworks
  frameworks=$(detect_test_framework "${TEST_TMP}/pnpm_repo")
  assert_contains "${frameworks}" "pnpm" "应使用pnpm作为runner"
}

test_detect_framework_js_yarn() {
  mkdir -p "${TEST_TMP}/yarn_repo"
  echo '{"scripts":{"test":"jest"}}' > "${TEST_TMP}/yarn_repo/package.json"
  touch "${TEST_TMP}/yarn_repo/yarn.lock"
  local frameworks
  frameworks=$(detect_test_framework "${TEST_TMP}/yarn_repo")
  assert_contains "${frameworks}" "yarn" "应使用yarn作为runner"
}

test_detect_framework_go() {
  mkdir -p "${TEST_TMP}/go_repo"
  echo 'module test' > "${TEST_TMP}/go_repo/go.mod"
  local frameworks
  frameworks=$(detect_test_framework "${TEST_TMP}/go_repo")
  if command -v go &>/dev/null; then
    assert_contains "${frameworks}" "go_test" "应检测到go test框架"
  fi
}

test_detect_framework_output_is_json_array() {
  mkdir -p "${TEST_TMP}/any_repo"
  local frameworks
  frameworks=$(detect_test_framework "${TEST_TMP}/any_repo")
  echo "${frameworks}" | jq . > /dev/null 2>&1 || {
    echo "输出应是有效JSON数组" >&2
    return 1
  }
  local type_check
  type_check=$(echo "${frameworks}" | jq 'type')
  assert_eq '"array"' "${type_check}" "输出应是JSON array"
}

###############################################################################
# 3. generate_targeted_test — 测试生成 (mock模式)
###############################################################################
test_generate_with_mock_content() {
  mkdir -p "${TEST_TMP}/gen_repo"
  export BASHCLAW_MOCK_TEST_CONTENT="def test_example(): assert True"
  local issue='{"verification_plan":"test X","location":"file.py:10","issue_type":"logic_bug","risk_statement":"problem"}'
  local framework='{"name":"pytest","command":"pytest","language":"python"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/gen_repo")
  local generated
  generated=$(echo "${test_info}" | jq -r '.generated')
  assert_eq "true" "${generated}" "mock模式应生成测试"
  local source
  source=$(echo "${test_info}" | jq -r '.source')
  assert_eq "mock" "${source}" "source应为mock"
  # 清理
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  rm -f "${test_file}" 2>/dev/null
  unset BASHCLAW_MOCK_TEST_CONTENT
}

test_generate_without_external_falls_back_to_builtin() {
  mkdir -p "${TEST_TMP}/gen_repo2"
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"test X","location":"file.py:10","issue_type":"logic_bug","risk_statement":"problem"}'
  local framework='{"name":"pytest","command":"pytest","language":"python"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/gen_repo2" 2>/dev/null)
  local generated
  generated=$(echo "${test_info}" | jq -r '.generated')
  assert_eq "true" "${generated}" "内置生成器应成功生成测试"
  local source
  source=$(echo "${test_info}" | jq -r '.source')
  assert_eq "builtin_basic" "${source}" "source应为builtin_basic"
  local framework_out
  framework_out=$(echo "${test_info}" | jq -r '.framework')
  assert_eq "bash" "${framework_out}" "framework应为bash"
  # 清理
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  rm -f "${test_file}" 2>/dev/null
}

test_generate_creates_correct_python_path() {
  mkdir -p "${TEST_TMP}/gen_repo3"
  export BASHCLAW_MOCK_TEST_CONTENT="def test(): pass"
  local issue='{"verification_plan":"test","location":"file.py:10","issue_type":"logic_bug","risk_statement":"problem"}'
  local framework='{"name":"pytest","command":"pytest","language":"python"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/gen_repo3")
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  assert_contains "${test_file}" ".py" "Python测试应以.py结尾"
  assert_contains "${test_file}" "test_targeted" "应包含test_targeted前缀"
  rm -f "${test_file}" 2>/dev/null
  unset BASHCLAW_MOCK_TEST_CONTENT
}

test_generate_creates_correct_js_path() {
  mkdir -p "${TEST_TMP}/gen_repo4"
  export BASHCLAW_MOCK_TEST_CONTENT="test('example', () => {})"
  local issue='{"verification_plan":"test","location":"file.js:10","issue_type":"logic_bug","risk_statement":"problem"}'
  local framework='{"name":"npm_test","command":"npm test","language":"javascript"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/gen_repo4")
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  assert_contains "${test_file}" ".test.js" "JS测试应以.test.js结尾"
  rm -f "${test_file}" 2>/dev/null
  unset BASHCLAW_MOCK_TEST_CONTENT
}

###############################################################################
# 4. execute_test — 测试执行
###############################################################################
test_execute_test_missing_file() {
  local test_info='{"test_file":"/nonexistent/file.py","framework":"pytest"}'
  local result
  result=$(execute_test "${test_info}" "${TEST_TMP}" 2>/dev/null)
  assert_json_field "${result}" ".status" "NOT_EXECUTABLE" "缺失文件应返回NOT_EXECUTABLE"
}

test_execute_test_passing_script() {
  mkdir -p "${TEST_TMP}/exec_repo"
  local test_file="${TEST_TMP}/exec_repo/test_pass.sh"
  echo '#!/bin/bash' > "${test_file}"
  echo 'exit 0' >> "${test_file}"
  chmod +x "${test_file}"
  local test_info="{\"test_file\":\"${test_file}\",\"framework\":\"bash\"}"
  local result
  result=$(execute_test "${test_info}" "${TEST_TMP}/exec_repo" 10 2>/dev/null) || true
  assert_json_field "${result}" ".status" "PASS" "exit 0的脚本应返回PASS"
}

test_execute_test_failing_script() {
  mkdir -p "${TEST_TMP}/exec_repo2"
  local test_file="${TEST_TMP}/exec_repo2/test_fail.sh"
  echo '#!/bin/bash' > "${test_file}"
  echo 'exit 1' >> "${test_file}"
  chmod +x "${test_file}"
  local test_info="{\"test_file\":\"${test_file}\",\"framework\":\"bash\"}"
  local result
  result=$(execute_test "${test_info}" "${TEST_TMP}/exec_repo2" 10 2>/dev/null) || true
  assert_json_field "${result}" ".status" "FAIL" "exit 1的脚本应返回FAIL"
}

test_execute_test_output_has_fields() {
  mkdir -p "${TEST_TMP}/exec_repo3"
  local test_file="${TEST_TMP}/exec_repo3/test_fields.sh"
  echo '#!/bin/bash' > "${test_file}"
  echo 'echo "test output"' >> "${test_file}"
  echo 'exit 0' >> "${test_file}"
  chmod +x "${test_file}"
  local test_info="{\"test_file\":\"${test_file}\",\"framework\":\"bash\"}"
  local result
  result=$(execute_test "${test_info}" "${TEST_TMP}/exec_repo3" 10 2>/dev/null) || true
  assert_json_has_field "${result}" ".status" "应包含status"
  assert_json_has_field "${result}" ".exit_code" "应包含exit_code"
  assert_json_has_field "${result}" ".output" "应包含output"
  assert_json_has_field "${result}" ".test_file" "应包含test_file"
}

###############################################################################
# 5. run_targeted_validation — 完整流程
###############################################################################
test_run_targeted_no_framework_uses_builtin() {
  mkdir -p "${TEST_TMP}/no_fw_repo"
  local issue='{"verification_plan":"test X","location":"file.py:10","issue_type":"logic_bug","risk_statement":"problem"}'
  local result
  result=$(run_targeted_validation "${issue}" "${TEST_TMP}/no_fw_repo" 2>/dev/null) || true
  # 没有检测到框架时，应使用内置生成器 + bash 执行
  assert_json_field "${result}" ".method" "targeted_test" "method应为targeted_test"
  assert_json_has_field "${result}" ".status" "应包含status"
  # status 不应再是 NOT_EXECUTABLE，因为内置生成器可以工作
  local status
  status=$(echo "${result}" | jq -r '.status')
  assert_not_contains "${status}" "NOT_EXECUTABLE" "有内置生成器时不应返回NOT_EXECUTABLE"
  # test_info 应标记为 builtin_basic
  local source
  source=$(echo "${result}" | jq -r '.test_info.source // empty')
  assert_eq "builtin_basic" "${source}" "test_info.source应为builtin_basic"
}

test_run_targeted_output_structure() {
  mkdir -p "${TEST_TMP}/tv_repo"
  local issue='{"verification_plan":"test X","location":"file.py:10","issue_type":"logic_bug","risk_statement":"problem"}'
  local result
  result=$(run_targeted_validation "${issue}" "${TEST_TMP}/tv_repo" 2>/dev/null) || true
  assert_json_has_field "${result}" ".method" "应包含method"
  assert_json_has_field "${result}" ".status" "应包含status"
  assert_json_has_field "${result}" ".timestamp" "应包含timestamp"
}

###############################################################################
# 5b. _generate_basic_test — 内置基本测试生成器
###############################################################################
test_builtin_gen_missing_test_type() {
  mkdir -p "${TEST_TMP}/bt_repo"
  echo 'echo hello' > "${TEST_TMP}/bt_repo/target.sh"
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"ensure function foo is tested","location":"target.sh:1","issue_type":"missing_test","risk_statement":"no test coverage"}'
  local framework='{"name":"bash","command":"bash","language":"shell"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/bt_repo" 2>/dev/null)
  local source
  source=$(echo "${test_info}" | jq -r '.source')
  assert_eq "builtin_basic" "${source}" "应使用内置生成器"
  # 生成的测试文件应能通过 bash -n 语法检查
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  bash -n "${test_file}" 2>/dev/null
  assert_eq "0" "$?" "生成的测试应通过bash -n语法检查"
  rm -f "${test_file}" 2>/dev/null
}

test_builtin_gen_security_risk_type() {
  mkdir -p "${TEST_TMP}/bt_repo2"
  echo 'echo safe_code' > "${TEST_TMP}/bt_repo2/app.sh"
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"check for injection","location":"app.sh:1","issue_type":"security_risk","risk_statement":"possible injection"}'
  local framework='{"name":"bash","command":"bash","language":"shell"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/bt_repo2" 2>/dev/null)
  local source
  source=$(echo "${test_info}" | jq -r '.source')
  assert_eq "builtin_basic" "${source}" "应使用内置生成器"
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  bash -n "${test_file}" 2>/dev/null
  assert_eq "0" "$?" "安全测试应通过bash -n语法检查"
  rm -f "${test_file}" 2>/dev/null
}

test_builtin_gen_logic_bug_type() {
  mkdir -p "${TEST_TMP}/bt_repo3"
  echo '#!/bin/bash' > "${TEST_TMP}/bt_repo3/logic.sh"
  echo 'x=$((1+1))' >> "${TEST_TMP}/bt_repo3/logic.sh"
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"check boundary condition","location":"logic.sh:2","issue_type":"logic_bug","risk_statement":"off by one"}'
  local framework='{"name":"bash","command":"bash","language":"shell"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/bt_repo3" 2>/dev/null)
  local source
  source=$(echo "${test_info}" | jq -r '.source')
  assert_eq "builtin_basic" "${source}" "应使用内置生成器"
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  bash -n "${test_file}" 2>/dev/null
  assert_eq "0" "$?" "逻辑测试应通过bash -n语法检查"
  rm -f "${test_file}" 2>/dev/null
}

test_builtin_gen_unknown_type() {
  mkdir -p "${TEST_TMP}/bt_repo4"
  echo 'data' > "${TEST_TMP}/bt_repo4/file.txt"
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"check something","location":"file.txt:1","issue_type":"unknown_type","risk_statement":"unknown"}'
  local framework='{"name":"bash","command":"bash","language":"shell"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/bt_repo4" 2>/dev/null)
  local source
  source=$(echo "${test_info}" | jq -r '.source')
  assert_eq "builtin_basic" "${source}" "未知类型也应使用内置生成器"
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  bash -n "${test_file}" 2>/dev/null
  assert_eq "0" "$?" "未知类型测试应通过bash -n语法检查"
  rm -f "${test_file}" 2>/dev/null
}

test_builtin_gen_test_passes_on_existing_file() {
  mkdir -p "${TEST_TMP}/bt_repo5"
  echo '#!/bin/bash' > "${TEST_TMP}/bt_repo5/good.sh"
  echo 'echo working' >> "${TEST_TMP}/bt_repo5/good.sh"
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"verify good.sh works","location":"good.sh:1","issue_type":"missing_test","risk_statement":"untested"}'
  local framework='{"name":"bash","command":"bash","language":"shell"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/bt_repo5" 2>/dev/null)
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  # 实际执行生成的测试 — 目标文件存在且有效，应该 PASS
  local exec_result
  exec_result=$(execute_test "${test_info}" "${TEST_TMP}/bt_repo5" 10 2>/dev/null) || true
  assert_json_field "${exec_result}" ".status" "PASS" "目标文件存在时内置测试应PASS"
  rm -f "${test_file}" 2>/dev/null
}

test_builtin_gen_test_fails_on_missing_file() {
  mkdir -p "${TEST_TMP}/bt_repo6"
  # 不创建目标文件
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"verify nonexistent","location":"nonexistent.sh:5","issue_type":"logic_bug","risk_statement":"problem"}'
  local framework='{"name":"bash","command":"bash","language":"shell"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/bt_repo6" 2>/dev/null)
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  # 实际执行生成的测试 — 目标文件不存在，应该 FAIL
  local exec_result
  exec_result=$(execute_test "${test_info}" "${TEST_TMP}/bt_repo6" 10 2>/dev/null) || true
  assert_json_field "${exec_result}" ".status" "FAIL" "目标文件不存在时内置测试应FAIL"
  rm -f "${test_file}" 2>/dev/null
}

test_builtin_gen_external_cmd_takes_priority() {
  mkdir -p "${TEST_TMP}/bt_repo7"
  export BASHCLAW_TEST_GEN_CMD="echo '#!/bin/bash'; echo 'exit 0'"
  local issue='{"verification_plan":"test","location":"file.sh:1","issue_type":"logic_bug","risk_statement":"problem"}'
  local framework='{"name":"bash","command":"bash","language":"shell"}'
  local test_info
  test_info=$(generate_targeted_test "${issue}" "${framework}" "${TEST_TMP}/bt_repo7" 2>/dev/null)
  local source
  source=$(echo "${test_info}" | jq -r '.source')
  assert_eq "model_generated" "${source}" "外部模型可用时应优先使用"
  local test_file
  test_file=$(echo "${test_info}" | jq -r '.test_file')
  rm -f "${test_file}" 2>/dev/null
  unset BASHCLAW_TEST_GEN_CMD
}

test_builtin_gen_e2e_full_flow_no_framework() {
  # 端到端测试：无框架 + 无外部模型，完整流程应使用内置生成器
  mkdir -p "${TEST_TMP}/e2e_repo"
  echo '#!/bin/bash' > "${TEST_TMP}/e2e_repo/main.sh"
  echo 'echo "hello world"' >> "${TEST_TMP}/e2e_repo/main.sh"
  unset BASHCLAW_TEST_GEN_CMD 2>/dev/null || true
  unset BASHCLAW_MOCK_TEST_CONTENT 2>/dev/null || true
  local issue='{"verification_plan":"verify main.sh runs correctly","location":"main.sh:2","issue_type":"missing_test","risk_statement":"no test"}'
  local result
  result=$(run_targeted_validation "${issue}" "${TEST_TMP}/e2e_repo" 2>/dev/null) || true
  assert_json_field "${result}" ".method" "targeted_test" "method应为targeted_test"
  assert_json_field "${result}" ".status" "PASS" "存在文件的端到端流程应PASS"
  local source
  source=$(echo "${result}" | jq -r '.test_info.source // empty')
  assert_eq "builtin_basic" "${source}" "应使用内置生成器"
}

###############################################################################
# 6. execute_repro_step
###############################################################################
test_repro_step_no_plan() {
  local issue='{"issue_type":"logic_bug"}'
  local result
  result=$(execute_repro_step "${issue}" "${TEST_TMP}" 2>/dev/null) || true
  assert_json_field "${result}" ".status" "NOT_EXECUTABLE" "无verification_plan应返回NOT_EXECUTABLE"
  assert_json_field "${result}" ".method" "repro_step" "method应为repro_step"
}

test_repro_step_no_gen_cmd() {
  unset BASHCLAW_REPRO_GEN_CMD 2>/dev/null || true
  local issue='{"verification_plan":"check that X happens","issue_type":"logic_bug"}'
  local result
  result=$(execute_repro_step "${issue}" "${TEST_TMP}" 2>/dev/null) || true
  assert_json_field "${result}" ".status" "NOT_EXECUTABLE" "无生成命令应返回NOT_EXECUTABLE"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_targeted_validation.sh =="

run_test test_tv_result_enums_defined
run_test test_default_timeout_defined
run_test test_detect_framework_empty_repo
run_test test_detect_framework_python_pyproject
run_test test_detect_framework_js_package_json
run_test test_detect_framework_js_pnpm
run_test test_detect_framework_js_yarn
run_test test_detect_framework_go
run_test test_detect_framework_output_is_json_array
run_test test_generate_with_mock_content
run_test test_generate_without_external_falls_back_to_builtin
run_test test_generate_creates_correct_python_path
run_test test_generate_creates_correct_js_path
run_test test_execute_test_missing_file
run_test test_execute_test_passing_script
run_test test_execute_test_failing_script
run_test test_execute_test_output_has_fields
run_test test_run_targeted_no_framework_uses_builtin
run_test test_run_targeted_output_structure
run_test test_builtin_gen_missing_test_type
run_test test_builtin_gen_security_risk_type
run_test test_builtin_gen_logic_bug_type
run_test test_builtin_gen_unknown_type
run_test test_builtin_gen_test_passes_on_existing_file
run_test test_builtin_gen_test_fails_on_missing_file
run_test test_builtin_gen_external_cmd_takes_priority
run_test test_builtin_gen_e2e_full_flow_no_framework
run_test test_repro_step_no_plan
run_test test_repro_step_no_gen_cmd

print_report "test_targeted_validation.sh"
