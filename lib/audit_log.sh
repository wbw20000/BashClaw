#!/usr/bin/env bash
set -euo pipefail

# audit_log.sh — Audit logging for BashClaw V1
# Records complete JSON audit entries for every task execution.
# All fields from Section 26 of the implementation document.
# Reference: 统一实施文档 第26节

AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-.bashclaw/audit}"

###############################################################################
# _audit_with_lock — 审计日志专用文件锁包装函数，防止并发写入竞态
# 参数：$1 = lock_file 路径前缀, 后续参数为要执行的命令
###############################################################################
_audit_with_lock() {
  local lock_file="$1"; shift
  # flock 不可用时直接执行（优雅降级）
  if ! command -v flock &>/dev/null; then
    "$@"
    return $?
  fi
  (
    flock -w 5 200 || { echo "LOCK_TIMEOUT" >&2; return 1; }
    "$@"
  ) 200>"${lock_file}.lock"
}

# Generate a unique task ID
audit_generate_task_id() {
  local date_part
  date_part="$(date +%Y%m%d)"
  local rand_part
  rand_part="$(head -c 6 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 6 || echo "$(date +%s)" | tail -c 6)"
  echo "${date_part}-${rand_part}"
}

# Initialize audit log directory
audit_init() {
  local log_dir="${1:-${AUDIT_LOG_DIR}}"
  mkdir -p "${log_dir}"
}

# Write a complete audit log entry (Section 26)
# All fields from the document specification
audit_log_write() {
  local task_id="${1:-$(audit_generate_task_id)}"
  local platform="${2:-bashclaw}"
  local tier_requested="${3:-default}"
  local tier_effective="${4:-default}"
  local executor_model="${5:-opus4.6}"
  local reviewer_model="${6:-}"
  local changed_files="${7:-0}"
  local diff_lines="${8:-0}"
  local change_type="${9:-logic_change}"
  local risk_tags="${10:-}"
  local knowledge_hits="${11:-}"
  local knowledge_confidence="${12:-low}"
  local knowledge_helpful="${13:-false}"
  local base_validation="${14:-[]}"
  local review_issue_count="${15:-0}"
  local confirmed_issue_count="${16:-0}"
  local refuted_issue_count="${17:-0}"
  local unverifiable_issue_count="${18:-0}"
  local requirement_conflict_count="${19:-0}"
  local targeted_validations="${20:-[]}"
  local human_escalated="${21:-false}"
  local human_final_decision="${22:-}"
  local memory_writeback_status="${23:-none}"
  local final_status="${24:-PENDING}"
  local resolved="${25:-false}"
  local token_total="${26:-0}"

  local log_dir="${AUDIT_LOG_DIR}"
  audit_init "${log_dir}"

  # Build risk_tags JSON array
  local risk_tags_json="[]"
  if [[ -n "${risk_tags}" ]]; then
    risk_tags_json="["
    local first=true
    IFS=',' read -ra tag_arr <<< "${risk_tags}"
    for tag in "${tag_arr[@]}"; do
      tag="$(echo "${tag}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "${tag}" ]] && continue
      ${first} || risk_tags_json="${risk_tags_json},"
      risk_tags_json="${risk_tags_json}\"${tag}\""
      first=false
    done
    risk_tags_json="${risk_tags_json}]"
  fi

  # Build knowledge_hits JSON array
  local knowledge_hits_json="[]"
  if [[ -n "${knowledge_hits}" ]]; then
    knowledge_hits_json="["
    local first=true
    IFS=',' read -ra hit_arr <<< "${knowledge_hits}"
    for hit in "${hit_arr[@]}"; do
      hit="$(echo "${hit}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "${hit}" ]] && continue
      ${first} || knowledge_hits_json="${knowledge_hits_json},"
      knowledge_hits_json="${knowledge_hits_json}\"${hit}\""
      first=false
    done
    knowledge_hits_json="${knowledge_hits_json}]"
  fi

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local log_file="${log_dir}/${task_id}.json"

  # 修复 High #5: 使用 jq -n --arg 安全构造 JSON，避免手工拼接导致的注入和格式错误
  jq -n \
    --arg task_id "${task_id}" \
    --arg timestamp "${timestamp}" \
    --arg platform "${platform}" \
    --arg tier_requested "${tier_requested}" \
    --arg tier_effective "${tier_effective}" \
    --arg executor_model "${executor_model}" \
    --arg reviewer_model "${reviewer_model}" \
    --argjson changed_files "${changed_files}" \
    --argjson diff_lines "${diff_lines}" \
    --arg change_type "${change_type}" \
    --argjson risk_tags "${risk_tags_json}" \
    --argjson knowledge_hits "${knowledge_hits_json}" \
    --arg knowledge_confidence "${knowledge_confidence}" \
    --argjson knowledge_helpful "${knowledge_helpful}" \
    --argjson base_validation "${base_validation}" \
    --argjson review_issue_count "${review_issue_count}" \
    --argjson confirmed_issue_count "${confirmed_issue_count}" \
    --argjson refuted_issue_count "${refuted_issue_count}" \
    --argjson unverifiable_issue_count "${unverifiable_issue_count}" \
    --argjson requirement_conflict_count "${requirement_conflict_count}" \
    --argjson targeted_validations "${targeted_validations}" \
    --argjson human_escalated "${human_escalated}" \
    --arg human_final_decision "${human_final_decision}" \
    --arg memory_writeback_status "${memory_writeback_status}" \
    --arg final_status "${final_status}" \
    --argjson resolved "${resolved}" \
    --argjson token_total "${token_total}" \
    '{
      task_id: $task_id,
      timestamp: $timestamp,
      platform: $platform,
      tier_requested: $tier_requested,
      tier_effective: $tier_effective,
      executor_model: $executor_model,
      reviewer_model: $reviewer_model,
      changed_files: $changed_files,
      diff_lines: $diff_lines,
      change_type: $change_type,
      risk_tags: $risk_tags,
      knowledge_hits: $knowledge_hits,
      knowledge_confidence: $knowledge_confidence,
      knowledge_helpful: $knowledge_helpful,
      base_validation: $base_validation,
      review_issue_count: $review_issue_count,
      confirmed_issue_count: $confirmed_issue_count,
      refuted_issue_count: $refuted_issue_count,
      unverifiable_issue_count: $unverifiable_issue_count,
      requirement_conflict_count: $requirement_conflict_count,
      targeted_validations: $targeted_validations,
      human_escalated: $human_escalated,
      human_final_decision: $human_final_decision,
      memory_writeback_status: $memory_writeback_status,
      final_status: $final_status,
      resolved: $resolved,
      token_total: $token_total
    }' > "${log_file}"

  echo "${log_file}"
}

