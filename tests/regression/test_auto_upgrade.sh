#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# test_auto_upgrade.sh — 自动升级回归测试
#
# 验证：
#   - auth 关键词 → 自动 Tier 3
#   - api/service/core → 自动 Tier 2
#   - docs_only → 保持 Tier 1
#   - diff 内容模式（jwt/credential/subprocess）→ 升级
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source test helper
source "${TEST_ROOT}/tests/test_helper.sh"

# Source library modules
source "${LIB_DIR}/risk_classifier.sh"
source "${LIB_DIR}/routing.sh"

###############################################################################
# Tests: Path-based auto-upgrade to Tier 3
###############################################################################

test_auto_upgrade_auth_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "src/auth/login.py")

  local tier
  tier="$(risk_suggest_tier "logic_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "auth path should upgrade to tier 3"
}

test_auto_upgrade_permission_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "lib/permission/roles.py")

  local tier
  tier="$(risk_suggest_tier "logic_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "permission path should upgrade to tier 3"
}

test_auto_upgrade_oauth_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "services/oauth_provider.py")

  local tier
  tier="$(risk_suggest_tier "logic_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "oauth path should upgrade to tier 3"
}

test_auto_upgrade_token_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "lib/token_manager.py")

  local tier
  tier="$(risk_suggest_tier "logic_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "token path should upgrade to tier 3"
}

test_auto_upgrade_secret_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "config/secrets.yaml")

  local tier
  tier="$(risk_suggest_tier "config_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "secret path should upgrade to tier 3"
}

test_auto_upgrade_payment_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "services/payment/stripe.py")

  local tier
  tier="$(risk_suggest_tier "logic_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "payment path should upgrade to tier 3"
}

test_auto_upgrade_billing_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "billing/invoices.py")

  local tier
  tier="$(risk_suggest_tier "logic_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "billing path should upgrade to tier 3"
}

test_auto_upgrade_deploy_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "deploy/production.sh")

  local tier
  tier="$(risk_suggest_tier "infra_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "deploy path should upgrade to tier 3"
}

test_auto_upgrade_migration_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "db/migrations/0003_alter.sql")

  local tier
  tier="$(risk_suggest_tier "schema_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "migration path should upgrade to tier 3"
}

test_auto_upgrade_schema_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "models/schema_v2.py")

  local tier
  tier="$(risk_suggest_tier "schema_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "schema path should upgrade to tier 3"
}

test_auto_upgrade_prod_to_tier3() {
  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_paths "config/prod_settings.py")

  local tier
  tier="$(risk_suggest_tier "config_change" "${tags[@]}")"
  assert_eq "3" "${tier}" "prod path should upgrade to tier 3"
}

###############################################################################
# Tests: Non-risk paths → Tier 2 (logic_change without risk keywords)
###############################################################################

test_auto_upgrade_logic_change_to_tier2() {
  local change_type
  change_type="$(risk_classify_change_type "src/utils/formatter.py")"
  assert_eq "logic_change" "${change_type}" "source file should be logic_change"

  local tier
  tier="$(risk_suggest_tier "${change_type}")"
  assert_eq "2" "${tier}" "logic_change should be tier 2"
}

test_auto_upgrade_config_change_to_tier2() {
  local change_type
  change_type="$(risk_classify_change_type "settings.json")"
  assert_eq "config_change" "${change_type}" "json file should be config_change"

  local tier
  tier="$(risk_suggest_tier "${change_type}")"
  assert_eq "2" "${tier}" "config_change should be tier 2"
}

###############################################################################
# Tests: docs_only stays Tier 1
###############################################################################

test_auto_upgrade_docs_stays_tier1() {
  local change_type
  change_type="$(risk_classify_change_type "docs/README.md" "CHANGELOG.md")"
  assert_eq "docs_only" "${change_type}" "doc files should be docs_only"

  local tier
  tier="$(risk_suggest_tier "${change_type}")"
  assert_eq "1" "${tier}" "docs_only should stay tier 1"
}

test_auto_upgrade_test_only_stays_tier1() {
  local change_type
  change_type="$(risk_classify_change_type "tests/test_utils.py")"
  assert_eq "test_only" "${change_type}" "test file should be test_only"

  local tier
  tier="$(risk_suggest_tier "${change_type}")"
  assert_eq "1" "${tier}" "test_only should stay tier 1"
}

###############################################################################
# Tests: Diff content pattern → upgrade
###############################################################################

test_auto_upgrade_diff_jwt_pattern() {
  local diff_file
  diff_file="$(mktemp)"
  echo "+ token = jwt.decode(access_token, secret_key)" > "${diff_file}"

  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_diff_content "${diff_file}")
  rm -f "${diff_file}"

  # Should have matched jwt and/or token pattern
  local found=false
  for t in "${tags[@]}"; do
    if [[ "${t}" == *"token"* || "${t}" == *"jwt"* ]]; then
      found=true
      break
    fi
  done

  if [[ "${found}" != "true" ]]; then
    echo "Expected jwt/token pattern match in diff, got: ${tags[*]}" >&2
    return 1
  fi
}

