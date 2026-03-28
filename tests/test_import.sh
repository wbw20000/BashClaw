#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

export PATH="/c/sqlite:${PATH}"

_load_import() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  mkdir -p "${TEST_TMP}/lib"
  cp "${LIB_DIR}/store_schema.sql" "${TEST_TMP}/lib/"
  cp "${LIB_DIR}/store.sh" "${TEST_TMP}/lib/"
  source "${LIB_DIR}/store.sh"
  store_init "${TEST_TMP}/.bashclaw"
  source "${LIB_DIR}/import.sh"
}

test_import_claude_code_jsonl() {
  _load_import
  cat > "${TEST_TMP}/session.jsonl" <<'EOF'
{"type":"human","text":"Fix the auth token refresh bug"}
{"type":"assistant","text":"I'll fix the tenant validation in auth/session.py"}
{"type":"human","text":"Looks good, ship it"}
EOF
  import_claude_code "${TEST_TMP}/session.jsonl" "Fix auth bug" >/dev/null
  local conv_count
  conv_count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM conversations WHERE source='claude_code'")
  assert_eq "1" "${conv_count}" "Should create 1 conversation"
  local msg_count
  msg_count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM messages")
  assert_eq "3" "${msg_count}" "Should import 3 messages"
}

test_import_chatgpt_json() {
  _load_import
  cat > "${TEST_TMP}/chatgpt.json" <<'EOF'
{
  "title": "Debug CORS issue",
  "mapping": {
    "a1": {"message": {"author": {"role": "user"}, "content": {"parts": ["Why is CORS failing?"]}}},
    "a2": {"message": {"author": {"role": "assistant"}, "content": {"parts": ["Check your Access-Control-Allow-Origin header"]}}}
  }
}
EOF
  import_chatgpt "${TEST_TMP}/chatgpt.json" >/dev/null
  local conv_count
  conv_count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM conversations WHERE source='chatgpt'")
  assert_eq "1" "${conv_count}" "Should create 1 chatgpt conversation"
}

test_import_dispatch_claude_code() {
  _load_import
  cat > "${TEST_TMP}/test.jsonl" <<'EOF'
{"type":"human","text":"hello"}
{"type":"assistant","text":"hi"}
EOF
  import_dispatch "claude-code" "${TEST_TMP}/test.jsonl" "Test session" >/dev/null
  local count
  count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM conversations")
  assert_eq "1" "${count}" "Dispatch should route to claude-code importer"
}

test_import_claude_code_with_malformed_lines() {
  _load_import
  cat > "${TEST_TMP}/mixed.jsonl" <<'EOF'
{"type":"human","text":"Valid line 1"}
this is not json at all
{"type":"assistant","text":"Valid line 2"}
{"broken json
{"type":"human","text":"Valid line 3"}
EOF
  local stderr_output
  stderr_output=$(import_claude_code "${TEST_TMP}/mixed.jsonl" "Mixed session" 2>&1 >/dev/null) || true
  local msg_count
  msg_count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM messages")
  assert_eq "3" "${msg_count}" "Should import 3 valid messages"
  assert_contains "${stderr_output}" "WARNING" "Should warn about failed lines"
}

test_import_empty_file() {
  _load_import
  touch "${TEST_TMP}/empty.jsonl"
  local conv_id
  conv_id=$(import_claude_code "${TEST_TMP}/empty.jsonl" "Empty" 2>/dev/null)
  [[ -n "${conv_id}" ]] || {
    echo "Should create conversation even for empty file" >&2; return 1
  }
  local msg_count
  msg_count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM messages")
  assert_eq "0" "${msg_count}" "Empty file should produce 0 messages"
}

echo "== test_import.sh =="
run_test test_import_claude_code_jsonl
run_test test_import_chatgpt_json
run_test test_import_dispatch_claude_code
run_test test_import_claude_code_with_malformed_lines
run_test test_import_empty_file
print_report "test_import.sh"