# _audit_log_update_inner — 更新审计日志内部实现（需在锁内调用）
_audit_log_update_inner() {
  local task_id="$1"
  local field="$2"
  local value="$3"
  local log_dir="${AUDIT_LOG_DIR}"

  local log_file="${log_dir}/${task_id}.json"

  if [[ ! -f "${log_file}" ]]; then
    echo "ERROR: Audit log not found for task: ${task_id}" >&2
    return 1
  fi

  # Use a temporary file for atomic update
  local tmp_file="${log_file}.tmp"

  if command -v jq &>/dev/null; then
    # Use jq for proper JSON manipulation
    jq --arg field "${field}" --argjson value "${value}" '.[$field] = $value' "${log_file}" > "${tmp_file}"
    mv "${tmp_file}" "${log_file}"
  else
    # Fallback: sed-based simple replacement (for string values only)
    sed "s/\"${field}\": \"[^\"]*\"/\"${field}\": \"${value}\"/" "${log_file}" > "${tmp_file}"
    mv "${tmp_file}" "${log_file}"
  fi
}

# Update an existing audit log entry with new fields（带文件锁保护 read-modify-write）
audit_log_update() {
  local task_id="$1"
  local field="$2"
  local value="$3"
  local log_dir="${AUDIT_LOG_DIR}"
  local log_file="${log_dir}/${task_id}.json"

  # 使用文件锁保护 read-modify-write 操作，防止并发更新竞态
  _audit_with_lock "${log_file}" _audit_log_update_inner "${task_id}" "${field}" "${value}"
}

