#!/usr/bin/env bash
###############################################################################
# test_memory_writeback.sh — Memory Writeback 模块测试
#
# 测试清单（对照统一实施文档第13节）：
#   - 16字段完整性
#   - 去重merge
#   - superseded标记
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_writeback() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export KNOWLEDGE_DIR="${TEST_TMP}/.bashclaw/knowledge"
  export WRITEBACK_LOG="${TEST_TMP}/.bashclaw/audit/writeback.log"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  mkdir -p "${KNOWLEDGE_DIR}"
  mkdir -p "$(dirname "${WRITEBACK_LOG}")"
  source "${LIB_DIR}/memory_writeback.sh"
}

# 创建一个完整的知识条目文件
_make_complete_entry() {
  local filepath="$1"
  local title="${2:-Test Decision}"
  local decision="${3:-Use pattern X}"
  cat > "${filepath}" <<EOF
{
  "decision_title": "${title}",
  "task_summary": "Fix authentication issue",
  "applicable_scope": "auth module",
  "non_applicable_scope": "public api",
  "final_decision": "${decision}",
  "why": "Security requirement",
  "known_pitfalls": ["Do not skip tenant check"],
  "validation_evidence": "pytest pass with targeted test",
  "issue_type": "security_risk",
  "review_or_human_required": true,
  "risk_tags": ["auth", "token"],
  "changeType": "logic_change",
  "linked_issue": "#123",
  "linked_pr": "#456",
  "timestamp": "2026-03-24T00:00:00Z"
}
EOF
}

###############################################################################
# 1. 16字段完整性验证
###############################################################################
test_validate_complete_entry() {
  _load_writeback
  local f="${TEST_TMP}/complete.json"
  _make_complete_entry "${f}"
  assert_true "完整条目应通过验证" _writeback_validate_fields "${f}"
}

test_validate_missing_decision_title() {
  _load_writeback
  local f="${TEST_TMP}/incomplete.json"
  echo '{"task_summary":"x","applicable_scope":"x","non_applicable_scope":"x","final_decision":"x","why":"x","known_pitfalls":"x","validation_evidence":"x","issue_type":"x","review_or_human_required":true,"risk_tags":"x","changeType":"x","linked_issue":"x","linked_pr":"x","timestamp":"x"}' > "${f}"
  assert_false "缺少decision_title应失败" _writeback_validate_fields "${f}"
}

test_validate_missing_task_summary() {
  _load_writeback
  local f="${TEST_TMP}/incomplete.json"
  echo '{"decision_title":"x","applicable_scope":"x","non_applicable_scope":"x","final_decision":"x","why":"x","known_pitfalls":"x","validation_evidence":"x","issue_type":"x","review_or_human_required":true,"risk_tags":"x","changeType":"x","linked_issue":"x","linked_pr":"x","timestamp":"x"}' > "${f}"
  assert_false "缺少task_summary应失败" _writeback_validate_fields "${f}"
}

test_validate_missing_applicable_scope() {
  _load_writeback
  local f="${TEST_TMP}/incomplete.json"
  echo '{"decision_title":"x","task_summary":"x","non_applicable_scope":"x","final_decision":"x","why":"x","known_pitfalls":"x","validation_evidence":"x","issue_type":"x","review_or_human_required":true,"risk_tags":"x","changeType":"x","linked_issue":"x","linked_pr":"x","timestamp":"x"}' > "${f}"
  assert_false "缺少applicable_scope应失败" _writeback_validate_fields "${f}"
}

test_validate_all_15_required_fields() {
  _load_writeback
  # 逐个移除每个必填字段测试
  local fields=("decision_title" "task_summary" "applicable_scope" "non_applicable_scope" "final_decision" "why" "known_pitfalls" "validation_evidence" "issue_type" "review_or_human_required" "risk_tags" "changeType" "linked_issue" "linked_pr" "timestamp")
  for field in "${fields[@]}"; do
    local f="${TEST_TMP}/missing_${field}.json"
    _make_complete_entry "${f}"
    # 使用 jq 删除该字段
    local modified
    modified=$(jq "del(.${field})" "${f}")
    echo "${modified}" > "${f}"
    assert_false "缺少${field}应失败" _writeback_validate_fields "${f}"
  done
}

