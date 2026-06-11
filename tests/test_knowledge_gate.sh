#!/usr/bin/env bash
###############################################################################
# test_knowledge_gate.sh — Knowledge Gate 模块测试
#
# 测试清单（对照统一实施文档第7节）：
#   - KNOWLEDGE_PRECHECK 输出格式
#   - confidence 分级（low/medium/high）
#   - action_hint 4种枚举
#   - 未命中默认行为
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/knowledge_gate.sh"

###############################################################################
# 1. knowledge_gate_required — 启用范围
###############################################################################
test_kg_required_tier1() {
  assert_false "Tier 1 不需要 Knowledge Gate" knowledge_gate_required "1"
}

test_kg_required_tier2() {
  assert_true "Tier 2 必须启用 Knowledge Gate" knowledge_gate_required "2"
}

test_kg_required_tier3() {
  assert_true "Tier 3 必须启用 Knowledge Gate" knowledge_gate_required "3"
}

test_kg_required_default() {
  assert_false "默认(无tier)不需要 Knowledge Gate" knowledge_gate_required ""
}

###############################################################################
# 2. KNOWLEDGE_PRECHECK 输出格式
###############################################################################
test_kg_run_tier1_skipped() {
  local result
  result=$(knowledge_gate_run "fix bug" "bugfix" "logic_change" "" "" "" "" "1" "${TEST_TMP}/.bashclaw/knowledge")
  assert_json_field "${result}" ".knowledge_gate" "skipped" "Tier 1应跳过Knowledge Gate"
  assert_contains "${result}" "tier_1_does_not_require" "应说明跳过原因"
}

test_kg_run_tier2_completed() {
  local result
  result=$(knowledge_gate_run "fix auth" "auth bugfix" "logic_change" "" "auth" "" "" "2" "${TEST_TMP}/.bashclaw/knowledge")
  assert_json_field "${result}" ".knowledge_gate" "completed" "Tier 2应完成Knowledge Gate"
}

test_kg_run_output_has_required_fields() {
  local result
  result=$(knowledge_gate_run "fix auth" "auth bugfix" "logic_change" "src/auth.py" "auth" "" "" "2" "${TEST_TMP}/.bashclaw/knowledge")
  assert_json_has_field "${result}" ".knowledge_gate" "应包含knowledge_gate字段"
  assert_json_has_field "${result}" ".similar_decisions" "应包含similar_decisions字段"
  assert_json_has_field "${result}" ".confidence" "应包含confidence字段"
  assert_json_has_field "${result}" ".action_hint" "应包含action_hint字段"
  assert_json_has_field "${result}" ".hit_count" "应包含hit_count字段"
}

test_kg_run_output_has_precheck_fields() {
  local result
  result=$(knowledge_gate_run "test" "test" "logic_change" "" "" "" "" "2" "${TEST_TMP}/.bashclaw/knowledge")
  # 对照文档第7.4节要求的字段
  assert_json_has_field "${result}" ".known_pitfalls" "应包含known_pitfalls"
  assert_json_has_field "${result}" ".recommended_patterns" "应包含recommended_patterns"
  assert_json_has_field "${result}" ".applicable_scope" "应包含applicable_scope"
  assert_json_has_field "${result}" ".non_applicable_scope" "应包含non_applicable_scope"
}

###############################################################################
# 3. confidence 分级（low/medium/high）
###############################################################################
test_confidence_zero_hits_is_low() {
  local conf
  conf=$(knowledge_gate_assess_confidence 0 0)
  assert_eq "low" "${conf}" "0命中应为low confidence"
}

test_confidence_one_hit_is_medium() {
  local conf
  conf=$(knowledge_gate_assess_confidence 1 3)
  assert_eq "medium" "${conf}" "1命中应为medium confidence"
}

test_confidence_two_hits_low_risk_is_high() {
  local conf
  conf=$(knowledge_gate_assess_confidence 2 1)
  assert_eq "high" "${conf}" "2命中+低风险数应为high confidence"
}

test_confidence_three_hits_is_high() {
  local conf
  conf=$(knowledge_gate_assess_confidence 3 5)
  assert_eq "high" "${conf}" "3命中应为high confidence"
}

test_confidence_values_are_valid_enum() {
  local valid_values=("low" "medium" "high")
  for hits in 0 1 2 3 5; do
    for risk in 0 1 2 3 5; do
      local conf
      conf=$(knowledge_gate_assess_confidence "${hits}" "${risk}")
      local found=false
      for v in "${valid_values[@]}"; do
        [[ "${conf}" == "${v}" ]] && found=true
      done
      assert_true "confidence应为有效枚举值 (hits=${hits}, risk=${risk}, got=${conf})" test "${found}" = "true"
    done
  done
}

###############################################################################
# 4. action_hint 4种枚举
###############################################################################
test_action_hint_proceed() {
  local hint
  hint=$(knowledge_gate_action_hint "high" "2" "0")
  assert_eq "proceed" "${hint}" "high confidence + 低风险 = proceed"
}

test_action_hint_proceed_zero_risk() {
  local hint
  hint=$(knowledge_gate_action_hint "high" "2" "1")
  assert_eq "proceed" "${hint}" "high confidence + risk<=1 = proceed"
}

test_action_hint_proceed_with_caution() {
  local hint
  hint=$(knowledge_gate_action_hint "high" "2" "3")
  assert_eq "proceed_with_caution" "${hint}" "high confidence + 多风险标签 = proceed_with_caution"
}

test_action_hint_require_review() {
  local hint
  hint=$(knowledge_gate_action_hint "medium" "2" "2")
  assert_eq "require_review" "${hint}" "medium confidence = require_review"
}

