# BashClaw Phase 1 Completion Implementation Plan (v2 — Codex-revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Phase 1: local-first SQLite knowledge store (compatible with SiYuan 3.38.0), stats command, git hooks, TS entry, and minimal import command.

**Architecture:** Replace JSON-file knowledge store with SQLite (WAL mode, FTS5 full-text search). Two logical layers: BashClaw Core (workflow engine) and BashClaw Memory (cards + conversations + provenance). Knowledge gate queries SQLite on the hot path. Conversations stored as archive for training data and context recovery. MCP/SiYuan is optional import/export connector.

**Tech Stack:** Bash 4+, jq, sqlite3 CLI, Node.js/TypeScript (TS entry only), git hooks

**SiYuan Compatibility Notes:**
- SiYuan uses SQLite 3.38.0, WAL mode, page_size=32768
- SiYuan's FTS5 uses custom "siyuan" tokenizer (compiled in Go) — we use standard `unicode61` tokenizer instead
- SiYuan's blocks table has 21 columns — our `cards` table maps to a subset
- Future upgrade path: export cards → SiYuan API (`/api/query/sql`) or direct .sy file generation
- Integration with SiYuan should go through its HTTP API (localhost:6806), not direct DB writes

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/store.sh` | Create | SQLite wrapper: init schema, CRUD for cards/conversations/messages |
| `lib/store_schema.sql` | Create | DDL: tables, indexes, FTS5 virtual tables |
| `lib/knowledge_gate.sh` | Modify | Query SQLite instead of scanning JSON files |
| `lib/memory_writeback.sh` | Modify | Write to SQLite instead of JSON files |
| `bashclaw.json` | Modify | `knowledge.provider` → `"local"`, add `store.type` → `"sqlite"` |
| `bashclaw.sh` | Modify | Add `stats`, `init`, `import` commands |
| `lib/audit_log.sh` | Modify | Add knowledge hit metrics to stats |
| `lib/import.sh` | Create | Multi-source conversation import (Claude Code JSONL, ChatGPT JSON) |
| `hooks/post-commit` | Create | Lightweight risk tagger |
| `hooks/pre-push` | Create | Tier 2 review gate |
| `lib/hook_helpers.sh` | Create | Shared hook logic |
| `package.json` | Create | npm package |
| `tsconfig.json` | Create | TS compiler config |
| `bin/bashclaw.ts` | Create | TS thin entry |
| `tests/test_store.sh` | Create | SQLite store tests |
| `tests/test_import.sh` | Create | Import tests |
| `tests/test_stats_command.sh` | Create | Stats command tests |
| `tests/test_hooks.sh` | Create | Hook helper tests |
| `tests/test_init.sh` | Create | Init + hook install + seed load tests |

---

## Task 1: SQLite Store Layer

**Files:**
- Create: `lib/store_schema.sql`
- Create: `lib/store.sh`
- Test: `tests/test_store.sh`

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_store.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_store() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_store.sh`
Expected: FAIL — `lib/store.sh` does not exist

- [ ] **Step 3: Create `lib/store_schema.sql`**

