#!/usr/bin/env bash
###############################################################################
# test_audit_log.sh — Audit Log 模块测试
#
# 测试清单（对照统一实施文档第26节）：
#   - JSON字段完整性（逐字段）
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_audit_log() {
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  mkdir -p "${AUDIT_LOG_DIR}"
  source "${LIB_DIR}/audit_log.sh"
}

###############################################################################
# 1. 审计日志 JSON 字段完整性 — 对照文档第26节
###############################################################################
test_audit_log_all_fields() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write \
    "20260324-abc123" \
    "bashclaw" \
    "reviewed" \
    "critical" \
    "opus4.6" \
    "codex" \
    "4" \
    "126" \
    "logic_change" \
    "auth,token" \
    "KB-102,KB-118" \
    "high" \
    "true" \
    '[{"name":"pytest","status":"PASS"},{"name":"ruff","status":"PASS"}]' \
    "3" \
    "1" \
    "1" \
    "1" \
    "0" \
    '[{"issue_id":"I-1","status":"FAILED","result":"CONFIRMED"}]' \
    "true" \
    "must_check_tenant_boundary" \
    "merged" \
    "DELIVERED" \
    "true" \
    "18432")

  [[ -f "${log_file}" ]] || { echo "日志文件未创建" >&2; return 1; }
  local content
  content=$(cat "${log_file}")

  # 逐字段验证（对照文档第26节）
  assert_json_field "${content}" ".task_id" "20260324-abc123" "task_id"
  assert_json_field "${content}" ".platform" "bashclaw" "platform"
  assert_json_field "${content}" ".tier_requested" "reviewed" "tier_requested"
  assert_json_field "${content}" ".tier_effective" "critical" "tier_effective"
  assert_json_field "${content}" ".executor_model" "opus4.6" "executor_model"
  assert_json_field "${content}" ".reviewer_model" "codex" "reviewer_model"
  assert_json_field "${content}" ".changed_files" "4" "changed_files"
  assert_json_field "${content}" ".diff_lines" "126" "diff_lines"
  assert_json_field "${content}" ".change_type" "logic_change" "change_type"
  assert_json_field "${content}" ".knowledge_confidence" "high" "knowledge_confidence"
  assert_json_field "${content}" ".knowledge_helpful" "true" "knowledge_helpful"
  assert_json_field "${content}" ".review_issue_count" "3" "review_issue_count"
  assert_json_field "${content}" ".confirmed_issue_count" "1" "confirmed_issue_count"
  assert_json_field "${content}" ".refuted_issue_count" "1" "refuted_issue_count"
  assert_json_field "${content}" ".unverifiable_issue_count" "1" "unverifiable_issue_count"
  assert_json_field "${content}" ".requirement_conflict_count" "0" "requirement_conflict_count"
  assert_json_field "${content}" ".human_escalated" "true" "human_escalated"
  assert_json_field "${content}" ".human_final_decision" "must_check_tenant_boundary" "human_final_decision"
  assert_json_field "${content}" ".memory_writeback_status" "merged" "memory_writeback_status"
  assert_json_field "${content}" ".final_status" "DELIVERED" "final_status"
  assert_json_field "${content}" ".resolved" "true" "resolved"
  assert_json_field "${content}" ".token_total" "18432" "token_total"
}

test_audit_log_has_timestamp() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write "test-ts")
  local content
  content=$(cat "${log_file}")
  assert_json_has_field "${content}" ".timestamp" "应包含timestamp"
  assert_matches "$(echo "${content}" | jq -r '.timestamp')" "20[0-9]{2}-[0-9]{2}-[0-9]{2}T" "timestamp应为ISO格式"
}

test_audit_log_risk_tags_array() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write "test-tags" "bashclaw" "default" "default" "opus4.6" "" "0" "0" "logic_change" "auth,token,secret")
  local content
  content=$(cat "${log_file}")
  local tag_count
  tag_count=$(echo "${content}" | jq '.risk_tags | length')
  assert_eq "3" "${tag_count}" "risk_tags应有3个元素"
  assert_json_field "${content}" '.risk_tags[0]' "auth" "第一个risk_tag应为auth"
  assert_json_field "${content}" '.risk_tags[1]' "token" "第二个risk_tag应为token"
}

test_audit_log_knowledge_hits_array() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write "test-hits" "bashclaw" "default" "default" "opus4.6" "" "0" "0" "logic_change" "" "KB-102,KB-118")
  local content
  content=$(cat "${log_file}")
  local hit_count
  hit_count=$(echo "${content}" | jq '.knowledge_hits | length')
  assert_eq "2" "${hit_count}" "knowledge_hits应有2个元素"
}

