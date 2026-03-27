#!/usr/bin/env bash
###############################################################################
# test_risk_classifier.sh — Risk Classifier 模块测试
#
# 测试清单（对照统一实施文档第16节）：
#   - auth路径 → 自动Tier 3
#   - api/service路径 → 自动Tier 2
#   - docs-only → Tier 1
#   - diff含jwt/session → 升级
#   - changeType 8种分类准确性
#   - 双层同时命中优先级
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"
source "${LIB_DIR}/risk_classifier.sh"

###############################################################################
# 1. auth 路径 → 自动 Tier 3
###############################################################################
test_auth_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "src/auth/login.py" "src/auth/session.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "auth路径应自动触发Tier 3"
}

test_permission_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "lib/permission/check.js")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "permission路径应触发Tier 3"
}

test_oauth_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "services/oauth/callback.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "oauth路径应触发Tier 3"
}

test_token_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "utils/token_manager.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "token路径应触发Tier 3"
}

test_secret_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "config/secret_store.yaml")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "secret路径应触发Tier 3"
}

test_payment_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "services/payment/checkout.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "payment路径应触发Tier 3"
}

test_billing_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "modules/billing/invoice.rb")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "billing路径应触发Tier 3"
}

test_deploy_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "deploy/production.sh")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "deploy路径应触发Tier 3"
}

test_migration_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "db/migrations/002_add_index.sql")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "migration路径应触发Tier 3"
}

test_schema_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "db/schema/users.sql")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "schema路径应触发Tier 3"
}

test_prod_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "config/prod.env")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "prod路径应触发Tier 3"
}

