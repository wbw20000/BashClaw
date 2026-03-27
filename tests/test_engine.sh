#!/usr/bin/env bash
###############################################################################
# test_engine.sh — Engine (Tier 1) 模块测试
#
# 测试清单（对照统一实施文档第5-6节）：
#   - engine_log 日志工具
#   - engine_run 完整流程（需要所有模块依赖）
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_engine() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  export BASHCLAW_LOG_LEVEL="error"
  mkdir -p "${AUDIT_LOG_DIR}"
  # Source all dependencies
  source "${LIB_DIR}/routing.sh"
  source "${LIB_DIR}/risk_classifier.sh"
  source "${LIB_DIR}/knowledge_gate.sh"
  source "${LIB_DIR}/executor.sh"
  source "${LIB_DIR}/validator_repo.sh"
  source "${LIB_DIR}/audit_log.sh"
  source "${LIB_DIR}/engine.sh"
}

###############################################################################
# 1. engine_log — 日志工具
###############################################################################
test_engine_log_info_visible_at_info_level() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="info"
  local output
  output=$(engine_log "info" "test message" 2>&1)
  assert_contains "${output}" "test message" "info级别日志应可见"
}

test_engine_log_debug_hidden_at_info_level() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="info"
  local output
  output=$(engine_log "debug" "debug message" 2>&1)
  [[ -z "${output}" ]] || {
    echo "debug级别日志在info模式下不应可见" >&2
    return 1
  }
}

test_engine_log_error_always_visible() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_log "error" "error message" 2>&1)
  assert_contains "${output}" "error message" "error级别日志应始终可见"
}

test_engine_log_format() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="info"
  local output
  output=$(engine_log "info" "pipeline start" 2>&1)
  assert_contains "${output}" "[bashclaw:info]" "日志应包含标准前缀"
}

###############################################################################
# 2. engine_run — 空输入验证
###############################################################################
test_engine_run_empty_input_fails() {
  _load_engine
  local result=0
  engine_run "" 2>/dev/null || result=$?
  assert_eq "1" "${result}" "空输入应返回错误"
}

###############################################################################
# 3. engine_run — 基本流程 (Tier 1)
###############################################################################
test_engine_run_basic_tier1() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "fix a typo in readme" 2>/dev/null)
  echo "${output}" | jq . > /dev/null 2>&1 || {
    echo "engine_run输出应是有效JSON" >&2
    echo "实际输出: ${output}" >&2
    return 1
  }
}

test_engine_run_has_task_id() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "fix a bug" 2>/dev/null)
  assert_json_has_field "${output}" ".task_id" "应包含task_id"
}

test_engine_run_has_tier_fields() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "fix a bug" 2>/dev/null)
  assert_json_has_field "${output}" ".tier_requested" "应包含tier_requested"
  assert_json_has_field "${output}" ".tier_effective" "应包含tier_effective"
}

test_engine_run_has_final_status() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "fix a bug" 2>/dev/null)
  assert_json_has_field "${output}" ".final_status" "应包含final_status"
}

test_engine_run_has_validation() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "fix a bug" 2>/dev/null)
  assert_json_has_field "${output}" ".validation.status" "应包含validation.status"
}

test_engine_run_has_audit_log() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "fix a bug" 2>/dev/null)
  assert_json_has_field "${output}" ".audit_log" "应包含audit_log字段"
}

###############################################################################
# 4. engine_run — /review 前缀升级
###############################################################################
test_engine_run_review_prefix() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "/review fix auth module" 2>/dev/null)
  assert_json_field "${output}" ".tier_requested" "reviewed" "/review应设置tier_requested为reviewed"
}

###############################################################################
# 5. engine_run — /critical 前缀升级
###############################################################################
test_engine_run_critical_prefix() {
  _load_engine
  export BASHCLAW_LOG_LEVEL="error"
  local output
  output=$(engine_run "/critical deploy to prod" 2>/dev/null)
  assert_json_field "${output}" ".tier_requested" "critical" "/critical应设置tier_requested为critical"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_engine.sh =="

run_test test_engine_log_info_visible_at_info_level
run_test test_engine_log_debug_hidden_at_info_level
run_test test_engine_log_error_always_visible
run_test test_engine_log_format
run_test test_engine_run_empty_input_fails
run_test test_engine_run_basic_tier1
run_test test_engine_run_has_task_id
run_test test_engine_run_has_tier_fields
run_test test_engine_run_has_final_status
run_test test_engine_run_has_validation
run_test test_engine_run_has_audit_log
run_test test_engine_run_review_prefix
run_test test_engine_run_critical_prefix

print_report "test_engine.sh"
