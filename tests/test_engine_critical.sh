#!/usr/bin/env bash
###############################################################################
# test_engine_critical.sh — Tier 3 Critical 编排引擎测试
#
# 测试清单（对照统一实施文档第6.3节）：
#   - engine_critical_run 参数验证
#   - engine_critical_complete_decision 裁决流程
#   - engine_critical_get_status 状态查询
#   - _critical_build_writeback_context 上下文构建
#   - audit_log_event 事件日志
#   - 预算阻止逻辑
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_engine_critical() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  export BUDGET_STATE_DIR="${TEST_TMP}/.bashclaw/budget"
  export ISSUE_TRACE_DIR="${TEST_TMP}/.bashclaw/issue_trace"
  export ARTIFACT_DIR="${TEST_TMP}/.bashclaw/artifacts"
  export KNOWLEDGE_DIR="${TEST_TMP}/.bashclaw/knowledge"
  export WRITEBACK_LOG="${TEST_TMP}/.bashclaw/audit/writeback.log"
  export ESCALATION_DIR="${TEST_TMP}/.bashclaw/escalations"
  mkdir -p "${AUDIT_LOG_DIR}" "${BUDGET_STATE_DIR}" "${ISSUE_TRACE_DIR}"
  mkdir -p "${ARTIFACT_DIR}" "${KNOWLEDGE_DIR}" "${ESCALATION_DIR}"
  mkdir -p "${TEST_TMP}/.bashclaw/runs"
  # engine_critical.sh sources ${BASHCLAW_ROOT}/lib/*.sh, so symlink lib into temp dir
  [[ -L "${TEST_TMP}/lib" || -d "${TEST_TMP}/lib" ]] || ln -s "${LIB_DIR}" "${TEST_TMP}/lib"
  source "${LIB_DIR}/engine_critical.sh"
}

###############################################################################
# 1. audit_log_event — 事件日志
###############################################################################
test_audit_log_event_writes() {
  _load_engine_critical
  audit_log_event "TEST" "test_event" "detail=hello"
  local log_file="${AUDIT_LOG_DIR}/events.log"
  [[ -f "${log_file}" ]] || { echo "事件日志文件未创建" >&2; return 1; }
  local content
  content=$(cat "${log_file}")
  assert_contains "${content}" "TEST" "应包含category"
  assert_contains "${content}" "test_event" "应包含event"
  assert_contains "${content}" "detail=hello" "应包含detail"
}

test_audit_log_event_has_timestamp() {
  _load_engine_critical
  audit_log_event "TS_TEST" "check_ts" ""
  local content
  content=$(cat "${AUDIT_LOG_DIR}/events.log")
  assert_matches "${content}" "20[0-9]{2}-[0-9]{2}-[0-9]{2}T" "应包含ISO时间戳"
}

###############################################################################
# 2. engine_critical_get_status
###############################################################################
test_get_status_not_found() {
  _load_engine_critical
  local result=0
  engine_critical_get_status "nonexistent-task" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "不存在的任务应返回错误"
}

test_get_status_returns_content() {
  _load_engine_critical
  local work_dir="${TEST_TMP}/.bashclaw/runs/test-status"
  mkdir -p "${work_dir}"
  echo "AWAITING_HUMAN_DECISION" > "${work_dir}/status"
  local status
  status=$(engine_critical_get_status "test-status")
  assert_eq "AWAITING_HUMAN_DECISION" "${status}" "应返回正确状态"
}

###############################################################################
# 3. _critical_build_writeback_context
###############################################################################
test_build_writeback_context_json() {
  _load_engine_critical
  local work_dir="${TEST_TMP}/.bashclaw/runs/ctx-test"
  mkdir -p "${work_dir}"
  echo "Knowledge: found relevant decision" > "${work_dir}/knowledge_precheck.txt"
  local result
  result=$(_critical_build_writeback_context "ctx-test" "ACCEPT" "Approved the change")
  echo "${result}" | jq . > /dev/null 2>&1 || {
    echo "输出应是有效JSON" >&2
    return 1
  }
}

test_build_writeback_context_has_fields() {
  _load_engine_critical
  local work_dir="${TEST_TMP}/.bashclaw/runs/ctx-test2"
  mkdir -p "${work_dir}"
  echo "KB hit" > "${work_dir}/knowledge_precheck.txt"
  local result
  result=$(_critical_build_writeback_context "ctx-test2" "REJECT" "Not acceptable")
  assert_contains "${result}" "ctx-test2" "应包含task_id"
  assert_contains "${result}" "REJECT" "应包含decision"
  assert_contains "${result}" "Not acceptable" "应包含detail"
}

test_build_writeback_context_no_knowledge() {
  _load_engine_critical
  local work_dir="${TEST_TMP}/.bashclaw/runs/ctx-nokg"
  mkdir -p "${work_dir}"
  # 不创建 knowledge_precheck.txt
  local result
  result=$(_critical_build_writeback_context "ctx-nokg" "ACCEPT" "OK")
  assert_contains "${result}" "N/A" "无knowledge时应为N/A"
}

###############################################################################
# 4. engine_critical_complete_decision — 状态验证
###############################################################################
test_complete_decision_missing_task() {
  _load_engine_critical
  local result=0
  engine_critical_complete_decision "nonexistent" "ACCEPT" "OK" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "不存在的任务应返回错误"
}

test_complete_decision_wrong_status() {
  _load_engine_critical
  local work_dir="${TEST_TMP}/.bashclaw/runs/wrong-status"
  mkdir -p "${work_dir}"
  echo "DELIVERED" > "${work_dir}/status"
  local result=0
  engine_critical_complete_decision "wrong-status" "ACCEPT" "OK" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "状态不正确时应返回错误"
}

