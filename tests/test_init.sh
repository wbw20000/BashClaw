#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

export PATH="/c/sqlite:${PATH}"

_load_bashclaw_for_init() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export BASHCLAW_LIB="${LIB_DIR}"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  export BASHCLAW_LOG_LEVEL="error"
  if [[ -d "${TEST_ROOT}/hooks" ]]; then
    cp -r "${TEST_ROOT}/hooks" "${TEST_TMP}/hooks"
  fi
  source "${TEST_ROOT}/bashclaw.sh"
}

test_init_creates_dirs() {
  _load_bashclaw_for_init
  bashclaw_init "${TEST_TMP}" 2>/dev/null
  [[ -d "${TEST_TMP}/.bashclaw/audit" ]] || { echo "audit dir missing" >&2; return 1; }
  [[ -d "${TEST_TMP}/.bashclaw/knowledge" ]] || { echo "knowledge dir missing" >&2; return 1; }
  [[ -d "${TEST_TMP}/.bashclaw/tmp" ]] || { echo "tmp dir missing" >&2; return 1; }
}

test_init_creates_db() {
  _load_bashclaw_for_init
  bashclaw_init "${TEST_TMP}" 2>/dev/null
  [[ -f "${TEST_TMP}/.bashclaw/bashclaw.db" ]] || {
    echo "bashclaw.db should be created by init" >&2; return 1
  }
}

test_init_loads_seeds() {
  _load_bashclaw_for_init
  # Create a seed file
  mkdir -p "${TEST_TMP}/seeds"
  cat > "${TEST_TMP}/seeds/test_seed.json" <<'EOF'
{
  "decision_title": "Init test seed",
  "applicable_scope": "test",
  "final_decision": "Do X",
  "why": "Because Y",
  "known_pitfalls": ["p1"],
  "risk_tags": ["test"],
  "issue_type": "logic_bug"
}
EOF
  bashclaw_init "${TEST_TMP}" 2>/dev/null
  local count
  count=$(sqlite3 "${TEST_TMP}/.bashclaw/bashclaw.db" "SELECT COUNT(*) FROM cards")
  assert_eq "1" "${count}" "Should load 1 seed card"
}

test_init_no_duplicate_seeds() {
  _load_bashclaw_for_init
  mkdir -p "${TEST_TMP}/seeds"
  cat > "${TEST_TMP}/seeds/test_seed.json" <<'EOF'
{
  "decision_title": "No dup seed",
  "applicable_scope": "test",
  "final_decision": "Do X",
  "why": "Because Y",
  "known_pitfalls": [],
  "risk_tags": [],
  "issue_type": "logic_bug"
}
EOF
  bashclaw_init "${TEST_TMP}" 2>/dev/null
  # Run init again
  bashclaw_init "${TEST_TMP}" 2>/dev/null
  local count
  count=$(sqlite3 "${TEST_TMP}/.bashclaw/bashclaw.db" "SELECT COUNT(*) FROM cards")
  assert_eq "1" "${count}" "Should not duplicate seeds on second init"
}

echo "== test_init.sh =="
run_test test_init_creates_dirs
run_test test_init_creates_db
run_test test_init_loads_seeds
run_test test_init_no_duplicate_seeds
print_report "test_init.sh"