test_auto_upgrade_diff_credential_pattern() {
  local diff_file
  diff_file="$(mktemp)"
  echo "+ load_credential_from_vault(secret_name)" > "${diff_file}"

  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_diff_content "${diff_file}")
  rm -f "${diff_file}"

  local found=false
  for t in "${tags[@]}"; do
    if [[ "${t}" == *"credential"* || "${t}" == *"secret"* ]]; then
      found=true
      break
    fi
  done

  if [[ "${found}" != "true" ]]; then
    echo "Expected credential/secret pattern match in diff, got: ${tags[*]}" >&2
    return 1
  fi
}

test_auto_upgrade_diff_subprocess_pattern() {
  local diff_file
  diff_file="$(mktemp)"
  echo "+ result = subprocess.run(['ssh', host, 'deploy'])" > "${diff_file}"

  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_diff_content "${diff_file}")
  rm -f "${diff_file}"

  local found=false
  for t in "${tags[@]}"; do
    if [[ "${t}" == *"subprocess"* || "${t}" == *"ssh"* || "${t}" == *"deploy"* ]]; then
      found=true
      break
    fi
  done

  if [[ "${found}" != "true" ]]; then
    echo "Expected subprocess/ssh/deploy pattern match in diff, got: ${tags[*]}" >&2
    return 1
  fi
}

test_auto_upgrade_diff_session_pattern() {
  local diff_file
  diff_file="$(mktemp)"
  echo "+ session.set_tenant_token(tenant_id, new_session_key)" > "${diff_file}"

  local -a tags=()
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && tags+=("${tag}")
  done < <(risk_classify_diff_content "${diff_file}")
  rm -f "${diff_file}"

  local found=false
  for t in "${tags[@]}"; do
    if [[ "${t}" == *"session"* || "${t}" == *"tenant"* || "${t}" == *"token"* ]]; then
      found=true
      break
    fi
  done

  if [[ "${found}" != "true" ]]; then
    echo "Expected session/tenant/token pattern match, got: ${tags[*]}" >&2
    return 1
  fi
}

###############################################################################
# Tests: Full risk_classify pipeline
###############################################################################

test_auto_upgrade_full_classify_auth_file() {
  local result
  result="$(risk_classify --files "src/auth/session.py")"
  assert_json_field "${result}" '.tier_suggestion' '3' "auth file should suggest tier 3"
  assert_contains "${result}" '"auth"' "should have auth risk tag"
}

test_auto_upgrade_full_classify_docs_file() {
  local result
  result="$(risk_classify --files "docs/guide.md")"
  assert_json_field "${result}" '.tier_suggestion' '1' "docs file should suggest tier 1"
  assert_json_field "${result}" '.change_type' 'docs_only' "should be docs_only"
}

###############################################################################
# Tests: Routing resolve with auto-upgrade
###############################################################################

test_auto_upgrade_resolve_tier_upgrades() {
  # No prefix (tier 1), but risk says tier 3
  local effective
  effective="$(routing_resolve_tier "1" "3")"
  assert_eq "3" "${effective}" "should upgrade from 1 to 3 based on risk"
}

test_auto_upgrade_resolve_tier_no_downgrade() {
  # /review prefix (tier 2), risk says tier 1
  local effective
  effective="$(routing_resolve_tier "2" "1")"
  assert_eq "2" "${effective}" "should not downgrade from 2 to 1"
}

###############################################################################
# Run all tests
###############################################################################

echo "=== 自动升级回归测试 ==="

run_test test_auto_upgrade_auth_to_tier3
run_test test_auto_upgrade_permission_to_tier3
run_test test_auto_upgrade_oauth_to_tier3
run_test test_auto_upgrade_token_to_tier3
run_test test_auto_upgrade_secret_to_tier3
run_test test_auto_upgrade_payment_to_tier3
run_test test_auto_upgrade_billing_to_tier3
run_test test_auto_upgrade_deploy_to_tier3
run_test test_auto_upgrade_migration_to_tier3
run_test test_auto_upgrade_schema_to_tier3
run_test test_auto_upgrade_prod_to_tier3
run_test test_auto_upgrade_logic_change_to_tier2
run_test test_auto_upgrade_config_change_to_tier2
run_test test_auto_upgrade_docs_stays_tier1
run_test test_auto_upgrade_test_only_stays_tier1
run_test test_auto_upgrade_diff_jwt_pattern
run_test test_auto_upgrade_diff_credential_pattern
run_test test_auto_upgrade_diff_subprocess_pattern
run_test test_auto_upgrade_diff_session_pattern
run_test test_auto_upgrade_full_classify_auth_file
run_test test_auto_upgrade_full_classify_docs_file
run_test test_auto_upgrade_resolve_tier_upgrades
run_test test_auto_upgrade_resolve_tier_no_downgrade

print_report "test_auto_upgrade.sh"
