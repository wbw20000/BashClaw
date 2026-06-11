#!/usr/bin/env bash
###############################################################################
# test_budget.sh — Budget 模块测试
#
# 测试清单（对照统一实施文档第15节）：
#   - 超预算行为
#   - 显式升级例外
#   - UNVERIFIABLE超3个强制人工
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

# budget.sh 使用 BASHCLAW_ROOT，在 setup_tmp 中设置
# 需要先设置然后再 source
_load_budget() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export BUDGET_STATE_DIR="${TEST_TMP}/.bashclaw/budget"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  source "${LIB_DIR}/budget.sh"
}

###############################################################################
# 1. 初始化
###############################################################################
test_budget_init_creates_dirs() {
  _load_budget
  budget_init
  [[ -d "${TEST_TMP}/.bashclaw/budget" ]] || { echo "budget目录未创建" >&2; return 1; }
  [[ -d "${TEST_TMP}/.bashclaw/audit" ]] || { echo "audit目录未创建" >&2; return 1; }
}

test_budget_state_file_created() {
  _load_budget
  budget_init
  _budget_ensure_state
  local state_file
  state_file="$(_budget_state_file)"
  [[ -f "${state_file}" ]] || { echo "状态文件未创建" >&2; return 1; }
}

test_budget_initial_state_zeros() {
  _load_budget
  budget_init
  _budget_ensure_state
  local t2 t3 he
  t2="$(_budget_read_field "tier2_runs")"
  t3="$(_budget_read_field "tier3_runs")"
  he="$(_budget_read_field "human_escalations")"
  assert_eq "0" "${t2}" "初始tier2_runs应为0"
  assert_eq "0" "${t3}" "初始tier3_runs应为0"
  assert_eq "0" "${he}" "初始human_escalations应为0"
}

###############################################################################
# 2. 超预算行为 — Tier 2
###############################################################################
test_budget_tier2_under_limit() {
  _load_budget
  budget_init
  assert_true "未超预算时应返回0" budget_check_tier2
}

test_budget_tier2_at_limit() {
  _load_budget
  budget_init
  # 手动设置到上限
  for i in $(seq 1 20); do
    budget_record_tier2
  done
  local result=0
  budget_check_tier2 2>/dev/null || result=$?
  assert_eq "1" "${result}" "达到Tier2上限(20)时应返回超预算"
}

test_budget_tier2_over_limit() {
  _load_budget
  budget_init
  for i in $(seq 1 21); do
    budget_record_tier2
  done
  local result=0
  budget_check_tier2 2>/dev/null || result=$?
  assert_eq "1" "${result}" "超过Tier2上限时应返回超预算"
}

###############################################################################
# 3. 超预算行为 — Tier 3
###############################################################################
test_budget_tier3_under_limit() {
  _load_budget
  budget_init
  assert_true "未超预算时应返回0" budget_check_tier3
}

test_budget_tier3_at_limit() {
  _load_budget
  budget_init
  for i in 1 2 3; do
    budget_record_tier3
  done
  local result=0
  budget_check_tier3 2>/dev/null || result=$?
  assert_eq "1" "${result}" "达到Tier3上限(3)时应返回超预算"
}

###############################################################################
# 4. 超预算行为 — Human Escalation
###############################################################################
test_budget_human_escalation_under_limit() {
  _load_budget
  budget_init
  assert_true "未超预算时应返回0" budget_check_human_escalation
}

test_budget_human_escalation_at_limit() {
  _load_budget
  budget_init
  for i in 1 2 3 4 5; do
    budget_record_human_escalation
  done
  local result=0
  budget_check_human_escalation 2>/dev/null || result=$?
  assert_eq "1" "${result}" "达到Human Escalation上限(5)时应返回超预算"
}

###############################################################################
# 5. UNVERIFIABLE 超3个强制人工
###############################################################################
test_budget_unverifiable_under_threshold() {
  _load_budget
  budget_init
  assert_true "未超阈值时应返回0" budget_check_unverifiable "0"
  assert_true "1个未超阈值" budget_check_unverifiable "1"
  assert_true "2个未超阈值" budget_check_unverifiable "2"
}

