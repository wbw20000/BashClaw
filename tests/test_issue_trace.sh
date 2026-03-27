#!/usr/bin/env bash
###############################################################################
# test_issue_trace.sh — Issue Trace 模块测试
#
# 测试清单（对照统一实施文档第14节）：
#   - 10个记录节点
#   - ledger comment
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_issue_trace() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export ISSUE_TRACE_DIR="${TEST_TMP}/.bashclaw/issue_trace"
  export ARTIFACT_DIR="${TEST_TMP}/.bashclaw/artifacts"
  source "${LIB_DIR}/issue_trace.sh"
}

###############################################################################
# 1. 10个记录节点验证
###############################################################################
test_trace_nodes_count() {
  _load_issue_trace
  local count="${#TRACE_NODES[@]}"
  assert_eq "10" "${count}" "应有10个记录节点"
}

test_trace_node_intake() {
  _load_issue_trace
  assert_true "INTAKE应是有效节点" _trace_validate_node "INTAKE"
}

test_trace_node_knowledge_precheck() {
  _load_issue_trace
  assert_true "KNOWLEDGE_PRECHECK应是有效节点" _trace_validate_node "KNOWLEDGE_PRECHECK"
}

test_trace_node_plan() {
  _load_issue_trace
  assert_true "PLAN应是有效节点" _trace_validate_node "PLAN"
}

test_trace_node_executor_result() {
  _load_issue_trace
  assert_true "EXECUTOR_RESULT应是有效节点" _trace_validate_node "EXECUTOR_RESULT"
}

test_trace_node_base_validation() {
  _load_issue_trace
  assert_true "BASE_VALIDATION应是有效节点" _trace_validate_node "BASE_VALIDATION"
}

test_trace_node_review_issues() {
  _load_issue_trace
  assert_true "REVIEW_ISSUES应是有效节点" _trace_validate_node "REVIEW_ISSUES"
}

test_trace_node_evidence_resolution() {
  _load_issue_trace
  assert_true "EVIDENCE_RESOLUTION应是有效节点" _trace_validate_node "EVIDENCE_RESOLUTION"
}

test_trace_node_human_decision() {
  _load_issue_trace
  assert_true "HUMAN_DECISION应是有效节点" _trace_validate_node "HUMAN_DECISION"
}

test_trace_node_memory_writeback() {
  _load_issue_trace
  assert_true "MEMORY_WRITEBACK应是有效节点" _trace_validate_node "MEMORY_WRITEBACK"
}

test_trace_node_final_delivery() {
  _load_issue_trace
  assert_true "FINAL_DELIVERY应是有效节点" _trace_validate_node "FINAL_DELIVERY"
}

test_trace_invalid_node() {
  _load_issue_trace
  assert_false "INVALID_NODE不应是有效节点" _trace_validate_node "INVALID_NODE"
  assert_false "空字符串不应是有效节点" _trace_validate_node ""
  assert_false "intake(小写)不应是有效节点" _trace_validate_node "intake"
}

###############################################################################
# 2. issue trace 创建
###############################################################################
test_trace_create_file() {
  _load_issue_trace
  local trace_file
  trace_file=$(issue_trace_create "task-001" "Fix auth bug" "tier2")
  [[ -f "${trace_file}" ]] || { echo "trace文件未创建" >&2; return 1; }
}

test_trace_create_content() {
  _load_issue_trace
  local trace_file
  trace_file=$(issue_trace_create "task-002" "Add token validation" "tier3")
  local content
  content=$(cat "${trace_file}")
  assert_contains "${content}" "task-002" "应包含task_id"
  assert_contains "${content}" "tier3" "应包含tier"
  assert_contains "${content}" "Add token validation" "应包含需求摘要"
  assert_contains "${content}" "OPEN" "状态应为OPEN"
  assert_contains "${content}" "INTAKE" "应包含自动的INTAKE节点"
}

test_trace_create_auto_intake() {
  _load_issue_trace
  local trace_file
  trace_file=$(issue_trace_create "task-003" "Refactor module" "tier1")
  local content
  content=$(cat "${trace_file}")
  assert_contains "${content}" "INTAKE" "应自动记录INTAKE节点"
  assert_contains "${content}" "任务已接收" "INTAKE应包含接收信息"
}

###############################################################################
# 3. ledger comment 记录
###############################################################################
test_trace_record_node() {
  _load_issue_trace
  issue_trace_create "task-004" "Test task" "tier2" > /dev/null
  issue_trace_record "task-004" "KNOWLEDGE_PRECHECK" "Found 2 similar decisions"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-004.md")
  assert_contains "${content}" "KNOWLEDGE_PRECHECK" "应包含记录的节点"
  assert_contains "${content}" "Found 2 similar decisions" "应包含记录的内容"
}

