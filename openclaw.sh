#!/usr/bin/env bash
set -euo pipefail

# openclaw.sh — Main entry point for OpenClaw
# Agent-oriented orchestration platform sharing BashClaw's core logic.
#
# Provides:
#   - Agent coordination (register, list, coordinate)
#   - Knowledge search (MCP + local)
#   - Long-chain task context management
#   - Task decomposition
#   - Cross-task memory reuse
#   - Full BashClaw pipeline (risk → knowledge gate → execute → validate → audit)
#
# Reference: BashClaw/OpenClaw V1 统一实施与验证文档 第3节

OPENCLAW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_CONFIG="${OPENCLAW_ROOT}/openclaw.json"
OPENCLAW_LIB="${OPENCLAW_ROOT}/lib"

# Source the OpenClaw adapter (which in turn sources all BashClaw core modules)
source "${OPENCLAW_LIB}/openclaw_adapter.sh"

# Source the main BashClaw engine for shared pipeline execution
source "${OPENCLAW_LIB}/engine.sh"

# Print usage information
openclaw_usage() {
  cat <<'USAGE'
OpenClaw — Agent-oriented, knowledge-first workflow platform

Shares BashClaw's core logic: risk classification, Knowledge Gate,
evidence-driven resolution, human escalation, memory writeback.

Usage:
  openclaw.sh <command> [options]

Commands:
  run <task_description>         Run a task through the full pipeline
  classify <diff_file>           Classify risk for a diff
  validate [path]                Run base validation on a repo
  audit <task_id>                Show audit log for a task
  config                         Show current configuration

Agent Commands:
  agent register <id> <role> [engine]   Register an agent
  agent list                            List registered agents
  agent coordinate <task_id> <desc> [tier]  Generate coordination plan

Knowledge Commands:
  knowledge search <query>       Search knowledge base (MCP + local)
  knowledge save <json_file>     Save a knowledge entry

Context Commands:
  context create <chain_id> <description>    Create a long-chain context
  context get <chain_id>                     Get context details
  context list                               List all contexts
  context add-task <chain_id> <task_id> <summary> [status]  Append task

Task Decomposition:
  decompose <parent_id> <description> <subtasks_json>  Decompose a task
  subtask update <parent_id> <sub_id> <status> [summary]  Update subtask
  chain get <parent_id>                                Get task chain

Memory Commands:
  memory search <query>          Cross-task memory search
  memory promote <chain_id> [index]  Promote chain knowledge to global

Prefixes (prepend to task description):
  /review    Force Tier 2 (reviewed) processing
  /critical  Force Tier 3 (critical) processing

Environment:
  BASHCLAW_ENGINE_OVERRIDE       Override engine (opus4.6|codex)
  BASHCLAW_TIER_OVERRIDE         Override tier (1|2|3)
  BASHCLAW_LOG_LEVEL             Log verbosity (debug|info|warn|error)
  OPENCLAW_MCP_ENDPOINT          MCP Server endpoint URL
USAGE
}

# Initialize workspace directories
openclaw_init_workspace() {
  local repo_root="${1:-.}"
  # BashClaw directories
  mkdir -p "${repo_root}/.bashclaw/audit"
  mkdir -p "${repo_root}/.bashclaw/knowledge"
  mkdir -p "${repo_root}/.bashclaw/tmp"
  # OpenClaw directories
  openclaw_init
}

