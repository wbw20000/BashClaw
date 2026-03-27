#!/usr/bin/env bash
set -euo pipefail

# bashclaw.sh — Main entry point for BashClaw V1
# Orchestrates: Risk Classification → Knowledge Gate → Executor → Base Validation → Audit

BASHCLAW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_CONFIG="${BASHCLAW_ROOT}/bashclaw.json"
BASHCLAW_LIB="${BASHCLAW_ROOT}/lib"

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

# Initialize workspace directories
bashclaw_init() {
  local repo_root="${1:-.}"
  mkdir -p "${repo_root}/.bashclaw/audit"
  mkdir -p "${repo_root}/.bashclaw/knowledge"
  mkdir -p "${repo_root}/.bashclaw/tmp"
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
      bashclaw_init "."
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