test_trace_record_multiple_nodes() {
  _load_issue_trace
  issue_trace_create "task-005" "Complex task" "tier3" > /dev/null
  issue_trace_record "task-005" "KNOWLEDGE_PRECHECK" "KB hit: kb-101"
  issue_trace_record "task-005" "PLAN" "Will modify auth/session.py"
  issue_trace_record "task-005" "EXECUTOR_RESULT" "3 files changed"
  issue_trace_record "task-005" "BASE_VALIDATION" "pytest PASS, ruff PASS"
  issue_trace_record "task-005" "REVIEW_ISSUES" "2 issues found"
  issue_trace_record "task-005" "EVIDENCE_RESOLUTION" "1 CONFIRMED, 1 REFUTED"
  issue_trace_record "task-005" "HUMAN_DECISION" "Approved with condition"
  issue_trace_record "task-005" "MEMORY_WRITEBACK" "New knowledge entry created"
  issue_trace_record "task-005" "FINAL_DELIVERY" "Task completed"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-005.md")
  # 验证所有10个节点都出现了（INTAKE自动创建 + 9个手动记录）
  assert_contains "${content}" "INTAKE" "应包含INTAKE"
  assert_contains "${content}" "KNOWLEDGE_PRECHECK" "应包含KNOWLEDGE_PRECHECK"
  assert_contains "${content}" "PLAN" "应包含PLAN"
  assert_contains "${content}" "EXECUTOR_RESULT" "应包含EXECUTOR_RESULT"
  assert_contains "${content}" "BASE_VALIDATION" "应包含BASE_VALIDATION"
  assert_contains "${content}" "REVIEW_ISSUES" "应包含REVIEW_ISSUES"
  assert_contains "${content}" "EVIDENCE_RESOLUTION" "应包含EVIDENCE_RESOLUTION"
  assert_contains "${content}" "HUMAN_DECISION" "应包含HUMAN_DECISION"
  assert_contains "${content}" "MEMORY_WRITEBACK" "应包含MEMORY_WRITEBACK"
  assert_contains "${content}" "FINAL_DELIVERY" "应包含FINAL_DELIVERY"
}

test_trace_record_invalid_node_rejected() {
  _load_issue_trace
  issue_trace_create "task-006" "Test task" "tier1" > /dev/null
  local result=0
  issue_trace_record "task-006" "INVALID_NODE" "Should fail" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "无效节点应被拒绝"
}

test_trace_record_auto_create_if_missing() {
  _load_issue_trace
  # 不先创建trace，直接record
  issue_trace_record "task-007" "BASE_VALIDATION" "All tests pass" 2>/dev/null
  [[ -f "${ISSUE_TRACE_DIR}/task-007.md" ]] || { echo "应自动创建trace" >&2; return 1; }
}

###############################################################################
# 4. ledger comment 格式
###############################################################################
test_trace_ledger_has_timestamp() {
  _load_issue_trace
  issue_trace_create "task-008" "Test" "tier1" > /dev/null
  issue_trace_record "task-008" "PLAN" "Do something"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-008.md")
  # 时间戳格式: [YYYY-MM-DDTHH:MM:SSZ]
  assert_matches "${content}" '\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' "应包含ISO时间戳"
}

test_trace_ledger_ordered() {
  _load_issue_trace
  issue_trace_create "task-009" "Test" "tier2" > /dev/null
  issue_trace_record "task-009" "KNOWLEDGE_PRECHECK" "First"
  issue_trace_record "task-009" "PLAN" "Second"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-009.md")
  # KNOWLEDGE_PRECHECK 应出现在 PLAN 之前
  local pos_kp pos_plan
  pos_kp=$(echo "${content}" | grep -n "KNOWLEDGE_PRECHECK" | head -1 | cut -d: -f1)
  pos_plan=$(echo "${content}" | grep -n "PLAN" | head -1 | cut -d: -f1)
  [[ "${pos_kp}" -lt "${pos_plan}" ]] || { echo "KNOWLEDGE_PRECHECK应在PLAN之前" >&2; return 1; }
}

###############################################################################
# 5. FINAL_DELIVERY 关闭 issue
###############################################################################
test_trace_final_delivery_closes_issue() {
  _load_issue_trace
  issue_trace_create "task-010" "Test" "tier1" > /dev/null
  issue_trace_record_final_delivery "task-010" "Completed successfully"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-010.md")
  assert_contains "${content}" "CLOSED" "FINAL_DELIVERY后状态应为CLOSED"
  assert_not_contains "${content}" "OPEN" "不应再包含OPEN状态"
}

