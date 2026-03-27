#!/usr/bin/env bash
set -euo pipefail

# knowledge_gate.sh — Knowledge Gate (Second Brain / MCP knowledge base pre-check)
# Mandatory for all Tier 2 and Tier 3 tasks.
# Retrieves historical decisions, known pitfalls, and recommended patterns
# before execution begins.
# Reference: 统一实施文档 第7节
#
# 检索策略（优先级）：
#   1. MCP 语义检索（search_knowledge）—— 精度高，依赖 MCP Server
#   2. 本地文件关键词匹配 —— 降级方案，无外部依赖

# ── source MCP 客户端 ─────────────────────────────────────────────────
BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ -f "${BASHCLAW_ROOT}/lib/mcp_client.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/mcp_client.sh"
fi

# Check if Knowledge Gate should be enabled for this tier
knowledge_gate_required() {
  local tier="${1:-1}"
  case "${tier}" in
    2|3) return 0 ;;
    *) return 1 ;;
  esac
}

# Build search query from task context
# Combines user request, file paths, change type, risk tags, etc.
knowledge_gate_build_query() {
  local user_request="${1:-}"
  local task_summary="${2:-}"
  local change_type="${3:-}"
  local -a file_paths=()
  local -a risk_tags=()
  local error_stack="${6:-}"
  local tech_stack="${7:-}"

  # Parse remaining args as file_paths and risk_tags
  if [[ $# -ge 4 ]]; then
    IFS=',' read -ra file_paths <<< "${4:-}"
  fi
  if [[ $# -ge 5 ]]; then
    IFS=',' read -ra risk_tags <<< "${5:-}"
  fi

  local query=""

  # Build composite query from all available inputs (Section 7.3)
  [[ -n "${user_request}" ]] && query="${query} ${user_request}"
  [[ -n "${task_summary}" ]] && query="${query} ${task_summary}"
  [[ -n "${change_type}" ]] && query="${query} ${change_type}"

  for fp in "${file_paths[@]}"; do
    [[ -n "${fp}" ]] && query="${query} ${fp}"
  done

  for rt in "${risk_tags[@]}"; do
    [[ -n "${rt}" ]] && query="${query} ${rt}"
  done

  [[ -n "${error_stack}" ]] && query="${query} ${error_stack}"
  [[ -n "${tech_stack}" ]] && query="${query} ${tech_stack}"

  # Trim leading/trailing whitespace
  echo "${query}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Search local knowledge base for matching entries
# Returns JSON array of matched knowledge entries
knowledge_gate_search_local() {
  local query="$1"
  local knowledge_dir="${2:-.bashclaw/knowledge}"

  if [[ ! -d "${knowledge_dir}" ]]; then
    echo "[]"
    return 0
  fi

  local -a matches=()
  local query_lower
  query_lower="$(echo "${query}" | tr '[:upper:]' '[:lower:]')"

  # Split query into searchable terms
  local -a terms=()
  read -ra terms <<< "${query_lower}"

  # Search knowledge files for matching terms
  for kb_file in "${knowledge_dir}"/*.json "${knowledge_dir}"/*.md; do
    [[ -f "${kb_file}" ]] || continue

    local content
    content="$(cat "${kb_file}" | tr '[:upper:]' '[:lower:]')"
    local match_count=0

    for term in "${terms[@]}"; do
      if [[ "${content}" == *"${term}"* ]]; then
        match_count=$((match_count + 1))
      fi
    done

    # Require at least 2 term matches or 1 if only 1 term
    local threshold=2
    [[ ${#terms[@]} -le 1 ]] && threshold=1

    if [[ ${match_count} -ge ${threshold} ]]; then
      matches+=("$(basename "${kb_file}")")
    fi
  done

  # Build JSON array
  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  local json="["
  local first=true
  for m in "${matches[@]}"; do
    ${first} || json="${json},"
    json="${json}\"${m}\""
    first=false
  done
  json="${json}]"
  echo "${json}"
}

# Determine confidence level based on match quality
# Returns: low, medium, high
knowledge_gate_assess_confidence() {
  local hit_count="${1:-0}"
  local total_risk_tags="${2:-0}"

  if [[ ${hit_count} -eq 0 ]]; then
    echo "low"
  elif [[ ${hit_count} -ge 3 || (${hit_count} -ge 2 && ${total_risk_tags} -le 2) ]]; then
    echo "high"
  else
    echo "medium"
  fi
}

# Determine action_hint based on confidence, tier, and risk (Section 7.4)
# Returns: proceed, proceed_with_caution, require_review, require_human_if_unverifiable
knowledge_gate_action_hint() {
  local confidence="$1"
  local tier="${2:-1}"
  local risk_tag_count="${3:-0}"

  # High confidence + low risk = safe to proceed
  if [[ "${confidence}" == "high" && ${risk_tag_count} -le 1 ]]; then
    echo "proceed"
    return 0
  fi

  # High confidence but some risk = proceed with caution
  if [[ "${confidence}" == "high" ]]; then
    echo "proceed_with_caution"
    return 0
  fi

  # Tier 3 with low/medium confidence = require human verification
  if [[ "${tier}" == "3" && "${confidence}" != "high" ]]; then
    echo "require_human_if_unverifiable"
    return 0
  fi

  # Medium confidence = require review
  if [[ "${confidence}" == "medium" ]]; then
    echo "require_review"
    return 0
  fi

  # Low confidence on tier 2+ = require review
  if [[ "${tier}" -ge 2 ]]; then
    echo "require_review"
    return 0
  fi

  echo "proceed_with_caution"
}

# Main Knowledge Gate entry point
# Outputs KNOWLEDGE_PRECHECK structure (Section 7.4)
#
# 检索优先级：
#   1. MCP search_knowledge 语义检索
#   2. 本地文件关键词匹配（降级方案）
knowledge_gate_run() {
  local user_request="${1:-}"
  local task_summary="${2:-}"
  local change_type="${3:-}"
  local file_paths="${4:-}"
  local risk_tags="${5:-}"
  local error_stack="${6:-}"
  local tech_stack="${7:-}"
  local tier="${8:-2}"
  local knowledge_dir="${9:-.bashclaw/knowledge}"

  # Check if Knowledge Gate is required
  if ! knowledge_gate_required "${tier}"; then
    cat <<EOF
{
  "knowledge_gate": "skipped",
  "reason": "tier_${tier}_does_not_require_knowledge_gate"
}
EOF
    return 0
  fi

  # Build search query (Section 7.3)
  local query
  query="$(knowledge_gate_build_query \
    "${user_request}" "${task_summary}" "${change_type}" \
    "${file_paths}" "${risk_tags}" "${error_stack}" "${tech_stack}")"

  # ── 检索策略：MCP 优先，本地降级 ──────────────────────────────────
  local hits="[]"
  local hit_count=0
  local known_pitfalls="[]"
  local recommended_patterns="[]"
  local non_applicable_scope="none"
  local retrieval_source="local"

  # 读取 MCP 配置的 minSimilarity（默认 0.75）
  local min_similarity="0.75"
  local retrieve_top_k="5"
  if command -v jq &>/dev/null && [[ -f "${BASHCLAW_ROOT}/bashclaw.json" ]]; then
    min_similarity=$(jq -r '.knowledge.minSimilarity // 0.75' "${BASHCLAW_ROOT}/bashclaw.json" 2>/dev/null) || min_similarity="0.75"
    retrieve_top_k=$(jq -r '.knowledge.retrieveTopK // 5' "${BASHCLAW_ROOT}/bashclaw.json" 2>/dev/null) || retrieve_top_k="5"
  fi

  # 策略1：尝试 MCP 语义检索
  local mcp_succeeded=false
  if type mcp_available &>/dev/null && mcp_available 2>/dev/null; then
    local mcp_raw=""
    mcp_raw=$(mcp_search_knowledge "${query}" "${retrieve_top_k}" 2>/dev/null) || true

    if [[ -n "${mcp_raw}" && "${mcp_raw}" != "[]" ]]; then
      # 解析 MCP 返回结果
      local parsed=""
      parsed=$(mcp_parse_search_results "${mcp_raw}" "${min_similarity}" 2>/dev/null) || true

      if [[ -n "${parsed}" ]] && command -v jq &>/dev/null; then
        local mcp_hit_count
        mcp_hit_count=$(echo "${parsed}" | jq -r '.hit_count // 0' 2>/dev/null) || mcp_hit_count=0

        if [[ "${mcp_hit_count}" -gt 0 ]] 2>/dev/null; then
          # MCP 检索成功，使用 MCP 结果
          hits=$(echo "${parsed}" | jq -c '.similar_decisions' 2>/dev/null) || hits="[]"
          hit_count="${mcp_hit_count}"
          known_pitfalls=$(echo "${parsed}" | jq -c '.known_pitfalls' 2>/dev/null) || known_pitfalls="[]"
          recommended_patterns=$(echo "${parsed}" | jq -c '.recommended_patterns' 2>/dev/null) || recommended_patterns="[]"
          retrieval_source="mcp"
          mcp_succeeded=true
        fi
      fi
    fi
  fi

  # 策略2：MCP 不可用或无结果时，回退到本地文件搜索
  if [[ "${mcp_succeeded}" != "true" ]]; then
    retrieval_source="local"
    hits="$(knowledge_gate_search_local "${query}" "${knowledge_dir}")"

    # Count hits
    hit_count=0
    if [[ "${hits}" != "[]" ]]; then
      hit_count="$(echo "${hits}" | tr ',' '\n' | wc -l)"
    fi

    # 从本地文件中提取 known_pitfalls、recommended_patterns、non_applicable_scope
    if [[ "${hits}" != "[]" ]]; then
      local pitfalls_collected="[]"
      local patterns_collected="[]"
      local scope_parts=""

      # 从 hits 数组中提取文件名列表
      local -a hit_files=()
      local hit_entry
      while IFS= read -r hit_entry; do
        [[ -n "${hit_entry}" ]] && hit_files+=("${hit_entry}")
      done < <(echo "${hits}" | tr -d '[]"' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      for kb_filename in "${hit_files[@]}"; do
        local kb_path="${knowledge_dir}/${kb_filename}"
        [[ -f "${kb_path}" ]] || continue

        # 只解析 JSON 文件
        if [[ "${kb_filename}" == *.json ]]; then
          if command -v jq &>/dev/null; then
            local file_pitfalls
            file_pitfalls=$(jq -c '.known_pitfalls // empty' "${kb_path}" 2>/dev/null) || true
            if [[ -n "${file_pitfalls}" && "${file_pitfalls}" != "null" ]]; then
              pitfalls_collected=$(echo "${pitfalls_collected}" | jq --argjson new "${file_pitfalls}" '. + $new' 2>/dev/null) || true
            fi

            local file_patterns
            file_patterns=$(jq -c '.recommended_patterns // empty' "${kb_path}" 2>/dev/null) || true
            if [[ -n "${file_patterns}" && "${file_patterns}" != "null" ]]; then
              patterns_collected=$(echo "${patterns_collected}" | jq --argjson new "${file_patterns}" '. + $new' 2>/dev/null) || true
            fi

            local file_scope
            file_scope=$(jq -r '.non_applicable_scope // empty' "${kb_path}" 2>/dev/null) || true
            if [[ -n "${file_scope}" ]]; then
              if [[ -n "${scope_parts}" ]]; then
                scope_parts="${scope_parts}, ${file_scope}"
              else
                scope_parts="${file_scope}"
              fi
            fi
          fi
        fi
      done

      known_pitfalls="${pitfalls_collected}"
      recommended_patterns="${patterns_collected}"
      if [[ -n "${scope_parts}" ]]; then
        non_applicable_scope="${scope_parts}"
      fi
    fi
  fi

  # Count risk tags
  local risk_tag_count=0
  if [[ -n "${risk_tags}" ]]; then
    risk_tag_count="$(echo "${risk_tags}" | tr ',' '\n' | wc -l)"
  fi

  # Assess confidence
  local confidence
  confidence="$(knowledge_gate_assess_confidence "${hit_count}" "${risk_tag_count}")"

  # Determine action hint
  local action_hint
  action_hint="$(knowledge_gate_action_hint "${confidence}" "${tier}" "${risk_tag_count}")"

  # 修复 High #5: 使用 jq -n --arg 安全构造 JSON，避免 query_used 等字段的特殊字符导致 JSON 破损
  jq -n \
    --argjson similar_decisions "${hits}" \
    --argjson known_pitfalls "${known_pitfalls}" \
    --argjson recommended_patterns "${recommended_patterns}" \
    --arg applicable_scope "${change_type}" \
    --arg non_applicable_scope "${non_applicable_scope}" \
    --arg confidence "${confidence}" \
    --arg action_hint "${action_hint}" \
    --arg query_used "${query}" \
    --argjson hit_count "${hit_count}" \
    --arg retrieval_source "${retrieval_source}" \
    '{
      knowledge_gate: "completed",
      similar_decisions: $similar_decisions,
      known_pitfalls: $known_pitfalls,
      recommended_patterns: $recommended_patterns,
      applicable_scope: $applicable_scope,
      non_applicable_scope: $non_applicable_scope,
      confidence: $confidence,
      action_hint: $action_hint,
      query_used: $query_used,
      hit_count: $hit_count,
      retrieval_source: $retrieval_source
    }'
}
