#!/usr/bin/env bash
###############################################################################
# run_tests.sh — BashClaw V1 测试运行器
#
# 运行所有测试文件并汇总结果。
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/tests"

total_suites=0
passed_suites=0
failed_suites=0
failed_names=()

echo "============================================="
echo "  BashClaw V1 测试套件"
echo "  时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================="
echo ""

for test_file in "${TEST_DIR}"/test_*.sh; do
  [[ "$(basename "${test_file}")" == "test_helper.sh" ]] && continue
  total_suites=$((total_suites + 1))
  suite_name="$(basename "${test_file}")"
  echo "--- Running ${suite_name} ---"
  if bash "${test_file}"; then
    passed_suites=$((passed_suites + 1))
  else
    failed_suites=$((failed_suites + 1))
    failed_names+=("${suite_name}")
  fi
  echo ""
done

echo "============================================="
echo "  测试汇总"
echo "============================================="
echo "  套件总数: ${total_suites}"
echo "  通过: ${passed_suites}"
echo "  失败: ${failed_suites}"
if [[ ${failed_suites} -gt 0 ]]; then
  echo ""
  echo "  失败套件:"
  for name in "${failed_names[@]}"; do
    echo "    x ${name}"
  done
fi
echo "============================================="

[[ ${failed_suites} -eq 0 ]]
