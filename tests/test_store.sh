#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

# Ensure sqlite3 is on PATH (Windows: /c/sqlite)
export PATH="/c/sqlite:${PATH}"

_load_store() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  # Copy schema to tmp so store_init can find it
  mkdir -p "${TEST_TMP}/lib"
  cp "${LIB_DIR}/store_schema.sql" "${TEST_TMP}/lib/"
  source "${LIB_DIR}/store.sh"
}

test_store_init_creates_db() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  [[ -f "${TEST_TMP}/.bashclaw/bashclaw.db" ]] || {
    echo "bashclaw.db should be created" >&2; return 1
  }
}

test_store_init_creates_tables() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  local tables
  tables=$(sqlite3 "${BASHCLAW_DB}" ".tables" 2>/dev/null)
  assert_contains "${tables}" "cards" "Should have cards table"
  assert_contains "${tables}" "conversations" "Should have conversations table"
  assert_contains "${tables}" "messages" "Should have messages table"
}

test_store_card_insert_and_query() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  local card_id
  card_id=$(store_card_insert "Test token refresh" "auth token refresh" \
    "Must validate tenant boundary" "cross-tenant risk" \
    '["auth","token"]' "security_risk")
  [[ -n "${card_id}" ]] || {
    echo "card_id should not be empty" >&2; return 1
  }
  local title
  title=$(store_card_get_field "${card_id}" "title")
  assert_eq "Test token refresh" "${title}" "Card title should match"
}

test_store_card_search_by_keyword() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  store_card_insert "Token refresh tenant check" "auth token refresh" \
    "Validate tenant boundary" "cross-tenant" '["auth"]' "security_risk"
  store_card_insert "CORS misconfiguration" "cors headers" \
    "Set correct origins" "wildcard origin" '["cors"]' "security_risk"
  local results
  results=$(store_card_search "auth token refresh")
  assert_contains "${results}" "Token refresh" "Should find auth-related card"
  assert_not_contains "${results}" "CORS" "Should not find unrelated card"
}

test_store_card_search_fts() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  store_card_insert "SQL injection via dynamic query" "sql injection" \
    "Use parameterized queries" "dynamic string concat" '["sql"]' "security_risk"
  local results
  results=$(store_card_search "injection parameterized")
  assert_contains "${results}" "SQL injection" "FTS should find by content keywords"
}

test_store_conversation_insert() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  local conv_id
  conv_id=$(store_conversation_insert "claude_code" "Fix auth token refresh" "session-abc-123")
  [[ -n "${conv_id}" ]] || {
    echo "conv_id should not be empty" >&2; return 1
  }
  local source
  source=$(sqlite3 "${BASHCLAW_DB}" "SELECT source FROM conversations WHERE id='${conv_id}'")
  assert_eq "claude_code" "${source}" "Conversation source should match"
}

test_store_card_conversation_link() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  local conv_id card_id
  conv_id=$(store_conversation_insert "chatgpt" "Debug CORS issue" "")
  card_id=$(store_card_insert "CORS fix" "cors" "Set origins" "wildcard" '["cors"]' "security_risk")
  store_card_link_conversation "${card_id}" "${conv_id}"
  local linked
  linked=$(sqlite3 "${BASHCLAW_DB}" "SELECT conversation_id FROM card_sources WHERE card_id='${card_id}'")
  assert_eq "${conv_id}" "${linked}" "Card should be linked to conversation"
}

test_store_seed_import() {
  _load_store
  store_init "${TEST_TMP}/.bashclaw"
  # Create a seed file
  cat > "${TEST_TMP}/seed.json" <<'EOF'
{
  "decision_title": "Test seed",
  "applicable_scope": "test",
  "final_decision": "Do X",
  "why": "Because Y",
  "known_pitfalls": ["pitfall1"],
  "risk_tags": ["test"],
  "issue_type": "logic_bug"
}
EOF
  store_seed_import "${TEST_TMP}/seed.json"
  local count
  count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM cards")
  assert_eq "1" "${count}" "Should have 1 card after seed import"
}

echo "== test_store.sh =="
run_test test_store_init_creates_db
run_test test_store_init_creates_tables
run_test test_store_card_insert_and_query
run_test test_store_card_search_by_keyword
run_test test_store_card_search_fts
run_test test_store_conversation_insert
run_test test_store_card_conversation_link
run_test test_store_seed_import
print_report "test_store.sh"