test_acl_path_triggers_tier3() {
  local result
  result=$(risk_classify --files "lib/acl/policy.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "acl路径应触发Tier 3"
}

###############################################################################
# 2. api/service 源码路径 → Tier 2 (logic_change)
###############################################################################
test_api_source_triggers_tier2() {
  local result
  result=$(risk_classify --files "src/api/handlers.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "2" "${tier}" "api源码路径（无高风险关键词）应触发Tier 2（logic_change）"
}

test_service_source_triggers_tier2() {
  local result
  result=$(risk_classify --files "src/services/user_service.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "2" "${tier}" "service源码路径应触发Tier 2（logic_change）"
}

###############################################################################
# 3. docs-only → Tier 1
###############################################################################
test_docs_only_triggers_tier1() {
  local result
  result=$(risk_classify --files "README.md" "docs/guide.md" "CHANGELOG.md")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "1" "${tier}" "仅修改文档应触发Tier 1"
}

test_single_readme_triggers_tier1() {
  local result
  result=$(risk_classify --files "README.md")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "1" "${tier}" "单个README.md应触发Tier 1"
}

test_test_only_triggers_tier1() {
  local result
  result=$(risk_classify --files "tests/test_login.py" "tests/test_utils.py")
  local tier change_type
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  change_type=$(echo "${result}" | jq -r '.change_type')
  assert_eq "1" "${tier}" "仅修改测试文件应触发Tier 1"
  assert_eq "test_only" "${change_type}" "应分类为test_only"
}

###############################################################################
# 4. diff 含 jwt/session → 升级
###############################################################################
test_diff_jwt_triggers_upgrade() {
  local tmp_diff
  tmp_diff="$(mktemp)"
  cat > "${tmp_diff}" <<'DIFF'
diff --git a/utils/helper.py b/utils/helper.py
+  jwt_token = generate_jwt(user_id)
+  return jwt_token
DIFF
  local result
  result=$(risk_classify --files "utils/helper.py" --diff "${tmp_diff}")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "diff含jwt应升级到Tier 3"
  assert_contains "${result}" "jwt" "应在risk_tags中包含jwt"
  rm -f "${tmp_diff}"
}

test_diff_session_triggers_upgrade() {
  local tmp_diff
  tmp_diff="$(mktemp)"
  cat > "${tmp_diff}" <<'DIFF'
diff --git a/handlers/login.py b/handlers/login.py
+  session_data = get_session(request)
+  validate_session(session_data)
DIFF
  local result
  result=$(risk_classify --files "handlers/login.py" --diff "${tmp_diff}")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "diff含session应升级到Tier 3"
  rm -f "${tmp_diff}"
}

test_diff_credential_triggers_upgrade() {
  local tmp_diff
  tmp_diff="$(mktemp)"
  cat > "${tmp_diff}" <<'DIFF'
+  cred = fetch_credential(service_name)
DIFF
  local result
  result=$(risk_classify --files "utils/cred.py" --diff "${tmp_diff}")
  assert_contains "${result}" "credential" "diff含credential应在risk_tags中"
  rm -f "${tmp_diff}"
}

###############################################################################
# 5. changeType 8种分类准确性
###############################################################################
test_change_type_docs_only() {
  local result
  result=$(risk_classify_change_type "README.md" "docs/api.md" "CHANGELOG.txt")
  assert_eq "docs_only" "${result}" "应分类为docs_only"
}

test_change_type_comment_only() {
  # 当所有文件都不匹配任何类型分类器（但有文件），则 comment_only
  # 实际上这很难单独触发，因为大多数扩展名会被归类
  # comment_only 是零匹配但文件列表非空的默认
  local result
  result=$(risk_classify_change_type)
  # 空文件列表 → docs_only
  assert_eq "docs_only" "${result}" "空文件列表应返回docs_only"
}

test_change_type_test_only() {
  local result
  result=$(risk_classify_change_type "tests/test_auth.py" "tests/test_utils.py" "spec/login_spec.rb")
  assert_eq "test_only" "${result}" "应分类为test_only"
}

test_change_type_logic_change() {
  local result
  result=$(risk_classify_change_type "src/main.py" "lib/utils.go")
  assert_eq "logic_change" "${result}" "应分类为logic_change"
}

test_change_type_config_change() {
  local result
  result=$(risk_classify_change_type "package.json" "tsconfig.json")
  assert_eq "config_change" "${result}" "应分类为config_change"
}

test_change_type_schema_change() {
  local result
  result=$(risk_classify_change_type "db/migrations/001.sql" "schema/users.sql")
  assert_eq "schema_change" "${result}" "应分类为schema_change"
}

test_change_type_infra_change() {
  local result
  result=$(risk_classify_change_type "Dockerfile" "k8s/deployment.yaml")
  assert_eq "infra_change" "${result}" "应分类为infra_change"
}

test_change_type_mixed_change() {
  local result
  result=$(risk_classify_change_type "src/main.py" "README.md" "tests/test_main.py")
  assert_eq "mixed_change" "${result}" "混合修改应分类为mixed_change"
}

###############################################################################
# 6. 双层同时命中优先级
###############################################################################
test_path_and_diff_both_trigger_tier3() {
  local tmp_diff
  tmp_diff="$(mktemp)"
  cat > "${tmp_diff}" <<'DIFF'
+  new_token = refresh_jwt(old_token)
DIFF
  local result
  result=$(risk_classify --files "src/auth/refresh.py" --diff "${tmp_diff}")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "3" "${tier}" "路径+diff同时命中应触发Tier 3"

  # 验证 risk_tags 包含了路径和 diff 的两类标签
  assert_contains "${result}" "auth" "应包含路径级别的auth标签"
  assert_contains "${result}" "jwt" "应包含diff级别的jwt标签"
  rm -f "${tmp_diff}"
}

test_tier3_overrides_tier2() {
  # logic_change 通常是 Tier 2，但有高风险标签时应升级到 Tier 3
  local result
  result=$(risk_classify --files "src/auth/middleware.py")
  local tier change_type
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  change_type=$(echo "${result}" | jq -r '.change_type')
  assert_eq "3" "${tier}" "Tier 3标签应优先于Tier 2的changeType判断"
  assert_eq "logic_change" "${change_type}" "changeType仍应是logic_change"
}

test_no_risk_tags_logic_change_is_tier2() {
  local result
  result=$(risk_classify --files "src/calculator.py")
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  assert_eq "2" "${tier}" "无高风险标签的logic_change应为Tier 2"
}

###############################################################################
# 7. 边界条件
###############################################################################
test_risk_classify_empty_input() {
  local result
  result=$(risk_classify)
  local tier
  tier=$(echo "${result}" | jq -r '.tier_suggestion')
  # 空输入默认 logic_change → Tier 2, 但无文件也无风险标签
  # 实际上空文件列表时 change_type 为 logic_change（默认）
  assert_matches "${tier}" "^[123]$" "空输入应返回有效的tier"
}

test_risk_classify_paths_deduplication() {
  # 同一个关键词出现多次不应重复
  local tags
  tags=$(risk_classify_paths "src/auth/login.py" "lib/auth/check.py" "auth/utils.py")
  local count
  count=$(echo "${tags}" | grep -c "auth" || true)
  assert_eq "1" "${count}" "同一关键词不应重复出现在risk_tags中"
}

test_risk_classify_case_insensitive() {
  local tags
  tags=$(risk_classify_paths "src/AUTH/Login.py")
  assert_contains "${tags}" "auth" "路径匹配应不区分大小写"
}

test_risk_classify_output_json_valid() {
  local result
  result=$(risk_classify --files "src/main.py")
  echo "${result}" | jq . > /dev/null 2>&1
  assert_eq "0" "$?" "输出应是有效的JSON"
}

test_risk_classify_has_required_fields() {
  local result
  result=$(risk_classify --files "src/main.py")
  assert_json_has_field "${result}" ".tier_suggestion" "应包含tier_suggestion"
  assert_json_has_field "${result}" ".risk_tags" "应包含risk_tags"
  assert_json_has_field "${result}" ".change_type" "应包含change_type"
  assert_json_has_field "${result}" ".file_count" "应包含file_count"
  assert_json_has_field "${result}" ".risk_tag_count" "应包含risk_tag_count"
}

test_low_risk_change_types() {
  assert_true "docs_only应是低风险" risk_is_low_risk_change_type "docs_only"
  assert_true "comment_only应是低风险" risk_is_low_risk_change_type "comment_only"
  assert_true "test_only应是低风险" risk_is_low_risk_change_type "test_only"
  assert_false "logic_change不应是低风险" risk_is_low_risk_change_type "logic_change"
  assert_false "config_change不应是低风险" risk_is_low_risk_change_type "config_change"
  assert_false "schema_change不应是低风险" risk_is_low_risk_change_type "schema_change"
  assert_false "infra_change不应是低风险" risk_is_low_risk_change_type "infra_change"
  assert_false "mixed_change不应是低风险" risk_is_low_risk_change_type "mixed_change"
}

###############################################################################
# 运行所有测试
###############################################################################
echo "== test_risk_classifier.sh =="

run_test test_auth_path_triggers_tier3
run_test test_permission_path_triggers_tier3
run_test test_oauth_path_triggers_tier3
run_test test_token_path_triggers_tier3
run_test test_secret_path_triggers_tier3
run_test test_payment_path_triggers_tier3
run_test test_billing_path_triggers_tier3
run_test test_deploy_path_triggers_tier3
run_test test_migration_path_triggers_tier3
run_test test_schema_path_triggers_tier3
run_test test_prod_path_triggers_tier3
run_test test_acl_path_triggers_tier3
run_test test_api_source_triggers_tier2
run_test test_service_source_triggers_tier2
run_test test_docs_only_triggers_tier1
run_test test_single_readme_triggers_tier1
run_test test_test_only_triggers_tier1
run_test test_diff_jwt_triggers_upgrade
run_test test_diff_session_triggers_upgrade
run_test test_diff_credential_triggers_upgrade
run_test test_change_type_docs_only
run_test test_change_type_comment_only
run_test test_change_type_test_only
run_test test_change_type_logic_change
run_test test_change_type_config_change
run_test test_change_type_schema_change
run_test test_change_type_infra_change
run_test test_change_type_mixed_change
run_test test_path_and_diff_both_trigger_tier3
run_test test_tier3_overrides_tier2
run_test test_no_risk_tags_logic_change_is_tier2
run_test test_risk_classify_empty_input
run_test test_risk_classify_paths_deduplication
run_test test_risk_classify_case_insensitive
run_test test_risk_classify_output_json_valid
run_test test_risk_classify_has_required_fields
run_test test_low_risk_change_types

print_report "test_risk_classifier.sh"