# Show audit log entry for a task
audit_log_show() {
  local task_id="${1:-}"
  local log_dir="${AUDIT_LOG_DIR}"

  if [[ -z "${task_id}" ]]; then
    # List recent audit logs
    echo "Recent audit logs:"
    ls -t "${log_dir}"/*.json 2>/dev/null | head -20 | while read -r f; do
      local tid
      tid="$(basename "${f}" .json)"
      local status=""
      if command -v jq &>/dev/null; then
        status="$(jq -r '.final_status // "unknown"' "${f}")"
      fi
      echo "  ${tid}  ${status}"
    done
    return 0
  fi

  local log_file="${log_dir}/${task_id}.json"
  if [[ ! -f "${log_file}" ]]; then
    echo "ERROR: Audit log not found: ${task_id}" >&2
    return 1
  fi

  if command -v jq &>/dev/null; then
    jq . "${log_file}"
  else
    cat "${log_file}"
  fi
}

# Calculate summary statistics from audit logs
audit_log_stats() {
  local log_dir="${AUDIT_LOG_DIR}"

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for audit statistics" >&2
    return 1
  fi

  local total=0
  local resolved_count=0
  local tier2_count=0
  local tier3_count=0
  local human_escalated_count=0
  local total_tokens=0
  local knowledge_hit_tasks=0

  for f in "${log_dir}"/*.json; do
    [[ -f "${f}" ]] || continue
    total=$((total + 1))

    local r
    r="$(jq -r '.resolved // false' "${f}")"
    [[ "${r}" == "true" ]] && resolved_count=$((resolved_count + 1))

    local te
    te="$(jq -r '.tier_effective // "default"' "${f}")"
    [[ "${te}" == "reviewed" ]] && tier2_count=$((tier2_count + 1))
    [[ "${te}" == "critical" ]] && tier3_count=$((tier3_count + 1))

    local he
    he="$(jq -r '.human_escalated // false' "${f}")"
    [[ "${he}" == "true" ]] && human_escalated_count=$((human_escalated_count + 1))

    local tok
    tok="$(jq -r '.token_total // 0' "${f}")"
    total_tokens=$((total_tokens + tok))

    # Knowledge hit tracking
    local kh
    kh="$(jq -r '.knowledge_helpful // false' "${f}")"
    [[ "${kh}" == "true" ]] && knowledge_hit_tasks=$((knowledge_hit_tasks + 1))
  done

  # 修复 High #5 + resolved_rate bug: 除数应为 total 而非 total+1，且用 jq 安全构造 JSON
  local resolved_rate="N/A"
  if [[ "${total}" -gt 0 ]]; then
    resolved_rate="$(echo "scale=2; ${resolved_count} * 100 / ${total}" | bc 2>/dev/null || echo "N/A")"
  else
    resolved_rate="0"
  fi

  local knowledge_hit_rate="0"
  if [[ "${total}" -gt 0 ]]; then
    knowledge_hit_rate="$(echo "scale=2; ${knowledge_hit_tasks} * 100 / ${total}" | bc 2>/dev/null || echo "0")"
  fi

  jq -n \
    --argjson total_tasks "${total}" \
    --argjson resolved "${resolved_count}" \
    --argjson tier2_runs "${tier2_count}" \
    --argjson tier3_runs "${tier3_count}" \
    --argjson human_escalations "${human_escalated_count}" \
    --argjson total_tokens "${total_tokens}" \
    --arg resolved_rate "${resolved_rate}%" \
    --argjson knowledge_hit_tasks "${knowledge_hit_tasks}" \
    --arg knowledge_hit_rate "${knowledge_hit_rate}%" \
    '{
      total_tasks: $total_tasks,
      resolved: $resolved,
      tier2_runs: $tier2_runs,
      tier3_runs: $tier3_runs,
      human_escalations: $human_escalations,
      total_tokens: $total_tokens,
      resolved_rate: $resolved_rate,
      knowledge_hit_tasks: $knowledge_hit_tasks,
      knowledge_hit_rate: $knowledge_hit_rate
    }'
}

# 轻量级事件日志适配器（供其他模块使用）
audit_log_event() {
  local category="${1:-}" event="${2:-}" detail="${3:-}"
  local log_dir="${AUDIT_LOG_DIR:-${BASHCLAW_ROOT}/.bashclaw/audit}"
  mkdir -p "${log_dir}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | ${category} | ${event} | ${detail}" \
    >> "${log_dir}/events.log"
}
