#!/usr/bin/env bash
set -euo pipefail

# engine.sh — Three-tier routing main entry point for BashClaw V1
# Orchestrates the full pipeline: Risk Classification → Routing → Knowledge Gate
#   → Executor → Base Validation → Audit Logging
# Integrates risk classification auto-upgrade.
# P1修复：Tier 2/3 自动链接到对应的编排引擎
# Reference: 统一实施文档 第5-6节

# P1修复：延迟加载 Tier 2/3 编排引擎，仅在实际路由到对应 tier 时 source
# 避免在 engine.sh 加载时就引入所有深层依赖（human_escalation, budget 等）
BASHCLAW_ENGINE_DIR="${BASHCLAW_ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Run the full BashClaw engine pipeline
engine_run() {
  local input="${*}"
  local log_level="${BASHCLAW_LOG_LEVEL:-info}"

  if [[ -z "${input}" ]]; then
    echo "ERROR: No task description provided" >&2
    return 1
  fi

  # === 特殊命令处理 ===
  case "${input}" in
    /exit|/quit|/cancel)
      cat <<'EXITMSG'
{"status":"EXIT","message":"BashClaw session ended. Send any message to start a new task."}
EXITMSG
      return 0
      ;;
    /review|/critical)
      # 空命令提示用户补充内容
      local mode_name="Review"
      local mode_desc="Tier 2 复核模式（Knowledge Gate + 证据裁决）"
      [[ "${input}" == "/critical" ]] && mode_name="Critical" && mode_desc="Tier 3 高风险审查（完整链路 + 人工升级）"
      cat <<PROMPT
{"status":"AWAITING_INPUT","mode":"${mode_name}","message":"已进入 ${mode_name} 模式 — ${mode_desc}。请描述你的任务：","hint":"例如: ${input} 修复 auth token 刷新时的跨租户边界校验","commands":["/review <task>","/critical <task>","/exit 退出当前模式"]}
PROMPT
      return 0
      ;;
  esac

  engine_log "info" "Starting BashClaw engine pipeline"

  # === Step 1: Parse routing prefix ===
  routing_parse_prefix "${input}"
  local prefix_tier="${ROUTING_TIER}"
  local task_command="${ROUTING_COMMAND}"
  engine_log "info" "Prefix parsed: tier=${prefix_tier}, command='${task_command}'"

  # === Step 2: Get changed files from git ===
  local -a changed_files=()
  local diff_file=""
  if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    while IFS= read -r f; do
      [[ -n "${f}" ]] && changed_files+=("${f}")
    done < <(git diff --name-only HEAD 2>/dev/null || true)

    # Create temp diff file for risk analysis
    diff_file="$(mktemp -t bashclaw_diff.XXXXXX 2>/dev/null || echo ".bashclaw/tmp/diff_$$.txt")"
    git diff HEAD > "${diff_file}" 2>/dev/null || true
  fi

  # === Step 3: Risk Classification (Section 16) ===
  engine_log "info" "Running risk classification"
  local risk_result=""
  if [[ ${#changed_files[@]} -gt 0 ]]; then
    local classify_args=("--files" "${changed_files[@]}")
    [[ -n "${diff_file}" && -f "${diff_file}" ]] && classify_args+=("--diff" "${diff_file}")
    risk_result="$(risk_classify "${classify_args[@]}")"
  else
    risk_result='{"tier_suggestion":1,"risk_tags":[],"change_type":"logic_change","file_count":0,"risk_tag_count":0}'
  fi

  # Extract risk classification results
  local risk_tier=1
  local change_type="logic_change"
  local risk_tags=""
  if command -v jq &>/dev/null; then
    risk_tier="$(echo "${risk_result}" | jq -r '.tier_suggestion // 1')"
    change_type="$(echo "${risk_result}" | jq -r '.change_type // "logic_change"')"
    risk_tags="$(echo "${risk_result}" | jq -r '.risk_tags | join(",") // ""')"
  else
    # Fallback: basic parsing
    risk_tier="$(echo "${risk_result}" | grep -oP '"tier_suggestion"\s*:\s*\K[0-9]+' || echo "1")"
    change_type="$(echo "${risk_result}" | grep -oP '"change_type"\s*:\s*"\K[^"]+' || echo "logic_change")"
  fi

  engine_log "info" "Risk classification: tier=${risk_tier}, type=${change_type}, tags=${risk_tags}"

  # === Step 4: Resolve effective tier (auto-upgrade from risk) ===
  local effective_tier
  effective_tier="$(routing_resolve_tier "${prefix_tier}" "${risk_tier}")"
  local tier_name
  tier_name="$(routing_tier_name "${effective_tier}")"
  engine_log "info" "Effective tier: ${effective_tier} (${tier_name})"

  # === Step 5: Generate task ID and init audit ===
  local task_id
  task_id="$(audit_generate_task_id)"
  engine_log "info" "Task ID: ${task_id}"

  # === Step 6: Knowledge Gate (Section 7) ===
  local knowledge_result='{"knowledge_gate":"skipped"}'
  if knowledge_gate_required "${effective_tier}"; then
    engine_log "info" "Running Knowledge Gate (tier ${effective_tier} requires it)"
    knowledge_result="$(knowledge_gate_run \
      "${task_command}" \
      "${task_command}" \
      "${change_type}" \
      "$(IFS=','; echo "${changed_files[*]+"${changed_files[*]}"}")" \
      "${risk_tags}" \
      "" \
      "" \
      "${effective_tier}")"
    engine_log "info" "Knowledge Gate complete"
  else
    engine_log "info" "Knowledge Gate skipped (tier ${effective_tier})"
  fi

  # Extract knowledge info for audit
  local knowledge_confidence="low"
  local knowledge_hits=""
  local knowledge_hit_count=0
  if command -v jq &>/dev/null; then
    knowledge_confidence="$(echo "${knowledge_result}" | jq -r '.confidence // "low"')"
    knowledge_hits="$(echo "${knowledge_result}" | jq -r '.similar_decisions | join(",") // ""' 2>/dev/null || echo "")"
    knowledge_hit_count="$(echo "${knowledge_result}" | jq -r '.hit_count // 0' 2>/dev/null || echo "0")"
  fi

  # === Step 7: Executor (Section 8) ===
  engine_log "info" "Running executor"
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
  engine_log "info" "Executor complete (engine: ${executor_engine})"

  # === Step 8: Base Validation (Section 9) ===
  engine_log "info" "Running base validation"
  local validation_result
  validation_result="$(validator_run "." "${change_type}")"

  local validation_status="PASS"
  local validation_results_json="[]"
  if command -v jq &>/dev/null; then
    validation_status="$(echo "${validation_result}" | jq -r '.validation.status // "PASS"')"
    validation_results_json="$(echo "${validation_result}" | jq -c '.validation.results // []')"
  fi
  engine_log "info" "Validation status: ${validation_status}"

  # === Step 8.5: 检查 executor 是否实际产生了代码变更 (Critical #1 修复) ===
  # 防止 executor 只返回模型文本但未修改任何代码的静默假成功。
  # 同时检查 executor 输出中的 files_modified 标记和实际 git diff。
  local executor_files_modified="false"
  if command -v jq &>/dev/null; then
    executor_files_modified="$(echo "${executor_result}" | jq -r '.executor.files_modified // false' 2>/dev/null || echo "false")"
  fi

  # 双重验证：即使 executor 声称有变更，也检查 git diff 是否真的有变更
  local repo_has_changes="false"
  if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    local actual_diff
    actual_diff="$(git diff HEAD 2>/dev/null || true)"
    if [[ -n "${actual_diff}" ]]; then
      repo_has_changes="true"
    fi
  fi
  engine_log "info" "Change detection: executor_files_modified=${executor_files_modified}, repo_has_changes=${repo_has_changes}"

  # === Step 9: Determine final status for Tier 1 ===
  local final_status="PENDING"
  local resolved="false"

  if [[ "${effective_tier}" == "1" ]]; then
    # Critical #1 修复：Tier 1 交付前必须确认有实际代码变更
    # 如果 executor 声称完成但 git diff 为空，不应标记为 DELIVERED
    if [[ "${validation_status}" == "PASS" && "${repo_has_changes}" == "true" ]]; then
      final_status="DELIVERED"
      resolved="true"
    elif [[ "${validation_status}" == "PASS" && "${repo_has_changes}" == "false" ]]; then
      # executor 执行通过验证但没有任何代码变更 — 静默假成功
      final_status="COMPLETED_NO_CHANGES"
      resolved="false"
      engine_log "warn" "Executor completed but no code changes detected (git diff empty). Marking as COMPLETED_NO_CHANGES instead of DELIVERED."
    else
      final_status="FAILED_VALIDATION"
      resolved="false"
    fi
  elif [[ "${effective_tier}" == "2" ]]; then
    # P1修复：Tier 2 自动调用 run_tier2_reviewed 编排引擎（来自 lib/engine_reviewed.sh）
    # 延迟加载：仅在路由到 Tier 2 时 source engine_reviewed.sh
    if ! type run_tier2_reviewed &>/dev/null && [[ -f "${BASHCLAW_ENGINE_DIR}/engine_reviewed.sh" ]]; then
      # shellcheck source=/dev/null
      source "${BASHCLAW_ENGINE_DIR}/engine_reviewed.sh" 2>/dev/null || true
    fi
    if type run_tier2_reviewed &>/dev/null; then
      engine_log "info" "Tier 2: 调用 run_tier2_reviewed 编排引擎"
      local tier2_result
      local tier2_code=0
      # run_tier2_reviewed 的 stdout 为完整 Tier 2 结果 JSON，捕获到变量中
      tier2_result=$(run_tier2_reviewed "${task_command}" "." 2>/dev/null) || tier2_code=$?
      if [[ ${tier2_code} -eq 0 ]]; then
        # Critical #1 修复：检查 Tier 2 结果是否包含 COMPLETED_NO_CHANGES
        # 如果 Tier 2 流程本身已标记为无变更，不应在此覆盖为 DELIVERED
        local tier2_status=""
        if command -v jq &>/dev/null && [[ -n "${tier2_result}" ]]; then
          tier2_status="$(echo "${tier2_result}" | jq -r '.status // ""' 2>/dev/null || echo "")"
        fi
        if [[ "${tier2_status}" == "COMPLETED_NO_CHANGES" ]]; then
          final_status="COMPLETED_NO_CHANGES"
          resolved="false"
          engine_log "warn" "Tier 2 completed but no code changes detected. Marking as COMPLETED_NO_CHANGES."
        else
          final_status="DELIVERED"
          resolved="true"
        fi
      elif [[ ${tier2_code} -eq 1 ]]; then
        final_status="NEEDS_HUMAN_ESCALATION"
        resolved="false"
      else
        final_status="FAILED_TIER2"
        resolved="false"
      fi
    else
      final_status="AWAITING_REVIEW"
      resolved="false"
    fi
  elif [[ "${effective_tier}" == "3" ]]; then
    # P1修复：Tier 3 自动调用 engine_critical_run 编排引擎（来自 lib/engine_critical.sh）
    # 延迟加载：仅在路由到 Tier 3 时 source engine_critical.sh
    if ! type engine_critical_run &>/dev/null && [[ -f "${BASHCLAW_ENGINE_DIR}/engine_critical.sh" ]]; then
      # shellcheck source=/dev/null
      source "${BASHCLAW_ENGINE_DIR}/engine_critical.sh" 2>/dev/null || true
    fi
    if type engine_critical_run &>/dev/null; then
      engine_log "info" "Tier 3: 调用 engine_critical_run 编排引擎"
      local tier3_code=0
      # engine_critical_run 在 stdout 输出流程信息，需要抑制以免污染 engine_run 的 JSON 输出
      engine_critical_run "${task_id}" "${task_command}" >/dev/null 2>/dev/null || tier3_code=$?
      if [[ ${tier3_code} -eq 0 ]]; then
        # Critical #1 修复：Tier 3 交付前也需确认有实际代码变更
        if [[ "${repo_has_changes}" == "true" ]]; then
          final_status="DELIVERED"
          resolved="true"
        else
          final_status="COMPLETED_NO_CHANGES"
          resolved="false"
          engine_log "warn" "Tier 3 completed but no code changes detected. Marking as COMPLETED_NO_CHANGES."
        fi
      else
        final_status="AWAITING_HUMAN_DECISION"
        resolved="false"
      fi
    else
      final_status="AWAITING_REVIEW"
      resolved="false"
    fi
  else
    # 未知 tier: 回退到待审查
    final_status="AWAITING_REVIEW"
    resolved="false"
  fi

  # === Step 10: Write audit log (Section 26) ===
  engine_log "info" "Writing audit log"
  local log_file
  log_file="$(audit_log_write \
    "${task_id}" \
    "bashclaw" \
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

  # === Output final result ===
  # 修复 High #5: 使用 jq -n --arg 安全构造 JSON，避免手工拼接导致的注入和格式错误
  local tier_requested_name
  tier_requested_name="$(routing_tier_name "${prefix_tier}")"
  jq -n \
    --arg task_id "${task_id}" \
    --arg tier_requested "${tier_requested_name}" \
    --arg tier_effective "${tier_name}" \
    --argjson risk_classification "${risk_result}" \
    --argjson knowledge_gate "${knowledge_result}" \
    --arg executor_engine "${executor_engine}" \
    --arg validation_status "${validation_status}" \
    --arg final_status "${final_status}" \
    --argjson resolved "${resolved}" \
    --arg audit_log "${log_file}" \
    '{
      task_id: $task_id,
      tier_requested: $tier_requested,
      tier_effective: $tier_effective,
      risk_classification: $risk_classification,
      knowledge_gate: $knowledge_gate,
      executor: {
        engine: $executor_engine,
        status: "completed"
      },
      validation: {
        status: $validation_status
      },
      final_status: $final_status,
      resolved: $resolved,
      audit_log: $audit_log
    }'

  # Cleanup temp files
  [[ -n "${diff_file}" && -f "${diff_file}" ]] && rm -f "${diff_file}" 2>/dev/null || true

  engine_log "info" "Pipeline complete: ${final_status}"
}

# Simple logging utility
engine_log() {
  local level="$1"
  local message="$2"
  local log_level="${BASHCLAW_LOG_LEVEL:-info}"

  # Log level priority: debug=0, info=1, warn=2, error=3
  local -A level_priority=([debug]=0 [info]=1 [warn]=2 [error]=3)
  local msg_priority="${level_priority[${level}]:-1}"
  local threshold="${level_priority[${log_level}]:-1}"

  if [[ ${msg_priority} -ge ${threshold} ]]; then
    echo "[bashclaw:${level}] ${message}" >&2
  fi
}
