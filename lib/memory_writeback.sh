#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# memory_writeback.sh — BashClaw V1 第二大脑知识回写
#
# 文档参考：统一实施与验证文档 第13节
#
# 回写时机：
#   1. Tier 2 最终通过且有可复用经验
#   2. Tier 3 人工裁决完成
#   3. 高价值失败案例被确认
#   4. 某类 targeted validation 被证明有效
#   5. 某类 review 误报模式被识别
#
# 必须回写字段（16个）：
#   decision_title / task_summary / applicable_scope / non_applicable_scope /
#   final_decision / why / known_pitfalls / validation_evidence / issue_type /
#   review_or_human_required / risk_tags / changeType / linked_issue /
#   linked_pr / timestamp / superseded_by(可选)
#
# 去重与合并：高相似则 merge/update；旧决策被推翻标记 superseded；
#             新坑点追加到原主题
#
# 质量要求：宁可少而准，不可多而乱
###############################################################################

# 防止重复 source
[[ -n "${_MEMORY_WRITEBACK_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_MEMORY_WRITEBACK_SH_LOADED=1

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KNOWLEDGE_DIR="${BASHCLAW_ROOT}/.bashclaw/knowledge"
WRITEBACK_LOG="${BASHCLAW_ROOT}/.bashclaw/audit/writeback.log"

# ── source 依赖 ──────────────────────────────────────────────────────
if [[ -f "${BASHCLAW_ROOT}/lib/issue_trace.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/issue_trace.sh"
fi

if [[ -f "${BASHCLAW_ROOT}/lib/audit_log.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/audit_log.sh"
fi

# MCP 客户端（用于将知识同步回写到远程知识库）
if [[ -f "${BASHCLAW_ROOT}/lib/mcp_client.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/mcp_client.sh"
fi

# 轻量级事件日志适配器
audit_log_event() {
  local category="${1:-}" event="${2:-}" detail="${3:-}"
  local log_dir="${AUDIT_LOG_DIR:-${BASHCLAW_ROOT}/.bashclaw/audit}"
  mkdir -p "${log_dir}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | ${category} | ${event} | ${detail}" \
    >> "${log_dir}/events.log"
}

###############################################################################
# writeback_init — 初始化知识目录
###############################################################################
writeback_init() {
  mkdir -p "${KNOWLEDGE_DIR}"
  mkdir -p "$(dirname "${WRITEBACK_LOG}")"
}

###############################################################################
# writeback_should_trigger — 判断是否应触发知识回写
#
# 参数：
#   $1 = trigger_type — 以下之一：
#        tier2_passed       — Tier2 最终通过且有可复用经验
#        tier3_decided      — Tier3 人工裁决完成
#        high_value_failure — 高价值失败案例被确认
#        validation_proven  — 某类 targeted validation 被证明有效
#        false_positive     — 某类 review 误报模式被识别
#   $2 = (可选) 额外条件描述
#
# 返回：0=应触发, 1=不应触发
###############################################################################
writeback_should_trigger() {
  local trigger_type="$1"

  case "${trigger_type}" in
    tier2_passed|tier3_decided|high_value_failure|validation_proven|false_positive)
      return 0
      ;;
    *)
      echo "[WRITEBACK] 不识别的触发类型: ${trigger_type}" >&2
      return 1
      ;;
  esac
}

###############################################################################
# _writeback_generate_id — 生成知识条目 ID
# 输出：KB-YYYYMMDD-HHMMSS-RANDOM
###############################################################################
_writeback_generate_id() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local rand
  rand="$(( RANDOM % 10000 ))"
  printf "KB-%s-%04d" "${ts}" "${rand}"
}

###############################################################################
# _writeback_find_similar — 查找相似的已有知识条目
#
# 参数：$1 = decision_title
#        $2 = applicable_scope
# 输出：相似条目的文件路径（可能为空）
#
# 注意：这是简化的文本匹配，生产中应使用 MCP 知识库的语义搜索
###############################################################################
_writeback_find_similar() {
  local title="$1"
  local scope="$2"
  local kb_file

  writeback_init

  # 提取标题关键词（取前3个有意义的词）
  local keywords
  keywords=$(echo "${title}" | tr -cs '[:alnum:]' '\n' | head -5 | tr '\n' '|')
  keywords="${keywords%|}"

  if [[ -z "${keywords}" ]]; then
    return 0
  fi

  for kb_file in "${KNOWLEDGE_DIR}"/*.json; do
    if [[ ! -f "${kb_file}" ]]; then
      continue
    fi
    # 如果标题或 scope 中匹配到多个关键词，认为相似
    local match_count=0
    local kw
    while IFS='|' read -ra KWARRAY; do
      for kw in "${KWARRAY[@]}"; do
        if [[ -n "${kw}" ]] && grep -qi "${kw}" "${kb_file}" 2>/dev/null; then
          match_count=$(( match_count + 1 ))
        fi
      done
    done <<< "${keywords}"

    if (( match_count >= 3 )); then
      echo "${kb_file}"
      return 0
    fi
  done
}

###############################################################################
# writeback_create — 创建新知识条目
#
# 参数（通过命名参数文件传入）：
#   $1 = 知识条目 JSON 文件路径，包含所有 16 个必填字段
#
# 输出：创建的知识条目文件路径
###############################################################################
writeback_create() {
  local input_file="$1"

  writeback_init

  if [[ ! -f "${input_file}" ]]; then
    echo "[WRITEBACK] 输入文件不存在: ${input_file}" >&2
    return 1
  fi

  # 验证必填字段
  if ! _writeback_validate_fields "${input_file}"; then
    return 1
  fi

  local kb_id
  kb_id="$(_writeback_generate_id)"

  local title scope
  if command -v jq &>/dev/null; then
    title=$(jq -r '.decision_title // ""' "${input_file}")
    scope=$(jq -r '.applicable_scope // ""' "${input_file}")
  else
    title=$(grep '"decision_title"' "${input_file}" | sed 's/.*: *"\(.*\)".*/\1/' | head -1)
    scope=$(grep '"applicable_scope"' "${input_file}" | sed 's/.*: *"\(.*\)".*/\1/' | head -1)
  fi

  # 去重检查
  local similar_file
  similar_file=$(_writeback_find_similar "${title}" "${scope}")

  if [[ -n "${similar_file}" ]]; then
    echo "[WRITEBACK] 发现相似条目: ${similar_file}，执行合并" >&2
    writeback_merge "${similar_file}" "${input_file}"
    return $?
  fi

  # 创建新条目
  local kb_file="${KNOWLEDGE_DIR}/${kb_id}.json"

  if command -v jq &>/dev/null; then
    jq --arg id "${kb_id}" '. + {"kb_id": $id}' "${input_file}" > "${kb_file}"
  else
    # 简单方式：在 JSON 末尾添加 kb_id
    sed "s/^{/{\"kb_id\": \"${kb_id}\",/" "${input_file}" > "${kb_file}"
  fi

  # 写入审计日志
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "${timestamp} | WRITEBACK_CREATE | kb_id=${kb_id} title=${title}" >> "${WRITEBACK_LOG}"

  audit_log_event "MEMORY_WRITEBACK" "created" "kb_id=${kb_id} title=${title}"

  # ── MCP 回写：同步到远程知识库（best-effort，失败不影响本地） ──────
  _writeback_mcp_sync_decision "${input_file}" "${kb_id}"

  echo "${kb_file}"
}

###############################################################################
# _writeback_mcp_sync_decision — 将知识条目同步到 MCP 知识库
#
# 从知识条目 JSON 中提取关键信息，调用 mcp_save_decision 回写。
# 失败时仅记录日志，不影响本地流程。
#
# 参数：
#   $1 = 知识条目 JSON 文件路径
#   $2 = kb_id（本地 ID，用于日志关联）
###############################################################################
_writeback_mcp_sync_decision() {
  local input_file="${1:-}"
  local kb_id="${2:-}"

  # 检查 MCP 客户端是否可用
  if ! type mcp_available &>/dev/null || ! mcp_available 2>/dev/null; then
    return 0
  fi

  if [[ ! -f "${input_file}" ]]; then
    return 0
  fi

  local decision="" reason="" tags=""

  if command -v jq &>/dev/null; then
    # 组合 decision_title + final_decision 作为决策内容
    local title final_decision why risk_tags_csv
    title=$(jq -r '.decision_title // ""' "${input_file}" 2>/dev/null) || true
    final_decision=$(jq -r '.final_decision // ""' "${input_file}" 2>/dev/null) || true
    why=$(jq -r '.why // ""' "${input_file}" 2>/dev/null) || true
    risk_tags_csv=$(jq -r '(.risk_tags // []) | if type == "array" then join(",") else . end' "${input_file}" 2>/dev/null) || true

    decision="${title}: ${final_decision}"
    reason="${why}"
    tags="${risk_tags_csv}"
  else
    return 0
  fi

  if [[ -z "${decision}" || "${decision}" == ": " ]]; then
    return 0
  fi

  # best-effort 调用，失败仅记录日志
  if mcp_save_decision "${decision}" "${reason}" "${tags}" "" 2>/dev/null; then
    audit_log_event "MEMORY_WRITEBACK" "mcp_synced" "kb_id=${kb_id} target=save_decision"
  else
    audit_log_event "MEMORY_WRITEBACK" "mcp_sync_failed" "kb_id=${kb_id} target=save_decision"
  fi

  return 0
}

###############################################################################
# _writeback_mcp_sync_lesson — 将踩坑经验同步到 MCP 知识库
#
# 从知识条目中提取 known_pitfalls，调用 mcp_save_lesson 回写。
# 失败时仅记录日志，不影响本地流程。
#
# 参数：
#   $1 = 知识条目 JSON 文件路径
#   $2 = kb_id
###############################################################################
_writeback_mcp_sync_lesson() {
  local input_file="${1:-}"
  local kb_id="${2:-}"

  # 检查 MCP 客户端是否可用
  if ! type mcp_available &>/dev/null || ! mcp_available 2>/dev/null; then
    return 0
  fi

  if [[ ! -f "${input_file}" ]]; then
    return 0
  fi

  if ! command -v jq &>/dev/null; then
    return 0
  fi

  # 提取 known_pitfalls 数组中的每个条目
  local pitfalls_count
  pitfalls_count=$(jq '.known_pitfalls | if type == "array" then length else 0 end' "${input_file}" 2>/dev/null) || pitfalls_count=0

  if [[ "${pitfalls_count}" -eq 0 ]] 2>/dev/null; then
    return 0
  fi

  local title solution tags
  title=$(jq -r '.decision_title // ""' "${input_file}" 2>/dev/null) || true
  solution=$(jq -r '.final_decision // ""' "${input_file}" 2>/dev/null) || true
  tags=$(jq -r '(.risk_tags // []) | if type == "array" then join(",") else . end' "${input_file}" 2>/dev/null) || true

  # 将所有 pitfalls 合并为一个问题描述
  local problem
  problem=$(jq -r '.known_pitfalls | if type == "array" then join("; ") else tostring end' "${input_file}" 2>/dev/null) || true

  if [[ -n "${problem}" && "${problem}" != "null" ]]; then
    if mcp_save_lesson "${problem}" "${solution}" "${tags}" "${title}" 2>/dev/null; then
      audit_log_event "MEMORY_WRITEBACK" "mcp_lesson_synced" "kb_id=${kb_id}"
    else
      audit_log_event "MEMORY_WRITEBACK" "mcp_lesson_sync_failed" "kb_id=${kb_id}"
    fi
  fi

  return 0
}

###############################################################################
# _writeback_validate_fields — 验证知识条目包含所有必填字段
# 参数：$1 = JSON 文件路径
# 返回：0=通过, 1=缺失字段
###############################################################################
_writeback_validate_fields() {
  local input_file="$1"

  local required_fields=(
    "decision_title"
    "task_summary"
    "applicable_scope"
    "non_applicable_scope"
    "final_decision"
    "why"
    "known_pitfalls"
    "validation_evidence"
    "issue_type"
    "review_or_human_required"
    "risk_tags"
    "changeType"
    "linked_issue"
    "linked_pr"
    "timestamp"
  )

  local missing=()
  local field

  if command -v jq &>/dev/null; then
    for field in "${required_fields[@]}"; do
      # 检查字段是否存在（允许空字符串，但不允许字段完全缺失）
      local has_field
      has_field=$(jq "has(\"${field}\")" "${input_file}" 2>/dev/null || echo "false")
      if [[ "${has_field}" != "true" ]]; then
        missing+=("${field}")
      fi
    done
  else
    for field in "${required_fields[@]}"; do
      if ! grep -q "\"${field}\"" "${input_file}"; then
        missing+=("${field}")
      fi
    done
  fi

  if (( ${#missing[@]} > 0 )); then
    echo "[WRITEBACK] 缺失必填字段: ${missing[*]}" >&2
    return 1
  fi

  return 0
}

###############################################################################
# writeback_merge — 合并新知识到已有相似条目
#
# 参数：$1 = 已有条目文件路径
#        $2 = 新知识 JSON 文件路径
#
# 策略：
#   - 保留原条目的 kb_id
#   - 合并 known_pitfalls（去重追加）
#   - 更新 timestamp
#   - 更新 validation_evidence（追加）
#   - 如果 final_decision 不同，标记旧的为 superseded
###############################################################################
writeback_merge() {
  local existing_file="$1"
  local new_file="$2"

  if ! command -v jq &>/dev/null; then
    echo "[WRITEBACK] 合并操作需要 jq，回退到创建新条目" >&2
    # 无 jq 时直接创建新条目（避免数据损坏）
    local kb_id
    kb_id="$(_writeback_generate_id)"
    local kb_file="${KNOWLEDGE_DIR}/${kb_id}.json"
    cp "${new_file}" "${kb_file}"
    echo "${kb_file}"
    return 0
  fi

  local existing_id existing_decision new_decision
  existing_id=$(jq -r '.kb_id // ""' "${existing_file}")
  existing_decision=$(jq -r '.final_decision // ""' "${existing_file}")
  new_decision=$(jq -r '.final_decision // ""' "${new_file}")

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 如果 final_decision 不同，旧条目标记 superseded
  if [[ "${existing_decision}" != "${new_decision}" && -n "${new_decision}" ]]; then
    local new_kb_id
    new_kb_id="$(_writeback_generate_id)"

    # 标记旧条目
    local tmp
    tmp=$(jq --arg new_id "${new_kb_id}" --arg ts "${timestamp}" \
      '.superseded_by = $new_id | .superseded_at = $ts' "${existing_file}")
    echo "${tmp}" > "${existing_file}"

    # 创建新条目
    local new_kb_file="${KNOWLEDGE_DIR}/${new_kb_id}.json"
    tmp=$(jq --arg id "${new_kb_id}" '. + {"kb_id": $id}' "${new_file}")
    echo "${tmp}" > "${new_kb_file}"

    echo "${timestamp} | WRITEBACK_SUPERSEDE | old=${existing_id} new=${new_kb_id}" >> "${WRITEBACK_LOG}"
    audit_log_event "MEMORY_WRITEBACK" "superseded" \
      "old_id=${existing_id} new_id=${new_kb_id}"

    # MCP 回写：supersede 时将新决策同步到远程知识库
    _writeback_mcp_sync_decision "${new_file}" "${new_kb_id}"
    _writeback_mcp_sync_lesson "${new_file}" "${new_kb_id}"

    echo "${new_kb_file}"
    return 0
  fi

  # 否则合并：追加 pitfalls 和 evidence
  local merged
  merged=$(jq --slurpfile new "${new_file}" --arg ts "${timestamp}" '
    .known_pitfalls = (
      if (.known_pitfalls | type) == "array" then
        (.known_pitfalls + ($new[0].known_pitfalls // []) | unique)
      else
        [.known_pitfalls, ($new[0].known_pitfalls // null)] | map(select(. != null))
      end
    ) |
    .validation_evidence = (
      if (.validation_evidence | type) == "array" then
        (.validation_evidence + ($new[0].validation_evidence // []))
      else
        [.validation_evidence, ($new[0].validation_evidence // null)] | map(select(. != null))
      end
    ) |
    .timestamp = $ts |
    .merge_count = ((.merge_count // 0) + 1)
  ' "${existing_file}")

  echo "${merged}" > "${existing_file}"

  echo "${timestamp} | WRITEBACK_MERGE | kb_id=${existing_id}" >> "${WRITEBACK_LOG}"
  audit_log_event "MEMORY_WRITEBACK" "merged" "kb_id=${existing_id}"

  # MCP 回写：合并后将更新后的条目同步到远程知识库
  _writeback_mcp_sync_decision "${existing_file}" "${existing_id}"
  _writeback_mcp_sync_lesson "${new_file}" "${existing_id}"

  echo "${existing_file}"
}

###############################################################################
# writeback_build_entry — 构建知识条目 JSON（辅助函数）
#
# 参数（位置参数，按顺序）：
#   $1  = decision_title
#   $2  = task_summary
#   $3  = applicable_scope
#   $4  = non_applicable_scope
#   $5  = final_decision
#   $6  = why
#   $7  = known_pitfalls (逗号分隔)
#   $8  = validation_evidence
#   $9  = issue_type
#   $10 = review_or_human_required (true/false)
#   $11 = risk_tags (逗号分隔)
#   $12 = changeType
#   $13 = linked_issue
#   $14 = linked_pr
#
# 输出：知识条目 JSON 文件路径（写入临时文件）
###############################################################################
writeback_build_entry() {
  local decision_title="$1"
  local task_summary="$2"
  local applicable_scope="$3"
  local non_applicable_scope="$4"
  local final_decision="$5"
  local why="$6"
  local known_pitfalls="$7"
  local validation_evidence="$8"
  local issue_type="$9"
  local review_or_human_required="${10}"
  local risk_tags="${11}"
  local change_type="${12}"
  local linked_issue="${13}"
  local linked_pr="${14}"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 将逗号分隔的值转换为 JSON 数组
  local pitfalls_json risk_tags_json
  pitfalls_json=$(echo "${known_pitfalls}" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | \
    awk 'NF {printf "%s\"%s\"", (NR>1?",":""), $0}' | sed 's/^/[/' | sed 's/$/]/')
  risk_tags_json=$(echo "${risk_tags}" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | \
    awk 'NF {printf "%s\"%s\"", (NR>1?",":""), $0}' | sed 's/^/[/' | sed 's/$/]/')

  local tmp_file
  tmp_file="$(mktemp)"

  cat > "${tmp_file}" <<EOF
{
  "decision_title": "${decision_title}",
  "task_summary": "${task_summary}",
  "applicable_scope": "${applicable_scope}",
  "non_applicable_scope": "${non_applicable_scope}",
  "final_decision": "${final_decision}",
  "why": "${why}",
  "known_pitfalls": ${pitfalls_json},
  "validation_evidence": "${validation_evidence}",
  "issue_type": "${issue_type}",
  "review_or_human_required": ${review_or_human_required},
  "risk_tags": ${risk_tags_json},
  "changeType": "${change_type}",
  "linked_issue": "${linked_issue}",
  "linked_pr": "${linked_pr}",
  "timestamp": "${timestamp}"
}
EOF

  echo "${tmp_file}"
}

###############################################################################
# writeback_from_escalation — 从人工裁决结果触发知识回写
#
# 参数：
#   $1 = task_id
#   $2 = escalation_decision_file — escalation_record_decision 生成的文件
#   $3 = context_json — 包含任务上下文的 JSON 文件
#
# 输出：创建的知识条目文件路径
###############################################################################
writeback_from_escalation() {
  local task_id="$1"
  local decision_file="$2"
  local context_file="$3"

  if [[ ! -f "${decision_file}" ]]; then
    echo "[WRITEBACK] 裁决文件不存在: ${decision_file}" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "[WRITEBACK] 需要 jq 来解析裁决文件" >&2
    return 1
  fi

  local decision detail timestamp
  decision=$(jq -r '.decision' "${decision_file}")
  detail=$(jq -r '.detail' "${decision_file}")
  timestamp=$(jq -r '.timestamp' "${decision_file}")

  # 从 context 构建知识条目
  local title summary scope
  if [[ -f "${context_file}" ]]; then
    title=$(jq -r '.decision_title // "Human decision for " + .task_id' "${context_file}")
    summary=$(jq -r '.task_summary // ""' "${context_file}")
    scope=$(jq -r '.applicable_scope // ""' "${context_file}")
  else
    title="Human decision: ${task_id}"
    summary="Task ${task_id} escalated to human"
    scope="unknown"
  fi

  # 构建完整知识条目
  local entry_file
  entry_file="$(mktemp)"

  cat > "${entry_file}" <<EOF
{
  "decision_title": "${title}",
  "task_summary": "${summary}",
  "applicable_scope": "${scope}",
  "non_applicable_scope": "",
  "final_decision": "${decision}: ${detail}",
  "why": "人工裁决 — ${detail}",
  "known_pitfalls": ["此问题曾需要人工裁决，注意类似场景"],
  "validation_evidence": "human_escalation_${task_id}",
  "issue_type": "human_decision",
  "review_or_human_required": true,
  "risk_tags": [],
  "changeType": "unknown",
  "linked_issue": "${task_id}",
  "linked_pr": "",
  "timestamp": "${timestamp}"
}
EOF

  local result
  result=$(writeback_create "${entry_file}")
  rm -f "${entry_file}"

  # 记录到 issue trace
  if type issue_trace_record_memory_writeback &>/dev/null; then
    issue_trace_record_memory_writeback "${task_id}" \
      "知识已回写: ${result}"
  fi

  echo "${result}"
}

###############################################################################
# writeback_list — 列出所有知识条目
# 输出：kb_id 和 title 列表
###############################################################################
writeback_list() {
  writeback_init
  local kb_file
  for kb_file in "${KNOWLEDGE_DIR}"/*.json; do
    if [[ ! -f "${kb_file}" ]]; then
      echo "(empty)"
      return 0
    fi
    if command -v jq &>/dev/null; then
      local kb_id title superseded
      kb_id=$(jq -r '.kb_id // "?"' "${kb_file}")
      title=$(jq -r '.decision_title // "?"' "${kb_file}")
      superseded=$(jq -r '.superseded_by // ""' "${kb_file}")
      if [[ -n "${superseded}" ]]; then
        echo "[${kb_id}] ${title} (superseded by ${superseded})"
      else
        echo "[${kb_id}] ${title}"
      fi
    else
      basename "${kb_file}" .json
    fi
  done
}

###############################################################################
# writeback_get — 获取指定知识条目内容
# 参数：$1 = kb_id 或文件路径
# 输出：条目 JSON 内容
###############################################################################
writeback_get() {
  local identifier="$1"

  if [[ -f "${identifier}" ]]; then
    cat "${identifier}"
    return 0
  fi

  local kb_file="${KNOWLEDGE_DIR}/${identifier}.json"
  if [[ -f "${kb_file}" ]]; then
    cat "${kb_file}"
    return 0
  fi

  # 搜索 kb_id 匹配
  local f
  for f in "${KNOWLEDGE_DIR}"/*.json; do
    if [[ -f "${f}" ]] && grep -q "\"kb_id\": \"${identifier}\"" "${f}" 2>/dev/null; then
      cat "${f}"
      return 0
    fi
  done

  echo "[WRITEBACK] 未找到知识条目: ${identifier}" >&2
  return 1
}
