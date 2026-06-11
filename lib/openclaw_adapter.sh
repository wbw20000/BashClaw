#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# openclaw_adapter.sh — OpenClaw 平台适配层
#
# 共享 BashClaw 的核心逻辑（风险分类、Knowledge Gate、验证、review、
# 证据裁决、人工升级、知识回写），并添加 OpenClaw 特有的功能接口：
#   - Agent 间角色协调
#   - 知识库检索（调用 MCP）
#   - 长链任务上下文管理
#   - 任务分解
#   - 跨任务记忆复用
#
# 文档参考：统一实施与验证文档 第3节
###############################################################################

# 防止重复 source
[[ -n "${_OPENCLAW_ADAPTER_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_OPENCLAW_ADAPTER_SH_LOADED=1

# 确定项目根目录
OPENCLAW_ROOT="${OPENCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OPENCLAW_LIB="${OPENCLAW_ROOT}/lib"
OPENCLAW_CONTEXT_DIR="${OPENCLAW_ROOT}/.openclaw/contexts"
OPENCLAW_TASK_CHAIN_DIR="${OPENCLAW_ROOT}/.openclaw/task_chains"
OPENCLAW_MEMORY_DIR="${OPENCLAW_ROOT}/.openclaw/memory"

# ── Source BashClaw 核心模块 ─────────────────────────────────────────
# 这些模块提供共享的核心逻辑
for _oc_module in \
  risk_classifier.sh \
  knowledge_gate.sh \
  executor.sh \
  validator_repo.sh \
  audit_log.sh \
  routing.sh \
  reviewer.sh \
  evidence_resolution.sh \
  human_escalation.sh \
  memory_writeback.sh \
  issue_trace.sh \
  budget.sh \
  skip_review.sh \
  targeted_validation.sh \
  engine_reviewed.sh \
  engine_critical.sh; do
  if [[ -f "${OPENCLAW_LIB}/${_oc_module}" ]]; then
    # shellcheck source=/dev/null
    source "${OPENCLAW_LIB}/${_oc_module}"
  fi
done
unset _oc_module

###############################################################################
# _openclaw_with_lock — OpenClaw 专用文件锁包装函数，防止并发状态更新竞态
# 参数：$1 = lock_file 路径前缀, 后续参数为要执行的命令
###############################################################################
_openclaw_with_lock() {
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

###############################################################################
# openclaw_init — 初始化 OpenClaw 工作目录
###############################################################################
openclaw_init() {
  mkdir -p "${OPENCLAW_CONTEXT_DIR}"
  mkdir -p "${OPENCLAW_TASK_CHAIN_DIR}"
  mkdir -p "${OPENCLAW_MEMORY_DIR}"
  mkdir -p "${OPENCLAW_ROOT}/.openclaw/audit"
  mkdir -p "${OPENCLAW_ROOT}/.openclaw/agents"
}

###############################################################################
# Agent 角色枚举
###############################################################################
readonly OPENCLAW_AGENT_ROLES=(
  "executor"     # 执行代码变更
  "reviewer"     # 复查与结构化审查
  "resolver"     # 证据裁决
  "coordinator"  # 任务编排与分解
  "knowledge"    # 知识检索与回写
)

###############################################################################
# SECTION 1: Agent 间角色协调
###############################################################################

# ── agent_register — 注册一个 Agent 角色 ─────────────────────────────
# 参数：$1 = agent_id, $2 = role, $3 = engine (opus4.6/codex)
# 输出：agent 配置文件路径
agent_register() {
  local agent_id="$1"
  local role="$2"
  local engine="${3:-opus4.6}"

  openclaw_init

  # 验证 role
  local valid=false
  local r
  for r in "${OPENCLAW_AGENT_ROLES[@]}"; do
    if [[ "${role}" == "${r}" ]]; then
      valid=true
      break
    fi
  done

  if [[ "${valid}" != "true" ]]; then
    echo "ERROR: Invalid role '${role}'. Valid roles: ${OPENCLAW_AGENT_ROLES[*]}" >&2
    return 1
  fi

  local agent_file="${OPENCLAW_ROOT}/.openclaw/agents/${agent_id}.json"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat > "${agent_file}" <<EOF
{
  "agent_id": "${agent_id}",
  "role": "${role}",
  "engine": "${engine}",
  "registered_at": "${timestamp}",
  "status": "active"
}
EOF

  echo "${agent_file}"
}

# ── agent_get_role — 获取 Agent 当前角色 ─────────────────────────────
# 参数：$1 = agent_id
# 输出：role 字符串
agent_get_role() {
  local agent_id="$1"
  local agent_file="${OPENCLAW_ROOT}/.openclaw/agents/${agent_id}.json"

  if [[ ! -f "${agent_file}" ]]; then
    echo "unregistered"
    return 1
  fi

  if command -v jq &>/dev/null; then
    jq -r '.role // "unknown"' "${agent_file}"
  else
    grep '"role"' "${agent_file}" | sed 's/.*: *"\(.*\)".*/\1/' | head -1
  fi
}

# ── agent_coordinate — 协调多个 Agent 执行任务 ───────────────────────
# 参数：$1 = task_id, $2 = task_description, $3 = tier
# 输出：协调计划 JSON
agent_coordinate() {
  local task_id="$1"
  local task_description="$2"
  local tier="${3:-2}"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 根据 tier 确定需要哪些 Agent 角色
  local -a required_roles=("executor")
  case "${tier}" in
    2)
      required_roles+=("reviewer" "resolver")
      ;;
    3)
      required_roles+=("reviewer" "resolver" "coordinator" "knowledge")
      ;;
  esac

  # 构建协调计划
  local roles_json="["
  local first=true
  for role in "${required_roles[@]}"; do
    ${first} || roles_json="${roles_json},"
    roles_json="${roles_json}\"${role}\""
    first=false
  done
  roles_json="${roles_json}]"

  cat <<EOF
{
  "coordination": {
    "task_id": "${task_id}",
    "tier": ${tier},
    "required_roles": ${roles_json},
    "sequence": [
      {"step": 1, "role": "knowledge", "action": "precheck"},
      {"step": 2, "role": "executor", "action": "execute"},
      {"step": 3, "role": "reviewer", "action": "review"},
      {"step": 4, "role": "resolver", "action": "resolve_evidence"},
      {"step": 5, "role": "coordinator", "action": "aggregate_results"}
    ],
    "timestamp": "${timestamp}"
  }
}
EOF
}

# ── agent_list — 列出所有注册的 Agent ────────────────────────────────
agent_list() {
  openclaw_init
  local agent_dir="${OPENCLAW_ROOT}/.openclaw/agents"
  local f
  for f in "${agent_dir}"/*.json; do
    if [[ -f "${f}" ]]; then
      if command -v jq &>/dev/null; then
        jq -c '{agent_id, role, engine, status}' "${f}"
      else
        basename "${f}" .json
      fi
    fi
  done
}

###############################################################################
# SECTION 2: 知识库检索（调用 MCP）
###############################################################################

# ── knowledge_search_mcp — 通过 MCP Server 检索知识库 ────────────────
# 参数：$1 = query, $2 = limit (default: 5)
# 输出：检索结果 JSON
# 注意：如果 MCP 不可用，回退到本地知识库检索
knowledge_search_mcp() {
  local query="$1"
  local limit="${2:-5}"

  # 优先使用 MCP（如果配置了）
  if [[ -n "${OPENCLAW_MCP_ENDPOINT:-}" ]]; then
    local response
    # 修复 High #7: 使用 jq -n --arg 安全构造 JSON body，防止查询文本中的
    # 引号/特殊字符破坏 JSON 结构（原先直接拼接字符串有注入风险）
    local json_body
    json_body=$(jq -n --arg q "${query}" --argjson l "${limit}" \
      '{query: $q, limit: $l}')
    response=$(curl -sf --max-time 10 \
      -X POST "${OPENCLAW_MCP_ENDPOINT}/search" \
      -H "Content-Type: application/json" \
      -d "${json_body}" 2>/dev/null) || true

    if [[ -n "${response}" ]]; then
      echo "${response}"
      return 0
    fi
    echo "[OPENCLAW] MCP endpoint unreachable, falling back to local knowledge" >&2
  fi

  # 回退：使用 BashClaw 的本地知识搜索
  local knowledge_dir="${OPENCLAW_ROOT}/.bashclaw/knowledge"
  if [[ -d "${knowledge_dir}" ]]; then
    knowledge_gate_search_local "${query}" "${knowledge_dir}"
  else
    echo "[]"
  fi
}

# ── knowledge_save_mcp — 通过 MCP Server 保存知识条目 ────────────────
# 参数：$1 = entry_json (知识条目 JSON 字符串)
# 输出：保存结果
knowledge_save_mcp() {
  local entry_json="$1"

  # 优先使用 MCP
  if [[ -n "${OPENCLAW_MCP_ENDPOINT:-}" ]]; then
    # 修复 High #7: 验证输入是合法 JSON，并通过 jq 规范化，防止格式错误的
    # JSON 字符串导致 API 调用失败或数据损坏
    local safe_json
    safe_json=$(echo "${entry_json}" | jq -c '.' 2>/dev/null) || {
      echo "[OPENCLAW] Invalid JSON for knowledge save, skipping MCP" >&2
      safe_json=""
    }

    if [[ -n "${safe_json}" ]]; then
      local response
      response=$(curl -sf --max-time 10 \
        -X POST "${OPENCLAW_MCP_ENDPOINT}/save" \
        -H "Content-Type: application/json" \
        -d "${safe_json}" 2>/dev/null) || true

      if [[ -n "${response}" ]]; then
        echo "${response}"
        return 0
      fi
    fi
    echo "[OPENCLAW] MCP save failed, falling back to local" >&2
  fi

  # 回退：使用 BashClaw 本地知识回写
  local tmp_file
  tmp_file="$(mktemp)"
  echo "${entry_json}" > "${tmp_file}"
  local result
  result=$(writeback_create "${tmp_file}" 2>&1) || true
  rm -f "${tmp_file}"
  echo "${result}"
}

###############################################################################
# SECTION 3: 长链任务上下文管理
###############################################################################

# ── context_create — 为长链任务创建持久化上下文 ──────────────────────
# 参数：$1 = chain_id, $2 = description
# 输出：上下文文件路径
context_create() {
  local chain_id="$1"
  local description="$2"

  openclaw_init

  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 修复 High #7: 使用 jq 安全构造 JSON，防止 description 含引号破坏结构
  jq -n \
    --arg chain_id "${chain_id}" \
    --arg description "${description}" \
    --arg created_at "${timestamp}" \
    --arg updated_at "${timestamp}" \
    '{
      chain_id: $chain_id,
      description: $description,
      created_at: $created_at,
      updated_at: $updated_at,
      status: "active",
      tasks: [],
      accumulated_knowledge: [],
      accumulated_risk_tags: [],
      total_tier2_runs: 0,
      total_tier3_runs: 0
    }' > "${context_file}"

  echo "${context_file}"
}

# ── _context_append_task_inner — 向上下文追加任务（内部实现，需在锁内调用）
_context_append_task_inner() {
  local chain_id="$1"
  local task_id="$2"
  local task_summary="$3"
  local result_status="${4:-PENDING}"

  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"
  if [[ ! -f "${context_file}" ]]; then
    echo "[OPENCLAW] Context not found: ${chain_id}" >&2
    return 1
  fi

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if command -v jq &>/dev/null; then
    local updated
    updated=$(jq \
      --arg tid "${task_id}" \
      --arg summary "${task_summary}" \
      --arg status "${result_status}" \
      --arg ts "${timestamp}" \
      '.tasks += [{"task_id": $tid, "summary": $summary, "status": $status, "timestamp": $ts}] | .updated_at = $ts' \
      "${context_file}")
    echo "${updated}" > "${context_file}"
  else
    echo "[OPENCLAW] jq required for context updates" >&2
    return 1
  fi
}

# ── context_append_task — 向长链上下文追加任务记录（带文件锁保护）────
# 参数：$1 = chain_id, $2 = task_id, $3 = task_summary, $4 = result_status
context_append_task() {
  local chain_id="$1"
  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"
  # 使用文件锁保护 read-modify-write，防止并发追加任务丢失
  _openclaw_with_lock "${context_file}" _context_append_task_inner "$@"
}

# ── context_get — 获取长链任务上下文 ─────────────────────────────────
# 参数：$1 = chain_id
# 输出：上下文 JSON
context_get() {
  local chain_id="$1"
  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"

  if [[ ! -f "${context_file}" ]]; then
    echo "[OPENCLAW] Context not found: ${chain_id}" >&2
    return 1
  fi

  cat "${context_file}"
}

# ── context_get_accumulated_knowledge — 获取链中累积的知识 ────────────
# 参数：$1 = chain_id
# 输出：累积知识 JSON 数组
context_get_accumulated_knowledge() {
  local chain_id="$1"
  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"

  if [[ ! -f "${context_file}" ]]; then
    echo "[]"
    return 0
  fi

  if command -v jq &>/dev/null; then
    jq '.accumulated_knowledge // []' "${context_file}"
  else
    echo "[]"
  fi
}

# ── _context_accumulate_knowledge_inner — 追加知识（内部实现，需在锁内调用）
_context_accumulate_knowledge_inner() {
  local chain_id="$1"
  local knowledge_entry="$2"

  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"
  if [[ ! -f "${context_file}" ]]; then
    echo "[OPENCLAW] Context not found: ${chain_id}" >&2
    return 1
  fi

  if command -v jq &>/dev/null; then
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local updated
    updated=$(jq \
      --argjson entry "${knowledge_entry}" \
      --arg ts "${timestamp}" \
      '.accumulated_knowledge += [$entry] | .updated_at = $ts' \
      "${context_file}")
    echo "${updated}" > "${context_file}"
  else
    echo "[OPENCLAW] jq required for context updates" >&2
    return 1
  fi
}

# ── context_accumulate_knowledge — 向链中追加知识条目（带文件锁保护）──
# 参数：$1 = chain_id, $2 = knowledge_entry (JSON 字符串)
context_accumulate_knowledge() {
  local chain_id="$1"
  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"
  # 使用文件锁保护 read-modify-write，防止并发知识追加丢失
  _openclaw_with_lock "${context_file}" _context_accumulate_knowledge_inner "$@"
}

# ── context_list — 列出所有活跃的长链上下文 ──────────────────────────
context_list() {
  openclaw_init
  local f
  for f in "${OPENCLAW_CONTEXT_DIR}"/*.json; do
    if [[ -f "${f}" ]]; then
      if command -v jq &>/dev/null; then
        jq -c '{chain_id, description, status, task_count: (.tasks | length)}' "${f}"
      else
        basename "${f}" .json
      fi
    fi
  done
}

###############################################################################
# SECTION 4: 任务分解
###############################################################################

# ── task_decompose — 将复杂任务分解为子任务 ──────────────────────────
# 参数：$1 = parent_task_id, $2 = task_description, $3 = subtasks (JSON 数组)
# 输出：分解计划 JSON
task_decompose() {
  local parent_task_id="$1"
  local task_description="$2"
  local subtasks_json="${3:-[]}"

  openclaw_init

  local chain_file="${OPENCLAW_TASK_CHAIN_DIR}/${parent_task_id}.json"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 对每个子任务进行风险分类
  local enriched_subtasks="[]"
  if command -v jq &>/dev/null; then
    local subtask_count
    subtask_count=$(echo "${subtasks_json}" | jq 'length')

    for ((i = 0; i < subtask_count; i++)); do
      local subtask
      subtask=$(echo "${subtasks_json}" | jq ".[$i]")
      local sub_desc
      sub_desc=$(echo "${subtask}" | jq -r '.description // ""')
      local sub_id="${parent_task_id}_sub$((i + 1))"

      # 简易风险评估
      local sub_tier=1
      for kw in auth permission token secret payment deploy migration schema; do
        if echo "${sub_desc}" | grep -qi "${kw}"; then
          sub_tier=2
          break
        fi
      done

      enriched_subtasks=$(echo "${enriched_subtasks}" | jq \
        --arg id "${sub_id}" \
        --arg desc "${sub_desc}" \
        --argjson tier "${sub_tier}" \
        --argjson idx "$((i + 1))" \
        '. + [{"subtask_id": $id, "description": $desc, "suggested_tier": $tier, "order": $idx, "status": "pending"}]')
    done
  fi

  # 修复 High #7: 使用 jq 安全构造 JSON，防止 description 含引号破坏结构
  jq -n \
    --arg parent_task_id "${parent_task_id}" \
    --arg description "${task_description}" \
    --arg created_at "${timestamp}" \
    --argjson subtasks "${enriched_subtasks}" \
    '{
      parent_task_id: $parent_task_id,
      description: $description,
      created_at: $created_at,
      subtasks: $subtasks,
      status: "decomposed"
    }' > "${chain_file}"

  cat "${chain_file}"
}

# ── _task_update_subtask_inner — 更新子任务（内部实现，需在锁内调用）
_task_update_subtask_inner() {
  local parent_task_id="$1"
  local subtask_id="$2"
  local status="$3"
  local result_summary="${4:-}"

  local chain_file="${OPENCLAW_TASK_CHAIN_DIR}/${parent_task_id}.json"
  if [[ ! -f "${chain_file}" ]]; then
    echo "[OPENCLAW] Task chain not found: ${parent_task_id}" >&2
    return 1
  fi

  if command -v jq &>/dev/null; then
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local updated
    updated=$(jq \
      --arg sid "${subtask_id}" \
      --arg st "${status}" \
      --arg rs "${result_summary}" \
      --arg ts "${timestamp}" \
      '(.subtasks[] | select(.subtask_id == $sid)) |= . + {"status": $st, "result": $rs, "completed_at": $ts}' \
      "${chain_file}")
    echo "${updated}" > "${chain_file}"
  else
    echo "[OPENCLAW] jq required for task updates" >&2
    return 1
  fi
}

# ── task_update_subtask — 更新子任务状态（带文件锁保护）────────────────
# 参数：$1 = parent_task_id, $2 = subtask_id, $3 = status, $4 = result_summary
task_update_subtask() {
  local parent_task_id="$1"
  local chain_file="${OPENCLAW_TASK_CHAIN_DIR}/${parent_task_id}.json"
  # 使用文件锁保护 read-modify-write，防止并发子任务更新丢失
  _openclaw_with_lock "${chain_file}" _task_update_subtask_inner "$@"
}

# ── task_get_chain — 获取任务分解链 ──────────────────────────────────
# 参数：$1 = parent_task_id
# 输出：任务链 JSON
task_get_chain() {
  local parent_task_id="$1"
  local chain_file="${OPENCLAW_TASK_CHAIN_DIR}/${parent_task_id}.json"

  if [[ ! -f "${chain_file}" ]]; then
    echo "[OPENCLAW] Task chain not found: ${parent_task_id}" >&2
    return 1
  fi

  cat "${chain_file}"
}

###############################################################################
# SECTION 5: 跨任务记忆复用
###############################################################################

# ── memory_cross_task_search — 跨任务搜索可复用记忆 ──────────────────
# 参数：$1 = query, $2 = scope (可选，限制搜索范围)
# 输出：匹配的记忆条目 JSON
memory_cross_task_search() {
  local query="$1"
  local scope="${2:-}"

  # 首先搜索 MCP 知识库
  local mcp_results
  mcp_results=$(knowledge_search_mcp "${query}" 5 2>/dev/null) || mcp_results="[]"

  # 然后搜索本地知识库
  local local_results
  local_results=$(knowledge_gate_search_local "${query}" "${OPENCLAW_ROOT}/.bashclaw/knowledge" 2>/dev/null) || local_results="[]"

  # 搜索长链上下文中的累积知识
  local chain_results="[]"
  if command -v jq &>/dev/null; then
    local f
    for f in "${OPENCLAW_CONTEXT_DIR}"/*.json; do
      if [[ -f "${f}" ]]; then
        local chain_knowledge
        chain_knowledge=$(jq '.accumulated_knowledge // []' "${f}" 2>/dev/null) || continue
        local match_count
        match_count=$(echo "${chain_knowledge}" | jq 'length' 2>/dev/null) || continue
        if [[ "${match_count}" -gt 0 ]]; then
          local chain_id
          chain_id=$(jq -r '.chain_id // "unknown"' "${f}")
          chain_results=$(echo "${chain_results}" | jq \
            --arg cid "${chain_id}" \
            --argjson knowledge "${chain_knowledge}" \
            '. + [{"source": "task_chain", "chain_id": $cid, "entries": $knowledge}]')
        fi
      fi
    done
  fi

  # 合并结果
  if command -v jq &>/dev/null; then
    jq -n \
      --argjson mcp "${mcp_results}" \
      --argjson local_kb "${local_results}" \
      --argjson chains "${chain_results}" \
      '{
        "mcp_results": $mcp,
        "local_results": $local_kb,
        "chain_results": $chains
      }'
  else
    cat <<EOF
{
  "mcp_results": ${mcp_results},
  "local_results": ${local_results},
  "chain_results": ${chain_results}
}
EOF
  fi
}

# ── memory_promote_to_global — 将任务链局部知识提升为全局知识 ────────
# 参数：$1 = chain_id, $2 = entry_index (在 accumulated_knowledge 中的索引)
# 输出：创建的全局知识条目路径
memory_promote_to_global() {
  local chain_id="$1"
  local entry_index="${2:-0}"

  local context_file="${OPENCLAW_CONTEXT_DIR}/${chain_id}.json"
  if [[ ! -f "${context_file}" ]]; then
    echo "[OPENCLAW] Context not found: ${chain_id}" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "[OPENCLAW] jq required for memory promotion" >&2
    return 1
  fi

  local entry
  entry=$(jq ".accumulated_knowledge[${entry_index}]" "${context_file}")

  if [[ "${entry}" == "null" ]]; then
    echo "[OPENCLAW] No knowledge entry at index ${entry_index}" >&2
    return 1
  fi

  # 保存到全局知识库（通过 MCP 或本地）
  knowledge_save_mcp "${entry}"
}

###############################################################################
# SECTION 6: OpenClaw 统一输出 Schema
# 确保与 BashClaw 输出格式一致（文档第28.2节要求）
###############################################################################

# ── openclaw_format_result — 格式化 OpenClaw 任务结果 ────────────────
# 与 BashClaw engine_run 的输出 schema 统一
# 参数：多个（与 engine.sh 的输出字段对齐）
openclaw_format_result() {
  local task_id="$1"
  local tier_requested="$2"
  local tier_effective="$3"
  local risk_result="$4"
  local knowledge_result="$5"
  local executor_engine="$6"
  local validation_status="$7"
  local final_status="$8"
  local resolved="$9"
  local audit_log_file="${10:-}"

  # 与 BashClaw 统一的输出 schema
  cat <<EOF
{
  "task_id": "${task_id}",
  "platform": "openclaw",
  "tier_requested": "${tier_requested}",
  "tier_effective": "${tier_effective}",
  "risk_classification": ${risk_result},
  "knowledge_gate": ${knowledge_result},
  "executor": {
    "engine": "${executor_engine}",
    "status": "completed"
  },
  "validation": {
    "status": "${validation_status}"
  },
  "final_status": "${final_status}",
  "resolved": ${resolved},
  "audit_log": "${audit_log_file}"
}
EOF
}
