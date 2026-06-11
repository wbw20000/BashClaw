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

# Allowed field names for store_card_get_field (SQL injection prevention)
_STORE_CARD_FIELDS="id title scope decision why pitfalls evidence risk_tags issue_type change_type superseded_by merge_count created_at updated_at"

# Check sqlite3 is available
_store_check_sqlite() {
  if ! command -v sqlite3 &>/dev/null; then
    echo "ERROR: sqlite3 is required. Install it: https://sqlite.org/download.html" >&2
    return 1
  fi
}

# Escape single quotes for SQL string literals
_store_escape() {
  echo "$1" | sed "s/'/''/g"
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

  local schema_file="${BASHCLAW_LIB:-${BASHCLAW_ROOT}/lib}/store_schema.sql"
  if [[ -f "${schema_file}" ]]; then
    _store_sql < "${schema_file}" >/dev/null
  fi
}

# Generate a unique ID: PREFIX-YYYYMMDD-HHMMSS-RANDOM
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
VALUES ('${card_id}', '$(_store_escape "${title}")', '$(_store_escape "${scope}")', '$(_store_escape "${decision}")', '$(_store_escape "${why}")', '$(_store_escape "${risk_tags}")', '$(_store_escape "${issue_type}")');
SQL

  echo "${card_id}"
}

# Get a single field from a card
store_card_get_field() {
  local card_id="$1"
  local field="$2"

  # Validate field against allowlist (SQL injection prevention)
  if ! echo " ${_STORE_CARD_FIELDS} " | grep -q " ${field} "; then
    echo "ERROR: Invalid field name: ${field}" >&2
    return 1
  fi

  local safe_id
  safe_id="$(_store_escape "${card_id}")"
  _store_sql "SELECT ${field} FROM cards WHERE id='${safe_id}'"
}

# Search cards using FTS5
# Args: query_string
# Output: JSON array of matching cards
# Note: Uses OR between terms for broad recall (knowledge gate sends composite queries)
store_card_search() {
  local query="$1"
  local limit="${2:-10}"
  # Validate limit as integer (SQL injection prevention for numeric params)
  limit="${limit//[!0-9]/}"
  [[ -z "${limit}" ]] && limit=10

  # Sanitize for FTS5: strip special operators, escape quotes, then OR-join terms
  local safe_query
  safe_query="$(echo "${query}" | sed 's/[\"()*^]//g' | sed "s/'/''/g" | tr -s ' ')"
  # Remove FTS5 boolean keywords that could break the query
  safe_query="$(echo " ${safe_query} " | sed 's/ AND / /gi; s/ OR / /gi; s/ NOT / /gi; s/ NEAR / /gi' | tr -s ' ' | sed 's/^ //; s/ $//')"
  # Join remaining terms with OR
  safe_query="$(echo "${safe_query}" | sed 's/ / OR /g')"

  # Bail out if query is empty after sanitization
  [[ -z "${safe_query}" ]] && { echo "[]"; return 0; }

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
  limit="${limit//[!0-9]/}"
  [[ -z "${limit}" ]] && limit=10

  local safe_query
  safe_query="$(_store_escape "${query}")"

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
VALUES ('${conv_id}', '$(_store_escape "${source}")', '$(_store_escape "${title}")', '$(_store_escape "${external_id}")');
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
  seq="${seq//[!0-9]/}"
  [[ -z "${seq}" ]] && seq=0

  local msg_id
  msg_id="$(_store_gen_id "MG-")"

  _store_sql <<SQL
INSERT INTO messages (id, conversation_id, role, content, seq)
VALUES ('${msg_id}', '$(_store_escape "${conv_id}")', '$(_store_escape "${role}")', '$(_store_escape "${content}")', ${seq});
UPDATE conversations SET message_count = message_count + 1 WHERE id = '$(_store_escape "${conv_id}")';
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
VALUES ('$(_store_escape "${card_id}")', '$(_store_escape "${conv_id}")', '$(_store_escape "${msg_range}")');
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
  if ! command -v sqlite3 &>/dev/null || [[ ! -f "${BASHCLAW_DB}" ]]; then
    echo '[{"active_cards":0,"superseded_cards":0,"total_conversations":0,"total_messages":0,"source_count":0}]'
    return 0
  fi
  _store_sql -json <<SQL
SELECT
  (SELECT COUNT(*) FROM cards WHERE superseded_by IS NULL) as active_cards,
  (SELECT COUNT(*) FROM cards WHERE superseded_by IS NOT NULL) as superseded_cards,
  (SELECT COUNT(*) FROM conversations) as total_conversations,
  (SELECT COUNT(*) FROM messages) as total_messages,
  (SELECT COUNT(DISTINCT source) FROM conversations) as source_count;
SQL
}