test_audit_log_base_validation_array() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write "test-bv" "bashclaw" "default" "default" "opus4.6" "" "0" "0" "logic_change" "" "" "low" "false" '[{"name":"pytest","status":"PASS"}]')
  local content
  content=$(cat "${log_file}")
  local bv_count
  bv_count=$(echo "${content}" | jq '.base_validation | length')
  assert_eq "1" "${bv_count}" "base_validation应有1个元素"
  assert_json_field "${content}" '.base_validation[0].name' "pytest" "base_validation[0].name应为pytest"
}

test_audit_log_targeted_validations_array() {
  _load_audit_log
  local tvs='[{"issue_id":"I-1","status":"FAILED","result":"CONFIRMED"}]'
  local log_file
  log_file=$(audit_log_write "test-tv" "bashclaw" "default" "default" "opus4.6" "" "0" "0" "logic_change" "" "" "low" "false" "[]" "0" "0" "0" "0" "0" "${tvs}")
  local content
  content=$(cat "${log_file}")
  local tv_count
  tv_count=$(echo "${content}" | jq '.targeted_validations | length')
  assert_eq "1" "${tv_count}" "targeted_validations应有1个元素"
}

###############################################################################
# 2. audit_log_update
###############################################################################
test_audit_log_update_field() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write "test-update")
  audit_log_update "test-update" "final_status" '"DELIVERED"'
  local content
  content=$(cat "${log_file}")
  assert_json_field "${content}" ".final_status" "DELIVERED" "更新后final_status应为DELIVERED"
}

test_audit_log_update_nonexistent() {
  _load_audit_log
  local result=0
  audit_log_update "nonexistent-task" "field" '"value"' 2>/dev/null || result=$?
  assert_eq "1" "${result}" "更新不存在的日志应返回错误"
}

###############################################################################
# 3. audit_generate_task_id 格式
###############################################################################
test_audit_task_id_format() {
  _load_audit_log
  local task_id
  task_id=$(audit_generate_task_id)
  assert_matches "${task_id}" "^[0-9]{8}-" "task_id应以日期开头"
}

###############################################################################
# 4. audit_log_show
###############################################################################
test_audit_log_show_existing() {
  _load_audit_log
  audit_log_write "test-show" >/dev/null
  local output
  output=$(audit_log_show "test-show")
  assert_contains "${output}" "test-show" "应显示日志内容"
}

test_audit_log_show_nonexistent() {
  _load_audit_log
  local result=0
  audit_log_show "nonexistent" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "不存在的日志应返回错误"
}

###############################################################################
# 5. 空值默认处理
###############################################################################
test_audit_log_defaults() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write "test-defaults")
  local content
  content=$(cat "${log_file}")
  assert_json_field "${content}" ".platform" "bashclaw" "默认platform应为bashclaw"
  assert_json_field "${content}" ".tier_requested" "default" "默认tier_requested应为default"
  assert_json_field "${content}" ".executor_model" "opus4.6" "默认executor_model应为opus4.6"
  assert_json_field "${content}" ".resolved" "false" "默认resolved应为false"
  assert_json_field "${content}" ".human_escalated" "false" "默认human_escalated应为false"
}

###############################################################################
# 6. JSON 有效性
###############################################################################
test_audit_log_valid_json() {
  _load_audit_log
  local log_file
  log_file=$(audit_log_write "test-json-valid" "bashclaw" "reviewed" "critical" "opus4.6" "codex" "2" "50" "logic_change" "auth" "KB-1" "high" "true" "[]" "1" "1" "0" "0" "0" "[]" "false" "" "none" "PENDING" "false" "5000")
  local content
  content=$(cat "${log_file}")
  echo "${content}" | jq . >/dev/null 2>&1 || {
    echo "审计日志不是有效JSON" >&2
    return 1
  }
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_audit_log.sh =="

run_test test_audit_log_all_fields
run_test test_audit_log_has_timestamp
run_test test_audit_log_risk_tags_array
run_test test_audit_log_knowledge_hits_array
run_test test_audit_log_base_validation_array
run_test test_audit_log_targeted_validations_array
run_test test_audit_log_update_field
run_test test_audit_log_update_nonexistent
run_test test_audit_task_id_format
run_test test_audit_log_show_existing
run_test test_audit_log_show_nonexistent
run_test test_audit_log_defaults
run_test test_audit_log_valid_json

print_report "test_audit_log.sh"
