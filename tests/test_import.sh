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

echo "== test_import.sh =="
run_test test_import_claude_code_jsonl
run_test test_import_chatgpt_json
run_test test_import_dispatch_claude_code
print_report "test_import.sh"