```sql
-- BashClaw SQLite Schema v1
-- Compatible with SQLite 3.38.0+ (SiYuan uses 3.38.0)
-- WAL mode for concurrent read/write

PRAGMA journal_mode=WAL;
PRAGMA page_size=32768;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;

-- Knowledge cards (distilled from conversations)
-- Maps loosely to SiYuan's blocks table structure
CREATE TABLE IF NOT EXISTS cards (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  scope       TEXT NOT NULL DEFAULT '',
  decision    TEXT NOT NULL DEFAULT '',
  why         TEXT NOT NULL DEFAULT '',
  pitfalls    TEXT NOT NULL DEFAULT '[]',   -- JSON array
  evidence    TEXT NOT NULL DEFAULT '',
  risk_tags   TEXT NOT NULL DEFAULT '[]',   -- JSON array
  issue_type  TEXT NOT NULL DEFAULT '',
  change_type TEXT NOT NULL DEFAULT '',
  superseded_by TEXT DEFAULT NULL,
  merge_count INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- FTS5 index for card search (standard unicode61 tokenizer, not SiYuan's custom one)
CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(
  title, scope, decision, why, pitfalls, evidence, risk_tags,
  content=cards,
  content_rowid=rowid,
  tokenize='unicode61'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS cards_ai AFTER INSERT ON cards BEGIN
  INSERT INTO cards_fts(rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES (new.rowid, new.title, new.scope, new.decision, new.why, new.pitfalls, new.evidence, new.risk_tags);
END;

CREATE TRIGGER IF NOT EXISTS cards_ad AFTER DELETE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES ('delete', old.rowid, old.title, old.scope, old.decision, old.why, old.pitfalls, old.evidence, old.risk_tags);
END;

CREATE TRIGGER IF NOT EXISTS cards_au AFTER UPDATE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES ('delete', old.rowid, old.title, old.scope, old.decision, old.why, old.pitfalls, old.evidence, old.risk_tags);
  INSERT INTO cards_fts(rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES (new.rowid, new.title, new.scope, new.decision, new.why, new.pitfalls, new.evidence, new.risk_tags);
END;

-- Conversations (raw chat sessions from any source)
CREATE TABLE IF NOT EXISTS conversations (
  id          TEXT PRIMARY KEY,
  source      TEXT NOT NULL DEFAULT 'unknown',  -- claude_code, chatgpt, claude_web, cursor
  title       TEXT NOT NULL DEFAULT '',
  external_id TEXT DEFAULT '',                   -- original session ID from source platform
  message_count INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  imported_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Messages within conversations
CREATE TABLE IF NOT EXISTS messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  role            TEXT NOT NULL DEFAULT 'user',  -- user, assistant, system, tool
  content         TEXT NOT NULL DEFAULT '',
  seq             INTEGER NOT NULL DEFAULT 0,    -- message order within conversation
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, seq);

-- Provenance: card <-> conversation links
CREATE TABLE IF NOT EXISTS card_sources (
  card_id         TEXT NOT NULL REFERENCES cards(id),
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  message_range   TEXT DEFAULT '',  -- e.g. "12-18" = messages 12-18 in conversation
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (card_id, conversation_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_cards_issue_type ON cards(issue_type);
CREATE INDEX IF NOT EXISTS idx_cards_superseded ON cards(superseded_by);
CREATE INDEX IF NOT EXISTS idx_conversations_source ON conversations(source);
```

