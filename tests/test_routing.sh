#!/usr/bin/env bash
###############################################################################
# test_routing.sh — Routing 模块测试
#
# 测试清单（对照统一实施文档第6节）：
#   - /review前缀解析
#   - /critical前缀解析
#   - BASHCLAW_ENGINE_OVERRIDE作用域
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/routing.sh"

###############################################################################
# 1. /review 前缀解析
###############################################################################
test_review_prefix_tier() {
  routing_parse_prefix "/review fix login bug"
  assert_eq "2" "${ROUTING_TIER}" "/review应设置Tier 2"
}

test_review_prefix_command() {
  routing_parse_prefix "/review fix login bug"
  assert_eq "fix login bug" "${ROUTING_COMMAND}" "应提取命令部分"
}

test_review_prefix_tier_name() {
  routing_parse_prefix "/review fix"
  assert_eq "reviewed" "${ROUTING_TIER_NAME}" "tier name应为reviewed"
}

test_review_prefix_alone() {
  routing_parse_prefix "/review"
  assert_eq "2" "${ROUTING_TIER}" "/review单独也应设置Tier 2"
  assert_eq "" "${ROUTING_COMMAND}" "无命令时应为空"
}

###############################################################################
# 2. /critical 前缀解析
###############################################################################
test_critical_prefix_tier() {
  routing_parse_prefix "/critical deploy to production"
  assert_eq "3" "${ROUTING_TIER}" "/critical应设置Tier 3"
}

test_critical_prefix_command() {
  routing_parse_prefix "/critical deploy to production"
  assert_eq "deploy to production" "${ROUTING_COMMAND}" "应提取命令部分"
}

test_critical_prefix_tier_name() {
  routing_parse_prefix "/critical"
  assert_eq "critical" "${ROUTING_TIER_NAME}" "tier name应为critical"
}

###############################################################################
# 3. 默认（无前缀）
###############################################################################
test_default_no_prefix() {
  routing_parse_prefix "fix a small bug"
  assert_eq "1" "${ROUTING_TIER}" "无前缀应默认Tier 1"
  assert_eq "default" "${ROUTING_TIER_NAME}" "tier name应为default"
  assert_eq "fix a small bug" "${ROUTING_COMMAND}" "命令应原封不动"
}

test_default_with_leading_spaces() {
  routing_parse_prefix "  fix a bug"
  assert_eq "1" "${ROUTING_TIER}" "前导空格不应影响默认tier"
}

###############################################################################
# 4. BASHCLAW_ENGINE_OVERRIDE 作用域
###############################################################################
test_engine_override_valid_opus() {
  export BASHCLAW_ENGINE_OVERRIDE="opus4.6"
  local engine
  engine=$(routing_get_engine_override)
  assert_eq "opus4.6" "${engine}" "应返回opus4.6"
  # 注意：子shell中的unset不影响父shell，这是bash的正常行为
  # 在实际routing_resolve中会直接调用（非子shell），unset生效
  unset BASHCLAW_ENGINE_OVERRIDE
}

test_engine_override_valid_codex() {
  export BASHCLAW_ENGINE_OVERRIDE="codex"
  local engine
  engine=$(routing_get_engine_override)
  assert_eq "codex" "${engine}" "应返回codex"
}

test_engine_override_invalid() {
  export BASHCLAW_ENGINE_OVERRIDE="invalid_engine"
  local result=0
  routing_get_engine_override 2>/dev/null || result=$?
  assert_eq "1" "${result}" "无效engine应返回错误"
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
}

test_engine_override_none() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  local result=0
  routing_get_engine_override 2>/dev/null || result=$?
  assert_eq "1" "${result}" "无override时应返回1"
}

test_engine_override_single_use() {
  export BASHCLAW_ENGINE_OVERRIDE="opus4.6"
  routing_get_engine_override >/dev/null 2>&1
  # 第二次调用应失败（已清除）
  local result=0
  routing_get_engine_override 2>/dev/null || result=$?
  assert_eq "1" "${result}" "override应为单次使用"
}