###############################################################################
# 2. 创建知识条目
###############################################################################
test_writeback_create_new_entry() {
  _load_writeback
  local f="${TEST_TMP}/new_entry.json"
  _make_complete_entry "${f}" "Unique decision for testing"
  local result
  result=$(writeback_create "${f}" 2>/dev/null)
  [[ -f "${result}" ]] || { echo "知识条目文件未创建: ${result}" >&2; return 1; }
  # 应包含 kb_id
  local kb_id
  kb_id=$(jq -r '.kb_id' "${result}")
  assert_matches "${kb_id}" "^KB-" "kb_id应以KB-开头"
}

test_writeback_create_missing_file() {
  _load_writeback
  local result=0
  writeback_create "/nonexistent/file.json" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "不存在的文件应返回错误"
}

test_writeback_create_incomplete_entry() {
  _load_writeback
  local f="${TEST_TMP}/incomplete.json"
  echo '{"decision_title":"only title"}' > "${f}"
  local result=0
  writeback_create "${f}" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "不完整的条目应返回错误"
}

###############################################################################
# 3. 去重 merge
###############################################################################
test_writeback_merge_on_similar() {
  _load_writeback

  # 创建一个已有条目
  local existing="${KNOWLEDGE_DIR}/KB-existing.json"
  _make_complete_entry "${existing}" "Token refresh must check tenant boundary"
  jq '. + {"kb_id": "KB-existing"}' "${existing}" > "${existing}.tmp" && mv "${existing}.tmp" "${existing}"

  # 创建一个相似的新条目（标题有足够重叠关键词）
  local new_entry="${TEST_TMP}/new_similar.json"
  _make_complete_entry "${new_entry}" "Token refresh must validate tenant boundary" "Same pattern"
  # writeback_create 应检测到相似并合并
  local result
  result=$(writeback_create "${new_entry}" 2>&1)
  # 应提示合并而不是创建全新条目
  assert_contains "${result}" "合并" "应检测到相似条目并合并"
}

test_writeback_merge_appends_pitfalls() {
  _load_writeback

  local existing="${KNOWLEDGE_DIR}/KB-merge-test.json"
  cat > "${existing}" <<'EOF'
{
  "kb_id": "KB-merge-test",
  "decision_title": "Merge test entry",
  "task_summary": "Test",
  "applicable_scope": "test",
  "non_applicable_scope": "",
  "final_decision": "Use pattern X",
  "why": "reason",
  "known_pitfalls": ["pitfall-A"],
  "validation_evidence": "evidence-1",
  "issue_type": "logic_bug",
  "review_or_human_required": false,
  "risk_tags": ["test"],
  "changeType": "logic_change",
  "linked_issue": "",
  "linked_pr": "",
  "timestamp": "2026-01-01T00:00:00Z"
}
EOF

  local new_entry="${TEST_TMP}/new_pitfall.json"
  cat > "${new_entry}" <<'EOF'
{
  "decision_title": "Merge test entry",
  "task_summary": "Test",
  "applicable_scope": "test",
  "non_applicable_scope": "",
  "final_decision": "Use pattern X",
  "why": "reason",
  "known_pitfalls": ["pitfall-B"],
  "validation_evidence": "evidence-2",
  "issue_type": "logic_bug",
  "review_or_human_required": false,
  "risk_tags": ["test"],
  "changeType": "logic_change",
  "linked_issue": "",
  "linked_pr": "",
  "timestamp": "2026-03-24T00:00:00Z"
}
EOF

  writeback_merge "${existing}" "${new_entry}" >/dev/null 2>&1
  local content
  content=$(cat "${existing}")
  assert_contains "${content}" "pitfall-A" "应保留原有pitfall"
  assert_contains "${content}" "pitfall-B" "应追加新pitfall"
}