- [ ] **Step 4: Create `lib/store.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# store.sh — BashClaw SQLite knowledge store
#
# Local-first storage layer for knowledge cards and conversations.
# Compatible with SQLite 3.38.0 (SiYuan's version) for future upgrade path.
# Uses FTS5 for full-text search with unicode61 tokenizer.
###############################################################################

[[ -n "${_STORE_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_STORE_SH_LOADED=1

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASHCLAW_DB="${BASHCLAW_DB:-${BASHCLAW_ROOT}/.bashclaw/bashclaw.db}"

# Check sqlite3 is available
_store_check_sqlite() {
  if ! command -v sqlite3 &>/dev/null; then
    echo "ERROR: sqlite3 is required. Install it: https://sqlite.org/download.html" >&2
    return 1
  fi
}

# Run SQL against the BashClaw database
_store_sql() {
  sqlite3 "${BASHCLAW_DB}" "$@"
}

# Initialize database with schema
store_init() {
  local bc_dir="${1:-${BASHCLAW_ROOT}/.bashclaw}"
  mkdir -p "${bc_dir}"
  BASHCLAW_DB="${bc_dir}/bashclaw.db"

  _store_check_sqlite || return 1

  local schema_file="${BASHCLAW_ROOT}/lib/store_schema.sql"
  if [[ -f "${schema_file}" ]]; then
    _store_sql < "${schema_file}"
  fi
}

# Generate a unique ID: YYYYMMDD-HHMMSS-RANDOM
_store_gen_id() {
  local prefix="${1:-}"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local rand=$(( RANDOM % 10000 ))
  printf "%s%s-%04d" "${prefix}" "${ts}" "${rand}"
}

###############################################################################
# Card CRUD
###############################################################################

# Insert a knowledge card
# Args: title scope decision why risk_tags_json issue_type
# Output: card ID
store_card_insert() {
  local title="$1"
  local scope="$2"
  local decision="$3"
  local why="$4"
  local risk_tags="${5:-[]}"
  local issue_type="${6:-}"

  local card_id
  card_id="$(_store_gen_id "KC-")"

  _store_sql <<SQL
INSERT INTO cards (id, title, scope, decision, why, risk_tags, issue_type)
VALUES ('${card_id}', '$(echo "${title}" | sed "s/'/''/g")', '$(echo "${scope}" | sed "s/'/''/g")', '$(echo "${decision}" | sed "s/'/''/g")', '$(echo "${why}" | sed "s/'/''/g")', '$(echo "${risk_tags}" | sed "s/'/''/g")', '$(echo "${issue_type}" | sed "s/'/''/g")');
SQL

  echo "${card_id}"
}

# Get a single field from a card
store_card_get_field() {
  local card_id="$1"
  local field="$2"
  _store_sql "SELECT ${field} FROM cards WHERE id='${card_id}'"
}

# Search cards using FTS5
# Args: query_string
# Output: JSON array of matching cards
store_card_search() {
  local query="$1"
  local limit="${2:-10}"

  # Escape single quotes in query
  local safe_query
  safe_query="$(echo "${query}" | sed "s/'/''/g")"

  _store_sql -json <<SQL
SELECT c.id, c.title, c.scope, c.decision, c.why, c.pitfalls, c.risk_tags, c.issue_type
FROM cards_fts fts
JOIN cards c ON c.rowid = fts.rowid
WHERE cards_fts MATCH '${safe_query}'
AND c.superseded_by IS NULL
ORDER BY rank
LIMIT ${limit};
SQL
}

# Search cards by keyword (fallback if FTS fails)
store_card_search_keyword() {
  local query="$1"
  local limit="${2:-10}"

  local safe_query
  safe_query="$(echo "${query}" | sed "s/'/''/g")"

  _store_sql -json <<SQL
SELECT id, title, scope, decision, why, pitfalls, risk_tags, issue_type
FROM cards
WHERE superseded_by IS NULL
AND (title LIKE '%${safe_query}%' OR scope LIKE '%${safe_query}%'
     OR decision LIKE '%${safe_query}%' OR risk_tags LIKE '%${safe_query}%')
LIMIT ${limit};
SQL
}

###############################################################################
# Conversation CRUD
###############################################################################

# Insert a conversation
# Args: source title external_id
# Output: conversation ID
store_conversation_insert() {
  local source="$1"
  local title="$2"
  local external_id="${3:-}"

  local conv_id
  conv_id="$(_store_gen_id "CV-")"

  _store_sql <<SQL
INSERT INTO conversations (id, source, title, external_id)
VALUES ('${conv_id}', '${source}', '$(echo "${title}" | sed "s/'/''/g")', '${external_id}');
SQL

  echo "${conv_id}"
}

# Insert a message into a conversation
# Args: conversation_id role content seq
# Output: message ID
store_message_insert() {
  local conv_id="$1"
  local role="$2"
  local content="$3"
  local seq="${4:-0}"

  local msg_id
  msg_id="$(_store_gen_id "MG-")"

  _store_sql <<SQL
INSERT INTO messages (id, conversation_id, role, content, seq)
VALUES ('${msg_id}', '${conv_id}', '${role}', '$(echo "${content}" | sed "s/'/''/g")', ${seq});
UPDATE conversations SET message_count = message_count + 1 WHERE id = '${conv_id}';
SQL

  echo "${msg_id}"
}

###############################################################################
# Provenance: link cards to conversations
###############################################################################

store_card_link_conversation() {
  local card_id="$1"
  local conv_id="$2"
  local msg_range="${3:-}"

  _store_sql <<SQL
INSERT OR IGNORE INTO card_sources (card_id, conversation_id, message_range)
VALUES ('${card_id}', '${conv_id}', '${msg_range}');
SQL
}

###############################################################################
# Seed import: load a seed JSON file into a card
###############################################################################

store_seed_import() {
  local json_file="$1"

  if [[ ! -f "${json_file}" ]]; then
    echo "ERROR: File not found: ${json_file}" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq required for seed import" >&2
    return 1
  fi

  local title scope decision why pitfalls risk_tags issue_type
  title=$(jq -r '.decision_title // ""' "${json_file}")
  scope=$(jq -r '.applicable_scope // ""' "${json_file}")
  decision=$(jq -r '.final_decision // ""' "${json_file}")
  why=$(jq -r '.why // ""' "${json_file}")
  pitfalls=$(jq -c '.known_pitfalls // []' "${json_file}")
  risk_tags=$(jq -c '.risk_tags // []' "${json_file}")
  issue_type=$(jq -r '.issue_type // ""' "${json_file}")

  store_card_insert "${title}" "${scope}" "${decision}" "${why}" "${risk_tags}" "${issue_type}"
}

###############################################################################
# Stats: card and conversation counts
###############################################################################

store_stats() {
  _store_sql -json <<SQL
SELECT
  (SELECT COUNT(*) FROM cards WHERE superseded_by IS NULL) as active_cards,
  (SELECT COUNT(*) FROM cards WHERE superseded_by IS NOT NULL) as superseded_cards,
  (SELECT COUNT(*) FROM conversations) as total_conversations,
  (SELECT COUNT(*) FROM messages) as total_messages,
  (SELECT COUNT(DISTINCT source) FROM conversations) as source_count;
SQL
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_store.sh`
Expected: All 8 tests PASS