###############################################################################
# 5. BASHCLAW_TIER_OVERRIDE 作用域
###############################################################################
test_tier_override_valid() {
  export BASHCLAW_TIER_OVERRIDE="3"
  local tier
  tier=$(routing_get_tier_override)
  assert_eq "3" "${tier}" "应返回3"
}

test_tier_override_invalid() {
  export BASHCLAW_TIER_OVERRIDE="5"
  local result=0
  routing_get_tier_override 2>/dev/null || result=$?
  assert_eq "1" "${result}" "无效tier应返回错误"
  unset BASHCLAW_TIER_OVERRIDE 2>/dev/null || true
}

###############################################################################
# 6. tier 解析（只升不降）
###############################################################################
test_resolve_tier_upgrade() {
  local tier
  tier=$(routing_resolve_tier "1" "3")
  assert_eq "3" "${tier}" "risk_tier=3应升级到3"
}

test_resolve_tier_no_downgrade() {
  local tier
  tier=$(routing_resolve_tier "3" "1")
  assert_eq "3" "${tier}" "prefix_tier=3不应被降级"
}

test_resolve_tier_equal() {
  local tier
  tier=$(routing_resolve_tier "2" "2")
  assert_eq "2" "${tier}" "相同tier应保持"
}

###############################################################################
# 7. routing_tier_name
###############################################################################
test_tier_name_mapping() {
  assert_eq "default" "$(routing_tier_name "1")" "1=default"
  assert_eq "reviewed" "$(routing_tier_name "2")" "2=reviewed"
  assert_eq "critical" "$(routing_tier_name "3")" "3=critical"
  assert_eq "unknown" "$(routing_tier_name "4")" "4=unknown"
}

###############################################################################
# 8. routing_resolve 完整流程
###############################################################################
test_routing_resolve_review_prefix() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  unset BASHCLAW_TIER_OVERRIDE 2>/dev/null || true
  local result
  result=$(routing_resolve "/review fix auth" "1")
  assert_json_field "${result}" ".routing.prefix_tier" "2" "prefix应为2"
  assert_json_field "${result}" ".routing.effective_tier" "2" "effective应为2"
  assert_json_field "${result}" ".routing.tier_name" "reviewed" "应为reviewed"
}

test_routing_resolve_risk_upgrade() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  unset BASHCLAW_TIER_OVERRIDE 2>/dev/null || true
  local result
  result=$(routing_resolve "fix auth" "3")
  assert_json_field "${result}" ".routing.prefix_tier" "1" "prefix应为1（无前缀）"
  assert_json_field "${result}" ".routing.effective_tier" "3" "应被risk升级到3"
}

test_routing_resolve_output_structure() {
  unset BASHCLAW_ENGINE_OVERRIDE 2>/dev/null || true
  unset BASHCLAW_TIER_OVERRIDE 2>/dev/null || true
  local result
  result=$(routing_resolve "test" "1")
  assert_json_has_field "${result}" ".routing.command" "应包含command"
  assert_json_has_field "${result}" ".routing.prefix_tier" "应包含prefix_tier"
  assert_json_has_field "${result}" ".routing.risk_tier" "应包含risk_tier"
  assert_json_has_field "${result}" ".routing.effective_tier" "应包含effective_tier"
  assert_json_has_field "${result}" ".routing.tier_name" "应包含tier_name"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_routing.sh =="

run_test test_review_prefix_tier
run_test test_review_prefix_command
run_test test_review_prefix_tier_name
run_test test_review_prefix_alone
run_test test_critical_prefix_tier
run_test test_critical_prefix_command
run_test test_critical_prefix_tier_name
run_test test_default_no_prefix
run_test test_default_with_leading_spaces
run_test test_engine_override_valid_opus
run_test test_engine_override_valid_codex
run_test test_engine_override_invalid
run_test test_engine_override_none
run_test test_engine_override_single_use
run_test test_tier_override_valid
run_test test_tier_override_invalid
run_test test_resolve_tier_upgrade
run_test test_resolve_tier_no_downgrade
run_test test_resolve_tier_equal
run_test test_tier_name_mapping
run_test test_routing_resolve_review_prefix
run_test test_routing_resolve_risk_upgrade
run_test test_routing_resolve_output_structure

print_report "test_routing.sh"
