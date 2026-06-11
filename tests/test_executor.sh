#!/usr/bin/env bash
###############################################################################
# test_executor.sh — Executor 模块测试
#
# 测试清单（对照统一实施文档第8节）：
#   - executor_select_engine 引擎选择逻辑
#   - executor_build_context 上下文构建
#   - executor_format_output 输出结构
#   - executor_run 完整管道
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/executor.sh"

###############################################################################
# 1. executor_select_engine — 引擎选择
###############################################################################
test_select_engine_override() {
  export BASHCLAW_ENGINE_OVERRIDE="codex"
  local engine
  engine=$(executor_select_engine "3" "high")
  assert_eq "codex" "${engine}" "OVERRIDE应优先于所有逻辑"
  unset BASHCLAW_ENGINE_OVERRIDE
}

test_select_engine_high_complexity_opus() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "1" "high")
  assert_eq "opus4.6" "${engine}" "高复杂度应选择opus4.6"
}

test_select_engine_complex_opus() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "1" "complex")
  assert_eq "opus4.6" "${engine}" "complex应选择opus4.6"
}

test_select_engine_low_complexity_codex() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "1" "low")
  assert_eq "codex" "${engine}" "低复杂度应选择codex"
}

test_select_engine_simple_codex() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "1" "simple")
  assert_eq "codex" "${engine}" "simple应选择codex"
}

test_select_engine_patch_codex() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "1" "patch")
  assert_eq "codex" "${engine}" "patch应选择codex"
}

test_select_engine_tier3_default_opus() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "3" "medium")
  assert_eq "opus4.6" "${engine}" "Tier 3默认应选择opus4.6"
}

test_select_engine_tier1_default_codex() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "1" "medium")
  assert_eq "codex" "${engine}" "Tier 1默认应选择codex"
}

test_select_engine_tier2_default_codex() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local engine
  engine=$(executor_select_engine "2" "medium")
  assert_eq "codex" "${engine}" "Tier 2默认应选择codex"
}

###############################################################################
# 2. executor_build_context — 上下文构建
###############################################################################
test_build_context_contains_task() {
  local ctx
  ctx=$(executor_build_context "Fix login bug" "" "logic_change" "auth")
  assert_contains "${ctx}" "Fix login bug" "应包含任务描述"
}

test_build_context_contains_change_type() {
  local ctx
  ctx=$(executor_build_context "" "" "schema_change" "")
  assert_contains "${ctx}" "schema_change" "应包含change_type"
}

test_build_context_contains_risk_tags() {
  local ctx
  ctx=$(executor_build_context "" "" "" "auth,token,jwt")
  assert_contains "${ctx}" "auth,token,jwt" "应包含risk_tags"
}

test_build_context_contains_knowledge() {
  local ctx
  ctx=$(executor_build_context "" "KB-101: always validate tenant" "" "")
  assert_contains "${ctx}" "KB-101" "应包含知识摘要"
}

test_build_context_truncates_long_task() {
  # 任务描述超过500字符应被截断
  local long_task
  long_task=$(printf 'x%.0s' {1..600})
  local ctx
  ctx=$(executor_build_context "${long_task}" "" "" "")
  local task_part
  task_part=$(echo "${ctx}" | grep "task:" | head -1)
  [[ ${#task_part} -le 520 ]] || {
    echo "任务描述应被截断到500字符以内" >&2
    return 1
  }
}

###############################################################################
# 3. executor_format_output — 输出格式
###############################################################################
test_format_output_valid_json() {
  local output
  output=$(executor_format_output "summary text" "file1.py,file2.py" "reason text" "KB-1" "run pytest" "auth risk")
  echo "${output}" | jq . > /dev/null 2>&1 || {
    echo "输出应是有效JSON" >&2
    return 1
  }
}

test_format_output_has_required_fields() {
  local output
  output=$(executor_format_output "summary" "files" "reason" "refs" "plan" "risks")
  assert_json_has_field "${output}" ".executor_output.summary.description" "应包含description"
  assert_json_has_field "${output}" ".executor_output.summary.changed_files" "应包含changed_files"
  assert_json_has_field "${output}" ".executor_output.summary.reason" "应包含reason"
  assert_json_has_field "${output}" ".executor_output.summary.knowledge_refs" "应包含knowledge_refs"
  assert_json_has_field "${output}" ".executor_output.validation_plan" "应包含validation_plan"
  assert_json_has_field "${output}" ".executor_output.open_risks" "应包含open_risks"
}

###############################################################################
# 4. executor_run — 完整管道
###############################################################################
test_executor_run_output_json_valid() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local output
  output=$(executor_run "fix a bug" "1" "" "logic_change" "" "low" 2>/dev/null)
  echo "${output}" | jq . > /dev/null 2>&1 || {
    echo "executor_run 输出应是有效JSON" >&2
    return 1
  }
}

test_executor_run_has_engine_field() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local output
  output=$(executor_run "fix a bug" "1" "" "logic_change" "" "low" 2>/dev/null)
  assert_json_has_field "${output}" ".executor.engine" "应包含engine字段"
}

test_executor_run_has_tier_field() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local output
  output=$(executor_run "fix a bug" "2" "" "logic_change" "" "low" 2>/dev/null)
  assert_json_field "${output}" ".executor.tier" "2" "tier应为2"
}

test_executor_run_has_status() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local output
  output=$(executor_run "fix a bug" "1" "" "" "" "low" 2>/dev/null)
  assert_json_field "${output}" ".executor.status" "ready" "status应为ready"
}

test_executor_run_has_output_summary() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local output
  output=$(executor_run "fix login bug" "1" "" "" "" "low" 2>/dev/null)
  assert_json_has_field "${output}" ".executor.output.summary" "应包含output.summary"
  assert_contains "${output}" "fix login bug" "summary应包含任务描述"
}

test_executor_run_has_validation_plan() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local output
  output=$(executor_run "fix" "1" "" "logic_change" "" "low" 2>/dev/null)
  assert_json_has_field "${output}" ".executor.output.validation_plan" "应包含validation_plan"
  assert_contains "${output}" "logic_change" "validation_plan应引用change_type"
}

test_executor_run_engine_matches_selection() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local output
  output=$(executor_run "analysis" "3" "" "" "" "high" 2>/dev/null)
  assert_json_field "${output}" ".executor.engine" "opus4.6" "高复杂度Tier3应选择opus4.6"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_executor.sh =="

run_test test_select_engine_override
run_test test_select_engine_high_complexity_opus
run_test test_select_engine_complex_opus
run_test test_select_engine_low_complexity_codex
run_test test_select_engine_simple_codex
run_test test_select_engine_patch_codex
run_test test_select_engine_tier3_default_opus
run_test test_select_engine_tier1_default_codex
run_test test_select_engine_tier2_default_codex
run_test test_build_context_contains_task
run_test test_build_context_contains_change_type
run_test test_build_context_contains_risk_tags
run_test test_build_context_contains_knowledge
run_test test_build_context_truncates_long_task
run_test test_format_output_valid_json
run_test test_format_output_has_required_fields
run_test test_executor_run_output_json_valid
run_test test_executor_run_has_engine_field
run_test test_executor_run_has_tier_field
run_test test_executor_run_has_status
run_test test_executor_run_has_output_summary
run_test test_executor_run_has_validation_plan
run_test test_executor_run_engine_matches_selection

print_report "test_executor.sh"
