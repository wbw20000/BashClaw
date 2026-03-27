#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

# Ensure sqlite3 is on PATH (Windows: /c/sqlite)
export PATH="/c/sqlite:${PATH}"

test_config_provider_is_local() {
  setup_tmp
  local provider
  provider=$(jq -r '.knowledge.provider' "${TEST_TMP}/bashclaw.json")
  assert_eq "local" "${provider}" "knowledge.provider should be 'local'"
  cleanup_tmp
}

test_knowledge_gate_queries_sqlite() {
  setup_tmp
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  # Copy schema
  mkdir -p "${TEST_TMP}/lib"
  cp "${LIB_DIR}/store_schema.sql" "${TEST_TMP}/lib/"
  cp "${LIB_DIR}/store.sh" "${TEST_TMP}/lib/"

  source "${LIB_DIR}/store.sh"
  store_init "${TEST_TMP}/.bashclaw"
  # Insert a card
  store_card_insert "Token refresh must validate tenant" "auth token refresh" \
    "Validate tenant_id on refresh" "cross-tenant pollution" '["auth","token"]' "security_risk"

  source "${LIB_DIR}/knowledge_gate.sh"
  local result
  result=$(knowledge_gate_run "auth token refresh" "fix token" "logic_change" "" "auth" "" "" "2" "")
  local hits
  hits=$(echo "${result}" | jq -r '.hit_count')
  [[ "${hits}" -ge 1 ]] || {
    echo "Should find card via SQLite, got ${hits} hits" >&2; return 1
  }
  local source_type
  source_type=$(echo "${result}" | jq -r '.retrieval_source')
  assert_eq "sqlite" "${source_type}" "retrieval_source should be sqlite"
  cleanup_tmp
}

echo "== test_knowledge_local_first.sh =="
run_test test_config_provider_is_local
run_test test_knowledge_gate_queries_sqlite
print_report "test_knowledge_local_first.sh"