# Override platform name in engine output
openclaw_run() {
  local input="${*}"

  if [[ -z "${input}" ]]; then
    echo "ERROR: No task description provided" >&2
    return 1
  fi

  openclaw_log "info" "Starting OpenClaw pipeline"

  # === Step 1: Parse routing prefix ===
  routing_parse_prefix "${input}"
  local prefix_tier="${ROUTING_TIER}"
  local task_command="${ROUTING_COMMAND}"
  openclaw_log "info" "Prefix parsed: tier=${prefix_tier}, command='${task_command}'"

  # === Step 2: Get changed files from git ===
  local -a changed_files=()
  local diff_file=""
  if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    while IFS= read -r f; do
      [[ -n "${f}" ]] && changed_files+=("${f}")
    done < <(git diff --name-only HEAD 2>/dev/null || true)

    diff_file="$(mktemp -t openclaw_diff.XXXXXX 2>/dev/null || echo ".bashclaw/tmp/diff_$$.txt")"
    git diff HEAD > "${diff_file}" 2>/dev/null || true
  fi

  # === Step 3: Risk Classification ===
  openclaw_log "info" "Running risk classification"
  local risk_result=""
  if [[ ${#changed_files[@]} -gt 0 ]]; then
    local classify_args=("--files" "${changed_files[@]}")
    [[ -n "${diff_file}" && -f "${diff_file}" ]] && classify_args+=("--diff" "${diff_file}")
    risk_result="$(risk_classify "${classify_args[@]}")"
  else
    risk_result='{"tier_suggestion":1,"risk_tags":[],"change_type":"logic_change","file_count":0,"risk_tag_count":0}'
  fi

  local risk_tier=1
  local change_type="logic_change"
  local risk_tags=""
  if command -v jq &>/dev/null; then
    risk_tier="$(echo "${risk_result}" | jq -r '.tier_suggestion // 1')"
    change_type="$(echo "${risk_result}" | jq -r '.change_type // "logic_change"')"
    risk_tags="$(echo "${risk_result}" | jq -r '.risk_tags | join(",") // ""')"
  else
    risk_tier="$(echo "${risk_result}" | grep -oP '"tier_suggestion"\s*:\s*\K[0-9]+' || echo "1")"
    change_type="$(echo "${risk_result}" | grep -oP '"change_type"\s*:\s*"\K[^"]+' || echo "logic_change")"
  fi

  openclaw_log "info" "Risk classification: tier=${risk_tier}, type=${change_type}, tags=${risk_tags}"

  # === Step 4: Resolve effective tier ===
  local effective_tier
  effective_tier="$(routing_resolve_tier "${prefix_tier}" "${risk_tier}")"
  local tier_name
  tier_name="$(routing_tier_name "${effective_tier}")"
  openclaw_log "info" "Effective tier: ${effective_tier} (${tier_name})"

  # === Step 5: Generate task ID and init audit ===
  local task_id
  task_id="$(audit_generate_task_id)"
  openclaw_log "info" "Task ID: ${task_id}"

  # === Step 6: Knowledge Gate (with MCP search) ===
  local knowledge_result='{"knowledge_gate":"skipped"}'
  if knowledge_gate_required "${effective_tier}"; then
    openclaw_log "info" "Running Knowledge Gate (tier ${effective_tier} requires it)"

    # OpenClaw enhancement: also search MCP
    local mcp_results=""
    mcp_results="$(knowledge_search_mcp "${task_command}" 3 2>/dev/null)" || mcp_results="[]"

    knowledge_result="$(knowledge_gate_run \
      "${task_command}" \
      "${task_command}" \
      "${change_type}" \
      "$(IFS=','; echo "${changed_files[*]+"${changed_files[*]}"}")" \
      "${risk_tags}" \
      "" \
      "" \
      "${effective_tier}")"
    openclaw_log "info" "Knowledge Gate complete"
  else
    openclaw_log "info" "Knowledge Gate skipped (tier ${effective_tier})"
  fi

  # Extract knowledge info
  local knowledge_confidence="low"
  local knowledge_hits=""
  local knowledge_hit_count=0
  if command -v jq &>/dev/null; then
    knowledge_confidence="$(echo "${knowledge_result}" | jq -r '.confidence // "low"')"
    knowledge_hits="$(echo "${knowledge_result}" | jq -r '.similar_decisions | join(",") // ""' 2>/dev/null || echo "")"
    knowledge_hit_count="$(echo "${knowledge_result}" | jq -r '.hit_count // 0' 2>/dev/null || echo "0")"
  fi

  # === Step 7: Executor ===
  openclaw_log "info" "Running executor"
  local executor_result
  executor_result="$(executor_run \
    "${task_command}" \
    "${effective_tier}" \
    "${knowledge_result}" \
    "${change_type}" \
    "${risk_tags}" \
    "low")"

  local executor_engine="opus4.6"
  if command -v jq &>/dev/null; then
    executor_engine="$(echo "${executor_result}" | jq -r '.executor.engine // "opus4.6"')"
  fi
  openclaw_log "info" "Executor complete (engine: ${executor_engine})"

  # === Step 8: Base Validation ===
  openclaw_log "info" "Running base validation"
  local validation_result
  validation_result="$(validator_run "." "${change_type}")"

  local validation_status="PASS"
  local validation_results_json="[]"
  if command -v jq &>/dev/null; then
    validation_status="$(echo "${validation_result}" | jq -r '.validation.status // "PASS"')"
    validation_results_json="$(echo "${validation_result}" | jq -c '.validation.results // []')"
  fi
  openclaw_log "info" "Validation status: ${validation_status}"

  # === Step 9: Determine final status ===
  local final_status="PENDING"
  local resolved="false"

  if [[ "${effective_tier}" == "1" ]]; then
    if [[ "${validation_status}" == "PASS" ]]; then
      final_status="DELIVERED"
      resolved="true"
    else
      final_status="FAILED_VALIDATION"
      resolved="false"
    fi
  else
    final_status="AWAITING_REVIEW"
    resolved="false"
  fi

  # === Step 10: Write audit log ===
  openclaw_log "info" "Writing audit log"
  local log_file
  log_file="$(audit_log_write \
    "${task_id}" \
    "openclaw" \
    "$(routing_tier_name "${prefix_tier}")" \
    "${tier_name}" \
    "${executor_engine}" \
    "" \
    "${#changed_files[@]}" \
    "0" \
    "${change_type}" \
    "${risk_tags}" \
    "${knowledge_hits}" \
    "${knowledge_confidence}" \
    "false" \
    "${validation_results_json}" \
    "0" \
    "0" \
    "0" \
    "0" \
    "0" \
    "[]" \
    "false" \
    "" \
    "none" \
    "${final_status}" \
    "${resolved}" \
    "0")"

  # === Output: unified schema with BashClaw ===
  openclaw_format_result \
    "${task_id}" \
    "$(routing_tier_name "${prefix_tier}")" \
    "${tier_name}" \
    "${risk_result}" \
    "${knowledge_result}" \
    "${executor_engine}" \
    "${validation_status}" \
    "${final_status}" \
    "${resolved}" \
    "${log_file}"

  # Cleanup temp files
  [[ -n "${diff_file}" && -f "${diff_file}" ]] && rm -f "${diff_file}" 2>/dev/null || true

  openclaw_log "info" "Pipeline complete: ${final_status}"
}

# Logging utility
openclaw_log() {
  local level="$1"
  local message="$2"
  local log_level="${BASHCLAW_LOG_LEVEL:-info}"

  local -A level_priority=([debug]=0 [info]=1 [warn]=2 [error]=3)
  local msg_priority="${level_priority[${level}]:-1}"
  local threshold="${level_priority[${log_level}]:-1}"

  if [[ ${msg_priority} -ge ${threshold} ]]; then
    echo "[openclaw:${level}] ${message}" >&2
  fi
}

# Main dispatcher
openclaw_main() {
  local command="${1:-}"

  if [[ -z "${command}" || "${command}" == "--help" || "${command}" == "-h" ]]; then
    openclaw_usage
    return 0
  fi

  shift

  case "${command}" in
    run)
      openclaw_init_workspace "."
      openclaw_run "$@"
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
      if [[ -f "${OPENCLAW_CONFIG}" ]]; then
        cat "${OPENCLAW_CONFIG}"
      elif [[ -f "${OPENCLAW_ROOT}/bashclaw.json" ]]; then
        echo "[openclaw] Using bashclaw.json (no openclaw.json found)" >&2
        cat "${OPENCLAW_ROOT}/bashclaw.json"
      else
        echo "ERROR: Config file not found" >&2
        return 1
      fi
      ;;

    # ── Agent commands ──
    agent)
      local subcmd="${1:-}"
      shift || true
      case "${subcmd}" in
        register)
          agent_register "$@"
          ;;
        list)
          agent_list
          ;;
        coordinate)
          agent_coordinate "$@"
          ;;
        *)
          echo "ERROR: Unknown agent command '${subcmd}'" >&2
          echo "Usage: openclaw.sh agent {register|list|coordinate}" >&2
          return 1
          ;;
      esac
      ;;

    # ── Knowledge commands ──
    knowledge)
      local subcmd="${1:-}"
      shift || true
      case "${subcmd}" in
        search)
          knowledge_search_mcp "$@"
          ;;
        save)
          local file="${1:-}"
          if [[ -z "${file}" || ! -f "${file}" ]]; then
            echo "ERROR: Knowledge JSON file required" >&2
            return 1
          fi
          knowledge_save_mcp "$(cat "${file}")"
          ;;
        *)
          echo "ERROR: Unknown knowledge command '${subcmd}'" >&2
          echo "Usage: openclaw.sh knowledge {search|save}" >&2
          return 1
          ;;
      esac
      ;;

    # ── Context commands ──
    context)
      local subcmd="${1:-}"
      shift || true
      case "${subcmd}" in
        create)
          context_create "$@"
          ;;
        get)
          context_get "$@"
          ;;
        list)
          context_list
          ;;
        add-task)
          context_append_task "$@"
          ;;
        *)
          echo "ERROR: Unknown context command '${subcmd}'" >&2
          echo "Usage: openclaw.sh context {create|get|list|add-task}" >&2
          return 1
          ;;
      esac
      ;;

    # ── Task decomposition commands ──
    decompose)
      task_decompose "$@"
      ;;
    subtask)
      local subcmd="${1:-}"
      shift || true
      case "${subcmd}" in
        update)
          task_update_subtask "$@"
          ;;
        *)
          echo "ERROR: Unknown subtask command '${subcmd}'" >&2
          echo "Usage: openclaw.sh subtask update <parent_id> <sub_id> <status> [summary]" >&2
          return 1
          ;;
      esac
      ;;
    chain)
      local subcmd="${1:-}"
      shift || true
      case "${subcmd}" in
        get)
          task_get_chain "$@"
          ;;
        *)
          echo "ERROR: Unknown chain command '${subcmd}'" >&2
          echo "Usage: openclaw.sh chain get <parent_id>" >&2
          return 1
          ;;
      esac
      ;;

    # ── Memory commands ──
    memory)
      local subcmd="${1:-}"
      shift || true
      case "${subcmd}" in
        search)
          memory_cross_task_search "$@"
          ;;
        promote)
          memory_promote_to_global "$@"
          ;;
        *)
          echo "ERROR: Unknown memory command '${subcmd}'" >&2
          echo "Usage: openclaw.sh memory {search|promote}" >&2
          return 1
          ;;
      esac
      ;;

    *)
      echo "ERROR: Unknown command '${command}'" >&2
      openclaw_usage >&2
      return 1
      ;;
  esac
}

# Run main only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  openclaw_main "$@"
fi