- [ ] **Step 6: Commit**

```bash
git add lib/store_schema.sql lib/store.sh tests/test_store.sh
git commit -m "feat: add SQLite store layer with cards, conversations, FTS5 search"
```

---

## Task 2: Wire Knowledge Gate to SQLite

**Files:**
- Modify: `bashclaw.json:64-70`
- Modify: `lib/knowledge_gate.sh`
- Test: `tests/test_knowledge_local_first.sh`

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_knowledge_local_first.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

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
  cleanup_tmp
}

echo "== test_knowledge_local_first.sh =="
run_test test_config_provider_is_local
run_test test_knowledge_gate_queries_sqlite
print_report "test_knowledge_local_first.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_knowledge_local_first.sh`
Expected: FAIL — config still has `"provider": "mcp"` and knowledge_gate doesn't query SQLite

- [ ] **Step 3: Flip config in `bashclaw.json`**

Change `knowledge` section to:
```json
  "knowledge": {
    "provider": "local",
    "store_type": "sqlite",
    "mcp_fallback": "mcp",
    "mcp_endpoint": "",
    "retrieveTopK": 5,
    "minSimilarity": 0.75
  },
```

- [ ] **Step 4: Update `knowledge_gate_run()` in `lib/knowledge_gate.sh`**

Replace the search strategy section (lines 219-325) to query SQLite first, fall back to JSON files, then MCP. Update the file header comments to reflect new priority order.