test_complete_decision_need_more_info() {
  _load_engine_critical
  local work_dir="${TEST_TMP}/.bashclaw/runs/need-info"
  mkdir -p "${work_dir}"
  echo "AWAITING_HUMAN_DECISION" > "${work_dir}/status"
  # 创建必要的中间文件
  echo '[]' > "${work_dir}/reviewer_issues.json"
  echo '[]' > "${work_dir}/resolution_results.json"
  echo "knowledge" > "${work_dir}/knowledge_precheck.txt"
  echo "executed" > "${work_dir}/executor_result.txt"
  local result=0
  engine_critical_complete_decision "need-info" "NEED_MORE_INFO" "Need details" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "NEED_MORE_INFO应返回1"
  local new_status
  new_status=$(cat "${work_dir}/status")
  assert_eq "NEED_MORE_INFO" "${new_status}" "状态应更新为NEED_MORE_INFO"
}

###############################################################################
# 5. engine_critical_run — 预算阻止
###############################################################################
test_critical_run_budget_block() {
  _load_engine_critical
  budget_init
  # 耗尽 tier3 预算
  for i in 1 2 3; do
    budget_record_tier3
  done
  local result=0
  engine_critical_run "budget-test" "Test budget block" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "超预算应返回1"
}

###############################################################################
# 6. engine_critical_run — 正常启动
###############################################################################
test_critical_run_creates_work_dir() {
  _load_engine_critical
  budget_init
  local result=0
  engine_critical_run "work-dir-test" "Test work dir creation" 2>/dev/null || result=$?
  # Tier 3 总是返回1（等待人工裁决），这是正常行为
  [[ -d "${TEST_TMP}/.bashclaw/runs/work-dir-test" ]] || {
    echo "工作目录应被创建" >&2
    return 1
  }
}

test_critical_run_creates_status_file() {
  _load_engine_critical
  budget_init
  engine_critical_run "status-test" "Test status file" 2>/dev/null || true
  local status_file="${TEST_TMP}/.bashclaw/runs/status-test/status"
  [[ -f "${status_file}" ]] || { echo "状态文件应被创建" >&2; return 1; }
  local status
  status=$(cat "${status_file}")
  assert_eq "AWAITING_HUMAN_DECISION" "${status}" "初始状态应为AWAITING_HUMAN_DECISION"
}

test_critical_run_creates_issue_trace() {
  _load_engine_critical
  budget_init
  engine_critical_run "trace-test" "Test issue trace" 2>/dev/null || true
  [[ -f "${ISSUE_TRACE_DIR}/trace-test.md" ]] || {
    echo "Issue trace文件应被创建" >&2
    return 1
  }
}

###############################################################################
# 7. 完整 accept 流程
###############################################################################
test_critical_full_accept_flow() {
  _load_engine_critical
  budget_init
  # Step 1: 运行 critical 流程
  engine_critical_run "accept-flow" "Test accept flow" 2>/dev/null || true
  # Step 2: 提交 accept 裁决
  local result=0
  engine_critical_complete_decision "accept-flow" "ACCEPT" "Looks good" 2>/dev/null || result=$?
  assert_eq "0" "${result}" "ACCEPT裁决应成功"
  local final_status
  final_status=$(cat "${TEST_TMP}/.bashclaw/runs/accept-flow/status")
  assert_eq "DELIVERED" "${final_status}" "ACCEPT后状态应为DELIVERED"
}

test_critical_full_reject_flow() {
  _load_engine_critical
  budget_init
  engine_critical_run "reject-flow" "Test reject flow" 2>/dev/null || true
  local result=0
  engine_critical_complete_decision "reject-flow" "REJECT" "Not acceptable" 2>/dev/null || result=$?
  assert_eq "0" "${result}" "REJECT裁决应成功"
  local final_status
  final_status=$(cat "${TEST_TMP}/.bashclaw/runs/reject-flow/status")
  assert_eq "REJECTED" "${final_status}" "REJECT后状态应为REJECTED"
}

test_critical_full_modify_flow() {
  _load_engine_critical
  budget_init
  engine_critical_run "modify-flow" "Test modify flow" 2>/dev/null || true
  local result=0
  engine_critical_complete_decision "modify-flow" "MODIFY" "Small change needed" 2>/dev/null || result=$?
  assert_eq "0" "${result}" "MODIFY裁决应成功"
  local final_status
  final_status=$(cat "${TEST_TMP}/.bashclaw/runs/modify-flow/status")
  assert_eq "DELIVERED_WITH_MODIFICATIONS" "${final_status}" "MODIFY后状态应为DELIVERED_WITH_MODIFICATIONS"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_engine_critical.sh =="

run_test test_audit_log_event_writes
run_test test_audit_log_event_has_timestamp
run_test test_get_status_not_found
run_test test_get_status_returns_content
run_test test_build_writeback_context_json
run_test test_build_writeback_context_has_fields
run_test test_build_writeback_context_no_knowledge
run_test test_complete_decision_missing_task
run_test test_complete_decision_wrong_status
run_test test_complete_decision_need_more_info
run_test test_critical_run_budget_block
run_test test_critical_run_creates_work_dir
run_test test_critical_run_creates_status_file
run_test test_critical_run_creates_issue_trace
run_test test_critical_full_accept_flow
run_test test_critical_full_reject_flow
run_test test_critical_full_modify_flow

print_report "test_engine_critical.sh"