###############################################################################
# 6. artifact 支持
###############################################################################
test_trace_record_with_artifact() {
  _load_issue_trace
  issue_trace_create "task-011" "Test" "tier2" > /dev/null
  # 创建一个详细内容文件
  local detail_file="${TEST_TMP}/detail.md"
  echo "Long detailed review output..." > "${detail_file}"
  issue_trace_record "task-011" "REVIEW_ISSUES" "3 issues found" "${detail_file}"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-011.md")
  assert_contains "${content}" "artifacts/" "应引用artifact文件"
}

###############################################################################
# 7. issue_trace_get 和 issue_trace_list
###############################################################################
test_trace_get_existing() {
  _load_issue_trace
  issue_trace_create "task-012" "Get test" "tier1" > /dev/null
  local content
  content=$(issue_trace_get "task-012")
  assert_contains "${content}" "task-012" "应返回trace内容"
}

test_trace_get_nonexistent() {
  _load_issue_trace
  local result=0
  issue_trace_get "nonexistent" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "不存在的trace应返回错误"
}

test_trace_list() {
  _load_issue_trace
  issue_trace_create "task-013" "List test 1" "tier1" > /dev/null
  issue_trace_create "task-014" "List test 2" "tier2" > /dev/null
  local list
  list=$(issue_trace_list)
  assert_contains "${list}" "task-013" "应列出task-013"
  assert_contains "${list}" "task-014" "应列出task-014"
}

###############################################################################
# 8. sub-issue 支持
###############################################################################
test_trace_sub_issue_creation() {
  _load_issue_trace
  issue_trace_create "task-015" "Parent task" "tier3" > /dev/null
  local sub_file
  sub_file=$(issue_trace_create_sub_issue "task-015" "sub1" "Sub task details")
  [[ -f "${sub_file}" ]] || { echo "sub-issue文件未创建" >&2; return 1; }
  local content
  content=$(cat "${sub_file}")
  assert_contains "${content}" "task-015_sub1" "应包含完整的sub-issue ID"
  assert_contains "${content}" "task-015" "应包含父任务ID"
}

###############################################################################
# 9. 便捷函数
###############################################################################
test_trace_record_knowledge_precheck() {
  _load_issue_trace
  issue_trace_create "task-016" "Test" "tier2" > /dev/null
  issue_trace_record_knowledge_precheck "task-016" "Hit: KB-101, KB-102"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-016.md")
  assert_contains "${content}" "KNOWLEDGE_PRECHECK" "应记录KNOWLEDGE_PRECHECK"
  assert_contains "${content}" "KB-101" "应包含知识条目引用"
}

test_trace_record_base_validation() {
  _load_issue_trace
  issue_trace_create "task-017" "Test" "tier1" > /dev/null
  issue_trace_record_base_validation "task-017" "pytest: PASS, ruff: PASS"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-017.md")
  assert_contains "${content}" "BASE_VALIDATION" "应记录BASE_VALIDATION"
}

test_trace_record_evidence_resolution() {
  _load_issue_trace
  issue_trace_create "task-018" "Test" "tier2" > /dev/null
  issue_trace_record_evidence_resolution "task-018" "I-1: CONFIRMED, I-2: REFUTED"
  local content
  content=$(cat "${ISSUE_TRACE_DIR}/task-018.md")
  assert_contains "${content}" "EVIDENCE_RESOLUTION" "应记录EVIDENCE_RESOLUTION"
  assert_contains "${content}" "CONFIRMED" "应包含裁决结果"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_issue_trace.sh =="

run_test test_trace_nodes_count
run_test test_trace_node_intake
run_test test_trace_node_knowledge_precheck
run_test test_trace_node_plan
run_test test_trace_node_executor_result
run_test test_trace_node_base_validation
run_test test_trace_node_review_issues
run_test test_trace_node_evidence_resolution
run_test test_trace_node_human_decision
run_test test_trace_node_memory_writeback
run_test test_trace_node_final_delivery
run_test test_trace_invalid_node
run_test test_trace_create_file
run_test test_trace_create_content
run_test test_trace_create_auto_intake
run_test test_trace_record_node
run_test test_trace_record_multiple_nodes
run_test test_trace_record_invalid_node_rejected
run_test test_trace_record_auto_create_if_missing
run_test test_trace_ledger_has_timestamp
run_test test_trace_ledger_ordered
run_test test_trace_final_delivery_closes_issue
run_test test_trace_record_with_artifact
run_test test_trace_get_existing
run_test test_trace_get_nonexistent
run_test test_trace_list
run_test test_trace_sub_issue_creation
run_test test_trace_record_knowledge_precheck
run_test test_trace_record_base_validation
run_test test_trace_record_evidence_resolution

print_report "test_issue_trace.sh"