###############################################################################
# 4. superseded 标记
###############################################################################
test_writeback_supersede_on_different_decision() {
  _load_writeback

  local existing="${KNOWLEDGE_DIR}/KB-supersede-test.json"
  cat > "${existing}" <<'EOF'
{
  "kb_id": "KB-supersede-test",
  "decision_title": "Old decision",
  "task_summary": "Test",
  "applicable_scope": "test",
  "non_applicable_scope": "",
  "final_decision": "Old way",
  "why": "reason",
  "known_pitfalls": [],
  "validation_evidence": "",
  "issue_type": "logic_bug",
  "review_or_human_required": false,
  "risk_tags": [],
  "changeType": "logic_change",
  "linked_issue": "",
  "linked_pr": "",
  "timestamp": "2026-01-01T00:00:00Z"
}
EOF

  local new_entry="${TEST_TMP}/new_decision.json"
  cat > "${new_entry}" <<'EOF'
{
  "decision_title": "Updated decision",
  "task_summary": "Test",
  "applicable_scope": "test",
  "non_applicable_scope": "",
  "final_decision": "New way",
  "why": "better approach",
  "known_pitfalls": [],
  "validation_evidence": "",
  "issue_type": "logic_bug",
  "review_or_human_required": false,
  "risk_tags": [],
  "changeType": "logic_change",
  "linked_issue": "",
  "linked_pr": "",
  "timestamp": "2026-03-24T00:00:00Z"
}
EOF

  writeback_merge "${existing}" "${new_entry}" >/dev/null 2>&1
  local old_content
  old_content=$(cat "${existing}")
  assert_contains "${old_content}" "superseded_by" "旧条目应标记superseded_by"
  assert_contains "${old_content}" "superseded_at" "旧条目应包含superseded_at时间"
}

###############################################################################
# 5. 触发条件
###############################################################################
test_trigger_tier2_passed() {
  _load_writeback
  assert_true "tier2_passed应触发" writeback_should_trigger "tier2_passed"
}

test_trigger_tier3_decided() {
  _load_writeback
  assert_true "tier3_decided应触发" writeback_should_trigger "tier3_decided"
}

test_trigger_high_value_failure() {
  _load_writeback
  assert_true "high_value_failure应触发" writeback_should_trigger "high_value_failure"
}

test_trigger_validation_proven() {
  _load_writeback
  assert_true "validation_proven应触发" writeback_should_trigger "validation_proven"
}

test_trigger_false_positive() {
  _load_writeback
  assert_true "false_positive应触发" writeback_should_trigger "false_positive"
}

test_trigger_invalid() {
  _load_writeback
  assert_false "无效类型不应触发" writeback_should_trigger "invalid_type"
}

###############################################################################
# 6. build_entry 辅助函数
###############################################################################
test_build_entry_creates_file() {
  _load_writeback
  local entry_file
  entry_file=$(writeback_build_entry \
    "Test Decision" "Fix bug" "auth module" "public api" \
    "Use pattern X" "Security" "pitfall-1,pitfall-2" \
    "pytest pass" "security_risk" "true" "auth,token" \
    "logic_change" "#100" "#200")
  [[ -f "${entry_file}" ]] || { echo "entry文件未创建" >&2; return 1; }
  local content
  content=$(cat "${entry_file}")
  assert_contains "${content}" "Test Decision" "应包含decision_title"
  assert_contains "${content}" "auth module" "应包含applicable_scope"
  rm -f "${entry_file}"
}

###############################################################################
# 7. writeback_list 和 writeback_get
###############################################################################
test_writeback_list_empty() {
  _load_writeback
  local list
  list=$(writeback_list)
  assert_contains "${list}" "empty" "空知识库应显示empty"
}

test_writeback_list_with_entries() {
  _load_writeback
  local f="${TEST_TMP}/entry1.json"
  _make_complete_entry "${f}" "Entry One"
  writeback_create "${f}" >/dev/null 2>&1
  local list
  list=$(writeback_list)
  assert_contains "${list}" "Entry One" "应列出条目标题"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_memory_writeback.sh =="

run_test test_validate_complete_entry
run_test test_validate_missing_decision_title
run_test test_validate_missing_task_summary
run_test test_validate_missing_applicable_scope
run_test test_validate_all_15_required_fields
run_test test_writeback_create_new_entry
run_test test_writeback_create_missing_file
run_test test_writeback_create_incomplete_entry
run_test test_writeback_merge_on_similar
run_test test_writeback_merge_appends_pitfalls
run_test test_writeback_supersede_on_different_decision
run_test test_trigger_tier2_passed
run_test test_trigger_tier3_decided
run_test test_trigger_high_value_failure
run_test test_trigger_validation_proven
run_test test_trigger_false_positive
run_test test_trigger_invalid
run_test test_build_entry_creates_file
run_test test_writeback_list_empty
run_test test_writeback_list_with_entries

print_report "test_memory_writeback.sh"
