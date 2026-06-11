#!/usr/bin/env bash
set -euo pipefail

# bashclaw.sh — Main entry point for BashClaw V1
# Orchestrates: Risk Classification → Knowledge Gate → Executor → Base Validation → Audit

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BASHCLAW_CONFIG="${BASHCLAW_CONFIG:-${BASHCLAW_ROOT}/bashclaw.json}"
BASHCLAW_LIB="${BASHCLAW_LIB:-${BASHCLAW_ROOT}/lib}"

# Source all library modules
source "${BASHCLAW_LIB}/risk_classifier.sh"
source "${BASHCLAW_LIB}/knowledge_gate.sh"
source "${BASHCLAW_LIB}/executor.sh"
source "${BASHCLAW_LIB}/validator_repo.sh"
source "${BASHCLAW_LIB}/audit_log.sh"
source "${BASHCLAW_LIB}/routing.sh"
source "${BASHCLAW_LIB}/engine.sh"

# Print usage information
bashclaw_usage() {
  cat <<'USAGE'
BashClaw V1 — Knowledge-first, evidence-driven coding workflow

Usage:
  bashclaw.sh <command> [options]

Commands:
  run <task_description>       Run a task through the full pipeline
  classify <diff_file>         Classify risk for a diff
  validate [path]              Run base validation on a repo
  audit <task_id>              Show audit log for a task
  stats                        Show knowledge + audit statistics (JSON)
  init [path]                  Initialize workspace (dirs, hooks, seeds)
  import <source> <file>       Import conversations (claude-code, chatgpt)
  config                       Show current configuration

Prefixes (prepend to task description):
  /review    Force Tier 2 (reviewed) processing
  /critical  Force Tier 3 (critical) processing

Environment:
  BASHCLAW_ENGINE_OVERRIDE     Override engine for single invocation (opus4.6|codex)
  BASHCLAW_TIER_OVERRIDE       Override tier for single invocation (1|2|3)
  BASHCLAW_LOG_LEVEL           Log verbosity (debug|info|warn|error) [default: info]
USAGE
}

# Initialize workspace directories, SQLite store, hooks, and seeds
bashclaw_init() {
  local repo_root="${1:-.}"
  mkdir -p "${repo_root}/.bashclaw/audit"
  mkdir -p "${repo_root}/.bashclaw/knowledge"
  mkdir -p "${repo_root}/.bashclaw/tmp"
  mkdir -p "${repo_root}/.bashclaw/budget"
  mkdir -p "${repo_root}/.bashclaw/issue_trace"
  mkdir -p "${repo_root}/.bashclaw/artifacts"

  # Initialize SQLite store
  if [[ -f "${BASHCLAW_LIB}/store.sh" ]]; then
    source "${BASHCLAW_LIB}/store.sh"
    export BASHCLAW_DB="${repo_root}/.bashclaw/bashclaw.db"
    store_init "${repo_root}/.bashclaw"

    # Load seed knowledge if seeds/ dir exists and DB is empty
    local card_count=0
    card_count=$(sqlite3 "${BASHCLAW_DB}" "SELECT COUNT(*) FROM cards" 2>/dev/null) || card_count=0
    if [[ "${card_count}" -eq 0 ]] && [[ -d "${BASHCLAW_ROOT}/seeds" ]]; then
      local seed_file loaded=0
      for seed_file in "${BASHCLAW_ROOT}/seeds"/*.json; do
        [[ -f "${seed_file}" ]] || continue
        store_seed_import "${seed_file}" 2>/dev/null && loaded=$((loaded + 1))
      done
      echo "Loaded ${loaded} seed knowledge cards into SQLite" >&2
    fi
  fi

  # Install git hooks if hooks/ dir exists
  if [[ -d "${BASHCLAW_ROOT}/hooks" ]] && [[ -d "${repo_root}/.git" ]]; then
    local hook_file
    for hook_file in "${BASHCLAW_ROOT}/hooks"/*; do
      [[ -f "${hook_file}" ]] || continue
      local hook_name
      hook_name="$(basename "${hook_file}")"
      local target="${repo_root}/.git/hooks/${hook_name}"
      if [[ ! -f "${target}" ]]; then
        cp "${hook_file}" "${target}"
        chmod +x "${target}"
      fi
    done
  fi
}

# Combined stats: audit log + SQLite knowledge store
bashclaw_stats() {
  local audit_stats="{}"
  local store_stats_json="{}"

  # Audit stats
  if type audit_log_stats &>/dev/null; then
    audit_stats=$(audit_log_stats 2>/dev/null) || audit_stats="{}"
  fi

  # Knowledge store stats
  if [[ -f "${BASHCLAW_LIB}/store.sh" ]]; then
    source "${BASHCLAW_LIB}/store.sh"
    if [[ -f "${BASHCLAW_DB:-}" ]]; then
      store_stats_json=$(store_stats 2>/dev/null) || store_stats_json="{}"
      # store_stats returns a JSON array with one element
      if echo "${store_stats_json}" | jq -e '.[0]' &>/dev/null; then
        store_stats_json=$(echo "${store_stats_json}" | jq '.[0]')
      fi
    fi
  fi

  # Merge both
  jq -n \
    --argjson audit "${audit_stats}" \
    --argjson knowledge "${store_stats_json}" \
    '$audit + $knowledge'
}

# Main dispatcher
bashclaw_main() {
  local command="${1:-}"

  if [[ -z "${command}" || "${command}" == "--help" || "${command}" == "-h" ]]; then
    bashclaw_usage
    return 0
  fi

  shift

  case "${command}" in
    run)
      bashclaw_init "${BASHCLAW_ROOT:-.}"
      engine_run "$@"
      ;;
    classify)
      risk_classify "$@"
      ;;
    validate)
      validator_run "$@"
      ;;
    audit)
      audit_log_show "$@"
      ;;
    stats)
      bashclaw_init "${BASHCLAW_ROOT:-.}"
      bashclaw_stats
      ;;
    init)
      bashclaw_init "${1:-${BASHCLAW_ROOT:-.}}"
      echo "BashClaw workspace initialized." >&2
      ;;
    import)
      source "${BASHCLAW_LIB}/store.sh"
      if [[ -f "${BASHCLAW_LIB}/import.sh" ]]; then
        source "${BASHCLAW_LIB}/import.sh"
      else
        echo "ERROR: import.sh not found" >&2
        return 1
      fi
      export BASHCLAW_DB="${BASHCLAW_DB:-.bashclaw/bashclaw.db}"
      store_init ".bashclaw"
      import_dispatch "$@"
      ;;
    config)
      if [[ -f "${BASHCLAW_CONFIG}" ]]; then
        cat "${BASHCLAW_CONFIG}"
      else
        echo "ERROR: Config file not found: ${BASHCLAW_CONFIG}" >&2
        return 1
      fi
      ;;
    *)
      echo "ERROR: Unknown command '${command}'" >&2
      bashclaw_usage >&2
      return 1
      ;;
  esac
}

# Run main only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bashclaw_main "$@"
fi
