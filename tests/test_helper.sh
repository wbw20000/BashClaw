#!/usr/bin/env bash
###############################################################################
# test_helper.sh — BashClaw V1 测试框架
#
# 轻量级 Bash 测试框架，无外部依赖。
# 提供断言函数、测试运行器和报告输出。
###############################################################################
set -euo pipefail

# 测试计数器
_TEST_TOTAL=0
_TEST_PASSED=0
_TEST_FAILED=0
_TEST_ERRORS=()

# 项目根目录
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TEST_ROOT}/lib"

# 颜色输出（支持 NO_COLOR）
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  _GREEN='\033[0;32m'
  _RED='\033[0;31m'
  _YELLOW='\033[0;33m'
  _RESET='\033[0m'
else
  _GREEN=''
  _RED=''
  _YELLOW=''
  _RESET=''
fi

# 临时目录管理
TEST_TMP=""
setup_tmp() {
  TEST_TMP="$(mktemp -d)"
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  mkdir -p "${TEST_TMP}/.bashclaw/knowledge"
  mkdir -p "${TEST_TMP}/.bashclaw/audit"
  mkdir -p "${TEST_TMP}/.bashclaw/budget"
  mkdir -p "${TEST_TMP}/.bashclaw/issue_trace"
  mkdir -p "${TEST_TMP}/.bashclaw/artifacts"
  mkdir -p "${TEST_TMP}/.bashclaw/tmp"
  # Copy config
  if [[ -f "${TEST_ROOT}/bashclaw.json" ]]; then
    cp "${TEST_ROOT}/bashclaw.json" "${TEST_TMP}/bashclaw.json"
  fi
}

cleanup_tmp() {
  if [[ -n "${TEST_TMP}" && -d "${TEST_TMP}" ]]; then
    rm -rf "${TEST_TMP}"
  fi
}

# 运行单个测试函数
run_test() {
  local test_name="$1"
  _TEST_TOTAL=$((_TEST_TOTAL + 1))

  # 每个测试重置临时环境
  setup_tmp

  local output
  local exit_code=0
  output=$("$test_name" 2>&1) || exit_code=$?

  cleanup_tmp

  if [[ ${exit_code} -eq 0 ]]; then
    _TEST_PASSED=$((_TEST_PASSED + 1))
    printf "  ${_GREEN}PASS${_RESET} %s\n" "${test_name}"
  else
    _TEST_FAILED=$((_TEST_FAILED + 1))
    printf "  ${_RED}FAIL${_RESET} %s\n" "${test_name}"
    if [[ -n "${output}" ]]; then
      printf "       %s\n" "${output}" | head -5
    fi
    _TEST_ERRORS+=("${test_name}: ${output}")
  fi
}

# 断言函数
assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assert_eq failed}"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "ASSERT_EQ FAILED: ${msg}" >&2
    echo "  expected: '${expected}'" >&2
    echo "  actual:   '${actual}'" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-assert_contains failed}"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "ASSERT_CONTAINS FAILED: ${msg}" >&2
    echo "  haystack: '${haystack}'" >&2
    echo "  needle:   '${needle}'" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-assert_not_contains failed}"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ASSERT_NOT_CONTAINS FAILED: ${msg}" >&2
    echo "  haystack should not contain: '${needle}'" >&2
    return 1
  fi
}

assert_matches() {
  local value="$1"
  local pattern="$2"
  local msg="${3:-assert_matches failed}"
  if ! echo "${value}" | grep -qE "${pattern}"; then
    echo "ASSERT_MATCHES FAILED: ${msg}" >&2
    echo "  value:   '${value}'" >&2
    echo "  pattern: '${pattern}'" >&2
    return 1
  fi
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local msg="${4:-assert_json_field failed}"
  local actual
  actual=$(echo "${json}" | jq -r "${field}" 2>/dev/null) || {
    echo "ASSERT_JSON_FIELD FAILED: ${msg} (jq parse error)" >&2
    return 1
  }
  if [[ "${actual}" != "${expected}" ]]; then
    echo "ASSERT_JSON_FIELD FAILED: ${msg}" >&2
    echo "  field:    ${field}" >&2
    echo "  expected: '${expected}'" >&2
    echo "  actual:   '${actual}'" >&2
    return 1
  fi
}

assert_json_has_field() {
  local json="$1"
  local field="$2"
  local msg="${3:-assert_json_has_field failed}"
  local value
  value=$(echo "${json}" | jq -r "${field}" 2>/dev/null)
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "ASSERT_JSON_HAS_FIELD FAILED: ${msg}" >&2
    echo "  field: ${field} is missing or null" >&2
    return 1
  fi
}

assert_exit_code() {
  local expected="$1"
  shift
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "${expected}" != "${actual}" ]]; then
    echo "ASSERT_EXIT_CODE FAILED" >&2
    echo "  expected exit code: ${expected}" >&2
    echo "  actual exit code:   ${actual}" >&2
    return 1
  fi
}

assert_true() {
  local msg="${1:-assert_true failed}"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "ASSERT_TRUE FAILED: ${msg}" >&2
    return 1
  fi
}

assert_false() {
  local msg="${1:-assert_false failed}"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ASSERT_FALSE FAILED: ${msg}" >&2
    return 1
  fi
}

# 输出最终测试报告
print_report() {
  local test_file="${1:-unknown}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " ${test_file} 测试报告"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  总计: %d  通过: ${_GREEN}%d${_RESET}  失败: ${_RED}%d${_RESET}\n" \
    "${_TEST_TOTAL}" "${_TEST_PASSED}" "${_TEST_FAILED}"

  if [[ ${_TEST_FAILED} -gt 0 ]]; then
    echo ""
    echo "  失败详情:"
    for err in "${_TEST_ERRORS[@]}"; do
      printf "    ${_RED}x${_RESET} %s\n" "${err}" | head -3
    done
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  [[ ${_TEST_FAILED} -eq 0 ]]
}
