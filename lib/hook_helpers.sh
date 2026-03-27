#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# hook_helpers.sh — Shared logic for BashClaw git hooks
#
# Stores commit risk tags in SQLite (commit_risk table).
# Used by post-commit (tag) and pre-push (gate).
###############################################################################

[[ -n "${_HOOK_HELPERS_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_HOOK_HELPERS_SH_LOADED=1

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Source store
if [[ -f "${BASHCLAW_ROOT}/lib/store.sh" ]]; then
  source "${BASHCLAW_ROOT}/lib/store.sh"
fi

# Ensure commit_risk table exists
_hook_ensure_schema() {
  local db="${BASHCLAW_DB:-}"
  [[ -f "${db}" ]] || return 1

  sqlite3 "${db}" <<'SQL'
CREATE TABLE IF NOT EXISTS commit_risk (
  commit_hash TEXT PRIMARY KEY,
  risk_level  TEXT NOT NULL DEFAULT 'low',  -- low, medium, high
  risk_tags   TEXT NOT NULL DEFAULT '[]',   -- JSON array
  reviewed    INTEGER NOT NULL DEFAULT 0,   -- 0=unreviewed, 1=reviewed
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
SQL
}

# Tag a commit with risk level
# Args: commit_hash risk_level risk_tags_json
hook_tag_commit() {
  local commit_hash="$1"
  local risk_level="${2:-low}"
  local risk_tags="${3:-[]}"

  _hook_ensure_schema || return 1

  sqlite3 "${BASHCLAW_DB}" <<SQL
INSERT OR REPLACE INTO commit_risk (commit_hash, risk_level, risk_tags)
VALUES ('${commit_hash}', '${risk_level}', '$(echo "${risk_tags}" | sed "s/'/''/g")');
SQL
}

# Get unreviewed high-risk commits
# Output: JSON array of {commit_hash, risk_level, risk_tags}
hook_get_high_risk_commits() {
  _hook_ensure_schema || { echo "[]"; return 0; }

  local result
  result=$(sqlite3 "${BASHCLAW_DB}" -json \
    "SELECT commit_hash, risk_level, risk_tags FROM commit_risk WHERE risk_level IN ('medium','high') AND reviewed=0" 2>/dev/null) || true
  echo "${result:-[]}"
}

# Mark commits as reviewed (after push)
hook_clear_pushed_commits() {
  _hook_ensure_schema || return 0
  sqlite3 "${BASHCLAW_DB}" "UPDATE commit_risk SET reviewed=1 WHERE reviewed=0" 2>/dev/null || true
}

# Classify commit risk from diff
# Args: commit_hash
# Output: risk_level (low/medium/high)
hook_classify_commit() {
  local commit_hash="$1"
  local diff_content
  diff_content=$(git diff "${commit_hash}^" "${commit_hash}" 2>/dev/null) || diff_content=""

  local risk_level="low"
  local -a found_tags=()

  # Check against risk keywords from config
  local risk_keywords="auth permission oauth token secret payment billing deploy migration schema prod acl"
  for kw in ${risk_keywords}; do
    if echo "${diff_content}" | grep -qi "${kw}" 2>/dev/null; then
      found_tags+=("${kw}")
    fi
  done

  if [[ ${#found_tags[@]} -ge 3 ]]; then
    risk_level="high"
  elif [[ ${#found_tags[@]} -ge 1 ]]; then
    risk_level="medium"
  fi

  # Build tags JSON
  local tags_json="[]"
  if [[ ${#found_tags[@]} -gt 0 ]]; then
    tags_json="["
    local first=true
    for t in "${found_tags[@]}"; do
      ${first} || tags_json="${tags_json},"
      tags_json="${tags_json}\"${t}\""
      first=false
    done
    tags_json="${tags_json}]"
  fi

  echo "${risk_level}|${tags_json}"
}