test_action_hint_require_human_if_unverifiable() {
  local hint
  hint=$(knowledge_gate_action_hint "low" "3" "3")
  assert_eq "require_human_if_unverifiable" "${hint}" "Tier 3 + low confidence = require_human_if_unverifiable"
}

test_action_hint_tier3_medium_requires_human() {
  local hint
  hint=$(knowledge_gate_action_hint "medium" "3" "2")
  assert_eq "require_human_if_unverifiable" "${hint}" "Tier 3 + medium confidence = require_human_if_unverifiable"
}

test_action_hint_low_confidence_tier2() {
  local hint
  hint=$(knowledge_gate_action_hint "low" "2" "1")
  assert_eq "require_review" "${hint}" "low confidence + Tier 2 = require_review"
}

test_action_hint_values_are_valid_enum() {
  local valid_values=("proceed" "proceed_with_caution" "require_review" "require_human_if_unverifiable")
  for conf in low medium high; do
    for tier in 1 2 3; do
      for risk in 0 1 2 3; do
        local hint
        hint=$(knowledge_gate_action_hint "${conf}" "${tier}" "${risk}")
        local found=false
        for v in "${valid_values[@]}"; do
          [[ "${hint}" == "${v}" ]] && found=true
        done
        assert_true "action_hint应为有效枚举值 (conf=${conf}, tier=${tier}, risk=${risk}, got=${hint})" test "${found}" = "true"
      done
    done
  done
}

###############################################################################
# 5. 未命中默认行为
###############################################################################
test_kg_no_hits_default_behavior() {
  # 空知识库，应正常返回空结果
  local result
  result=$(knowledge_gate_run "fix rare bug" "rare" "logic_change" "src/rare.py" "" "" "" "2" "${TEST_TMP}/.bashclaw/knowledge")
  assert_json_field "${result}" ".knowledge_gate" "completed" "应正常完成"
  assert_json_field "${result}" ".confidence" "low" "无命中应为low confidence"
  local hit_count
  hit_count=$(echo "${result}" | jq -r '.hit_count')
  assert_eq "0" "${hit_count}" "无命中时hit_count应为0"
}

test_kg_no_hits_similar_decisions_empty() {
  local result
  result=$(knowledge_gate_run "test" "test" "logic_change" "" "" "" "" "2" "${TEST_TMP}/.bashclaw/knowledge")
  local decisions
  decisions=$(echo "${result}" | jq -r '.similar_decisions')
  assert_eq "[]" "${decisions}" "无命中时similar_decisions应为空数组"
}

###############################################################################
# 6. 知识库命中场景
###############################################################################
test_kg_with_matching_knowledge() {
  # 创建一个知识条目
  cat > "${TEST_TMP}/.bashclaw/knowledge/kb001.json" <<'EOF'
{
  "decision_title": "token refresh must check tenant boundary",
  "applicable_scope": "auth session refresh",
  "final_decision": "always validate tenant_id",
  "risk_tags": ["auth", "token", "tenant"]
}
EOF
  local result
  result=$(knowledge_gate_run "fix token refresh" "token refresh bug" "logic_change" "src/auth/refresh.py" "auth,token" "" "" "2" "${TEST_TMP}/.bashclaw/knowledge")
  local hit_count
  hit_count=$(echo "${result}" | jq -r '.hit_count')
  [[ "${hit_count}" -gt 0 ]] || {
    echo "FAIL: 应命中知识条目，但hit_count=${hit_count}" >&2
    return 1
  }
}

###############################################################################
# 7. build_query 构建
###############################################################################
test_kg_build_query_combines_inputs() {
  local query
  query=$(knowledge_gate_build_query "fix login bug" "login bugfix" "logic_change" "src/login.py" "auth" "stack trace" "python")
  assert_contains "${query}" "fix login bug" "应包含user_request"
  assert_contains "${query}" "login bugfix" "应包含task_summary"
  assert_contains "${query}" "logic_change" "应包含change_type"
  assert_contains "${query}" "src/login.py" "应包含file_paths"
  assert_contains "${query}" "auth" "应包含risk_tags"
  assert_contains "${query}" "stack trace" "应包含error_stack"
  assert_contains "${query}" "python" "应包含tech_stack"
}

test_kg_build_query_empty_inputs() {
  local query
  query=$(knowledge_gate_build_query "" "" "" "" "" "" "")
  # 应返回空或仅空白
  [[ -z "$(echo "${query}" | tr -d '[:space:]')" ]] || {
    echo "所有输入为空时query应为空，但得到: '${query}'" >&2
    return 1
  }
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_knowledge_gate.sh =="

run_test test_kg_required_tier1
run_test test_kg_required_tier2
run_test test_kg_required_tier3
run_test test_kg_required_default
run_test test_kg_run_tier1_skipped
run_test test_kg_run_tier2_completed
run_test test_kg_run_output_has_required_fields
run_test test_kg_run_output_has_precheck_fields
run_test test_confidence_zero_hits_is_low
run_test test_confidence_one_hit_is_medium
run_test test_confidence_two_hits_low_risk_is_high
run_test test_confidence_three_hits_is_high
run_test test_confidence_values_are_valid_enum
run_test test_action_hint_proceed
run_test test_action_hint_proceed_zero_risk
run_test test_action_hint_proceed_with_caution
run_test test_action_hint_require_review
run_test test_action_hint_require_human_if_unverifiable
run_test test_action_hint_tier3_medium_requires_human
run_test test_action_hint_low_confidence_tier2
run_test test_action_hint_values_are_valid_enum
run_test test_kg_no_hits_default_behavior
run_test test_kg_no_hits_similar_decisions_empty
run_test test_kg_with_matching_knowledge
run_test test_kg_build_query_combines_inputs
run_test test_kg_build_query_empty_inputs

print_report "test_knowledge_gate.sh"