The local search function `knowledge_gate_search_local()` should be updated to call `store_card_search()` when SQLite is available, falling back to the existing JSON file scan.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_knowledge_local_first.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add bashclaw.json lib/knowledge_gate.sh tests/test_knowledge_local_first.sh
git commit -m "feat: wire knowledge gate to SQLite store, local-first search"
```

---

## Task 3: Wire Memory Writeback to SQLite

**Files:**
- Modify: `lib/memory_writeback.sh`

- [ ] **Step 1: Update `writeback_create()` to write cards to SQLite**

Add `store_card_insert()` call alongside existing JSON file creation. Keep JSON as backup for now.

- [ ] **Step 2: Update `writeback_merge()` to update SQLite**

Use SQL UPDATE for merge operations instead of jq file manipulation.

- [ ] **Step 3: Run existing writeback tests**

Run: `bash tests/test_memory_writeback.sh`
Expected: All existing tests still PASS

- [ ] **Step 4: Commit**

```bash
git add lib/memory_writeback.sh
git commit -m "feat: wire memory writeback to SQLite store"
```

---

## Task 4: `bashclaw stats` Command

**Files:**
- Modify: `bashclaw.sh` (add stats + init + import commands)
- Modify: `lib/audit_log.sh` (add knowledge metrics)
- Test: `tests/test_stats_command.sh`

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_stats_command.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_bashclaw() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_CONFIG="${TEST_TMP}/bashclaw.json"
  export AUDIT_LOG_DIR="${TEST_TMP}/.bashclaw/audit"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
  export BASHCLAW_LOG_LEVEL="error"
  source "${TEST_ROOT}/bashclaw.sh"
}

test_stats_command_exists() {
  _load_bashclaw
  local output
  output=$(bashclaw_main stats 2>&1) || true
  assert_not_contains "${output}" "Unknown command" "stats should be recognized"
}

test_stats_returns_json() {
  _load_bashclaw
  local output
  output=$(bashclaw_main stats 2>/dev/null) || true
  echo "${output}" | jq . > /dev/null 2>&1 || {
    echo "stats should output valid JSON, got: ${output}" >&2; return 1
  }
}

test_stats_includes_knowledge_metrics() {
  _load_bashclaw
  source "${LIB_DIR}/store.sh"
  store_init "${TEST_TMP}/.bashclaw"
  store_card_insert "Test" "test" "do X" "because Y" '["test"]' "logic_bug"
  local output
  output=$(bashclaw_main stats 2>/dev/null) || true
  local cards
  cards=$(echo "${output}" | jq -r '.active_cards // 0')
  assert_eq "1" "${cards}" "Should show 1 active card"
}

test_stats_in_usage() {
  _load_bashclaw
  local output
  output=$(bashclaw_main --help 2>&1) || true
  assert_contains "${output}" "stats" "Usage should mention stats"
}

echo "== test_stats_command.sh =="
run_test test_stats_command_exists
run_test test_stats_returns_json
run_test test_stats_includes_knowledge_metrics
run_test test_stats_in_usage
print_report "test_stats_command.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_stats_command.sh`
Expected: FAIL — `stats` not in dispatcher

- [ ] **Step 3: Add commands to `bashclaw.sh`**

Add `stats`, `init`, `import` to usage text and dispatcher. `stats` combines audit log stats + SQLite store stats into one JSON output.

- [ ] **Step 4: Enhance `audit_log_stats()` with knowledge hit metrics**

Add `knowledge_hit_tasks` and `knowledge_hit_rate` fields.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_stats_command.sh`
Expected: All 4 PASS

- [ ] **Step 6: Commit**

```bash
git add bashclaw.sh lib/audit_log.sh tests/test_stats_command.sh
git commit -m "feat: add bashclaw stats with audit + knowledge metrics"
```

---

## Task 5: Git Hooks

**Files:**
- Create: `lib/hook_helpers.sh`
- Create: `hooks/post-commit`
- Create: `hooks/pre-push`
- Modify: `bashclaw.sh` (enhance `bashclaw_init`)
- Test: `tests/test_hooks.sh`
- Test: `tests/test_init.sh`

- [ ] **Step 1: Write failing test for hook helpers**

Test `hook_tag_commit`, `hook_get_high_risk_commits`, `hook_clear_pushed_commits` functions.

- [ ] **Step 2: Implement `lib/hook_helpers.sh`**

Store commit risk tags in SQLite (new `commit_risk` table) instead of JSON file.

- [ ] **Step 3: Run test to verify it passes**

- [ ] **Step 4: Create `hooks/post-commit` and `hooks/pre-push`**

post-commit: Run risk_classifier (<1s), tag commit in SQLite.
pre-push: Query high-risk commits, run Tier 2 review, block if unresolved.

- [ ] **Step 5: Write failing test for `bashclaw init`**

Test: creates dirs, installs hooks, loads seeds into SQLite, doesn't overwrite existing cards.

- [ ] **Step 6: Enhance `bashclaw_init()` to install hooks + load seeds into SQLite**

- [ ] **Step 7: Run all tests**

- [ ] **Step 8: Commit**

```bash
git add lib/hook_helpers.sh hooks/ bashclaw.sh tests/test_hooks.sh tests/test_init.sh
git commit -m "feat: git hooks with SQLite risk tagging + bashclaw init"
```

---

## Task 6: Minimal Import Command

**Files:**
- Create: `lib/import.sh`
- Test: `tests/test_import.sh`

- [ ] **Step 1: Write failing test for Claude Code JSONL import**

```bash
# tests/test_import.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_helper.sh"