test_budget_unverifiable_at_threshold() {
  _load_budget
  budget_init
  local result=0
  budget_check_unverifiable "3" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "UNVERIFIABLE=3时应强制人工"
}

test_budget_unverifiable_over_threshold() {
  _load_budget
  budget_init
  local result=0
  budget_check_unverifiable "5" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "UNVERIFIABLE>3时应强制人工"
}

###############################################################################
# 6. 记录与递增
###############################################################################
test_budget_record_increments() {
  _load_budget
  budget_init
  budget_record_tier2
  budget_record_tier2
  budget_record_tier3
  local t2 t3
  t2="$(_budget_read_field "tier2_runs")"
  t3="$(_budget_read_field "tier3_runs")"
  assert_eq "2" "${t2}" "记录2次tier2后应为2"
  assert_eq "1" "${t3}" "记录1次tier3后应为1"
}

###############################################################################
# 7. 预算状态获取
###############################################################################
test_budget_get_status_format() {
  _load_budget
  budget_init
  budget_record_tier2
  local status
  status=$(budget_get_status)
  assert_json_has_field "${status}" ".tier2.used" "应包含tier2.used"
  assert_json_has_field "${status}" ".tier2.max" "应包含tier2.max"
  assert_json_has_field "${status}" ".tier3.used" "应包含tier3.used"
  assert_json_has_field "${status}" ".tier3.max" "应包含tier3.max"
  assert_json_has_field "${status}" ".human_escalations.used" "应包含human_escalations.used"
  assert_json_has_field "${status}" ".human_escalations.max" "应包含human_escalations.max"
  assert_json_has_field "${status}" ".date" "应包含date"
}

test_budget_get_status_values() {
  _load_budget
  budget_init
  budget_record_tier2
  budget_record_tier2
  budget_record_tier3
  local status
  status=$(budget_get_status)
  assert_json_field "${status}" ".tier2.used" "2" "tier2.used应为2"
  assert_json_field "${status}" ".tier3.used" "1" "tier3.used应为1"
  assert_json_field "${status}" ".human_escalations.used" "0" "human_escalations.used应为0"
}

###############################################################################
# 8. 超预算事件写入日志
###############################################################################
test_budget_overflow_logged() {
  _load_budget
  budget_init
  for i in $(seq 1 20); do
    budget_record_tier2
  done
  budget_check_tier2 2>/dev/null || true
  local log_file="${TEST_TMP}/.bashclaw/audit/budget_overflow.log"
  [[ -f "${log_file}" ]] || { echo "超预算日志文件未创建" >&2; return 1; }
  local content
  content=$(cat "${log_file}")
  assert_contains "${content}" "BUDGET_OVERFLOW" "日志应包含BUDGET_OVERFLOW"
  assert_contains "${content}" "tier2" "日志应包含tier2"
}

###############################################################################
# 9. 警告机制
###############################################################################
test_budget_warn_near_limit() {
  _load_budget
  budget_init
  # Tier2 上限20, 80%=16
  for i in $(seq 1 16); do
    budget_record_tier2
  done
  local warn_output
  warn_output=$(budget_warn_if_enabled "tier2" 2>&1)
  assert_contains "${warn_output}" "BUDGET_WARN" "接近上限时应输出警告"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_budget.sh =="

run_test test_budget_init_creates_dirs
run_test test_budget_state_file_created
run_test test_budget_initial_state_zeros
run_test test_budget_tier2_under_limit
run_test test_budget_tier2_at_limit
run_test test_budget_tier2_over_limit
run_test test_budget_tier3_under_limit
run_test test_budget_tier3_at_limit
run_test test_budget_human_escalation_under_limit
run_test test_budget_human_escalation_at_limit
run_test test_budget_unverifiable_under_threshold
run_test test_budget_unverifiable_at_threshold
run_test test_budget_unverifiable_over_threshold
run_test test_budget_record_increments
run_test test_budget_get_status_format
run_test test_budget_get_status_values
run_test test_budget_overflow_logged
run_test test_budget_warn_near_limit

print_report "test_budget.sh"
