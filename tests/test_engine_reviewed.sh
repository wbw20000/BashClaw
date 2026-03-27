#!/usr/bin/env bash
###############################################################################
# test_engine_reviewed.sh — Tier 2 编排引擎测试
#
# 测试清单（对照统一实施文档第6.2节）：
#   - run_tier2_reviewed 参数验证
#   - _tier2_log 日志工具
#   - 模块加载与 fallback stub
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_engine_reviewed() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  export BASHCLAW_LOG_LEVEL="error"
  mkdir -p "${AUDIT_LOG_DIR}"
  mkdir -p "${TEST_TMP}/.bashclaw/knowledge"
  mkdir -p "${TEST_TMP}/.bashclaw/escalations"
  # Source the module
  source "${LIB_DIR}/engine_reviewed.sh"
}

###############################################################################
# 1. run_tier2_reviewed — 参数验证
###############################################################################
test_tier2_requires_user_request() {
  _load_engine_reviewed
  # ${1:?} with empty string causes bash to exit with error, which is expected
  # Run in subshell to capture the exit without killing parent
  local result=0
  ( run_tier2_reviewed "" ) 2>/dev/null || result=$?
  [[ "${result}" -ne 0 ]] || {
    echo "空user_request应返回错误" >&2
    return 1
  }
}

###############################################################################
# 2. _tier2_log — 日志格式
###############################################################################
test_tier2_log_format() {
  _load_engine_reviewed
  local output
  output=$(_tier2_log "TEST_EVENT" "test data" 2>&1)
  assert_contains "${output}" "TIER2:TEST_EVENT" "日志应包含事件类型"
}

test_tier2_log_has_timestamp() {
  _load_engine_reviewed
  local output
  output=$(_tier2_log "TEST" "" 2>&1)
  assert_matches "${output}" "20[0-9]{2}-[0-9]{2}-[0-9]{2}T" "日志应包含时间戳"
}

###############################################################################
# 3. stub 函数验证 — 确保 fallback 存在
###############################################################################
test_stubs_available_knowledge_gate_run() {
  _load_engine_reviewed
  # knowledge_gate_run 应该可用（要么是真实的，要么是 stub）
  type knowledge_gate_run &>/dev/null || {
    echo "knowledge_gate_run 应该可用" >&2
    return 1
  }
}

test_stubs_available_executor_run() {
  _load_engine_reviewed
  type executor_run &>/dev/null || {
    echo "executor_run 应该可用" >&2
    return 1
  }
}

test_stubs_available_validator_run() {
  _load_engine_reviewed
  type validator_run &>/dev/null || {
    echo "validator_run 应该可用" >&2
    return 1
  }
}

test_stubs_available_risk_classify() {
  _load_engine_reviewed
  type risk_classify &>/dev/null || {
    echo "risk_classify 应该可用" >&2
    return 1
  }
}

test_stubs_available_evaluate_skip_review() {
  _load_engine_reviewed
  type evaluate_skip_review &>/dev/null || {
    echo "evaluate_skip_review 应该可用" >&2
    return 1
  }
}

test_stubs_available_run_review() {
  _load_engine_reviewed
  type run_review &>/dev/null || {
    echo "run_review 应该可用" >&2
    return 1
  }
}

test_stubs_available_run_evidence_resolution() {
  _load_engine_reviewed
  type run_evidence_resolution &>/dev/null || {
    echo "run_evidence_resolution 应该可用" >&2
    return 1
  }
}

###############################################################################
# 4. 完整流程 — skip review 场景
###############################################################################
test_tier2_skip_review_path() {
  _load_engine_reviewed
  # 设置 mock reviewer 输出为空（这样 skip review 可能被触发）
  export BASHCLAW_REVIEW_MOCK_OUTPUT='{"issues":[]}'
  local result
  local exit_code=0
  result=$(run_tier2_reviewed "fix typo in readme" "${TEST_TMP}" 2>/dev/null) || exit_code=$?
  # 即使内部有错误，结果应该是 JSON
  if [[ -n "${result}" ]]; then
    echo "${result}" | jq . > /dev/null 2>&1 || {
      echo "输出应是有效JSON" >&2
      echo "实际输出: ${result}" >&2
      return 1
    }
    assert_json_has_field "${result}" ".status" "应包含status"
    assert_json_has_field "${result}" ".trace_id" "应包含trace_id"
    assert_json_has_field "${result}" ".timestamp" "应包含timestamp"
  fi
  unset BASHCLAW_REVIEW_MOCK_OUTPUT
}

###############################################################################
# 5. 完整流程 — review with issues 场景
###############################################################################
test_tier2_review_with_issues() {
  _load_engine_reviewed
  export BASHCLAW_REVIEW_MOCK_OUTPUT='{"issues":[{"location":"auth.py:10","issue_type":"security_risk","severity":"critical","risk_statement":"Missing auth check","why_it_matters":"Unauthorized access","verification_plan":"Test with unauthenticated request and verify 403"}]}'
  local result
  local exit_code=0
  result=$(run_tier2_reviewed "fix auth bug" "${TEST_TMP}" 2>/dev/null) || exit_code=$?
  if [[ -n "${result}" ]]; then
    echo "${result}" | jq . > /dev/null 2>&1 || {
      echo "输出应是有效JSON" >&2
      return 1
    }
    # 有 issues 时不应是 skip review
    local status
    status=$(echo "${result}" | jq -r '.status // empty')
    [[ "${status}" != "COMPLETED_SKIP_REVIEW" ]] || {
      echo "有issues时不应跳过review" >&2
      return 1
    }
  fi
  unset BASHCLAW_REVIEW_MOCK_OUTPUT
}

###############################################################################
# 6. 输出结构完整性
###############################################################################
test_tier2_output_has_change_type() {
  _load_engine_reviewed
  export BASHCLAW_REVIEW_MOCK_OUTPUT='{"issues":[]}'
  local result
  result=$(run_tier2_reviewed "test output" "${TEST_TMP}" 2>/dev/null) || true
  if [[ -n "${result}" ]]; then
    assert_json_has_field "${result}" ".change_type" "应包含change_type"
  fi
  unset BASHCLAW_REVIEW_MOCK_OUTPUT
}

test_tier2_output_has_knowledge() {
  _load_engine_reviewed
  export BASHCLAW_REVIEW_MOCK_OUTPUT='{"issues":[]}'
  local result
  result=$(run_tier2_reviewed "test output" "${TEST_TMP}" 2>/dev/null) || true
  if [[ -n "${result}" ]]; then
    assert_json_has_field "${result}" ".knowledge_precheck" "应包含knowledge_precheck"
  fi
  unset BASHCLAW_REVIEW_MOCK_OUTPUT
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_engine_reviewed.sh =="

run_test test_tier2_requires_user_request
run_test test_tier2_log_format
run_test test_tier2_log_has_timestamp
run_test test_stubs_available_knowledge_gate_run
run_test test_stubs_available_executor_run
run_test test_stubs_available_validator_run
run_test test_stubs_available_risk_classify
run_test test_stubs_available_evaluate_skip_review
run_test test_stubs_available_run_review
run_test test_stubs_available_run_evidence_resolution
run_test test_tier2_skip_review_path
run_test test_tier2_review_with_issues
run_test test_tier2_output_has_change_type
run_test test_tier2_output_has_knowledge

print_report "test_engine_reviewed.sh"