_load_import() {
  export BASHCLAW_ROOT="${TEST_TMP}"
  export BASHCLAW_DB="${TEST_TMP}/.bashclaw/bashclaw.db"
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
  import_claude_code "${TEST_TMP}/session.jsonl" "Fix auth bug"
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
  import_chatgpt "${TEST_TMP}/chatgpt.json"
  local conv_count
  conv_count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM conversations WHERE source='chatgpt'")
  assert_eq "1" "${conv_count}" "Should create 1 chatgpt conversation"
}

echo "== test_import.sh =="
run_test test_import_claude_code_jsonl
run_test test_import_chatgpt_json
print_report "test_import.sh"
```

- [ ] **Step 2: Implement `lib/import.sh`**

Two importers for Phase 1:
- `import_claude_code <file.jsonl> [title]` — JSONL format (one JSON object per line with type + text)
- `import_chatgpt <file.json>` — ChatGPT export format (nested mapping with author.role + content.parts)

Both normalize into the `conversations` + `messages` tables.

- [ ] **Step 3: Run test to verify it passes**

- [ ] **Step 4: Wire `bashclaw import` command**

Add to dispatcher:
```bash
    import)
      source "${BASHCLAW_LIB}/store.sh"
      source "${BASHCLAW_LIB}/import.sh"
      store_init ".bashclaw"
      import_dispatch "$@"
      ;;
```

- [ ] **Step 5: Commit**

```bash
git add lib/import.sh tests/test_import.sh bashclaw.sh
git commit -m "feat: add bashclaw import for Claude Code JSONL and ChatGPT JSON"
```

---

## Task 7: TypeScript Thin Entry Point

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `bin/bashclaw.ts`

- [ ] **Step 1: Create `package.json`**

Add `sqlite3` to the dependency check list in the TS entry.

- [ ] **Step 2: Create `tsconfig.json`**

- [ ] **Step 3: Create `bin/bashclaw.ts`**

Thin wrapper: preflight checks (bash, jq, sqlite3, git), then `execFileSync('bash', ['bashclaw.sh', ...args])`.

- [ ] **Step 4: Compile and test**

Run: `npm install && npx tsc && node bin/bashclaw.js --help`
Expected: Shows BashClaw usage

- [ ] **Step 5: Commit**

```bash
git add package.json tsconfig.json bin/bashclaw.ts
git commit -m "feat: add TypeScript entry point with sqlite3 preflight check"
```

---

## Task 8: Full Integration Test + Final Verification

- [ ] **Step 1: Run all existing tests**

Run: `for f in tests/test_*.sh; do bash "$f"; done`
Expected: All PASS

- [ ] **Step 2: End-to-end verification**

```bash
# 1. Init
bash bashclaw.sh init .
# Verify: .bashclaw/bashclaw.db exists, seeds loaded
sqlite3 .bashclaw/bashclaw.db "SELECT COUNT(*) FROM cards"  # → 25

# 2. Stats
bash bashclaw.sh stats  # → JSON with active_cards: 25

# 3. Import
bash bashclaw.sh import claude-code some-session.jsonl
sqlite3 .bashclaw/bashclaw.db "SELECT COUNT(*) FROM conversations"  # → 1

# 4. TS entry
node bin/bashclaw.js --help  # → usage

# 5. Hooks exist
ls hooks/post-commit hooks/pre-push  # → both present
```

- [ ] **Step 3: Commit everything**

```bash
git add -A
git commit -m "feat: BashClaw Phase 1 complete — SQLite store, stats, hooks, import, TS entry"
```
