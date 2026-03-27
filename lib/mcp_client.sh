#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# mcp_client.sh — MCP (Model Context Protocol) 调用客户端
#
# 封装与 KnowledgeSync MCP Server 的交互。
# 支持两种调用方式：
#   1. HTTP endpoint（通过 curl 调用 MCP Server REST API）
#   2. claude-code CLI（通过 claude mcp 子命令调用）
#
# 当 MCP 不可用时，所有函数优雅降级：返回空结果 + 非零退出码，
# 调用方据此回退到本地文件搜索。
#
# 依赖：curl, jq（可选但推荐）
###############################################################################

# 防止重复 source
[[ -n "${_MCP_CLIENT_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_MCP_CLIENT_SH_LOADED=1

# ── 配置 ─────────────────────────────────────────────────────────────
BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# MCP 端点地址（从 bashclaw.json 或环境变量读取）
MCP_ENDPOINT="${MCP_ENDPOINT:-}"
# MCP 可用性缓存（避免每次都探测）
_MCP_AVAILABLE=""
# MCP 超时（秒）
MCP_TIMEOUT="${MCP_TIMEOUT:-5}"

###############################################################################
# _mcp_load_config — 从 bashclaw.json 加载 MCP 配置
###############################################################################
_mcp_load_config() {
  local config_file="${BASHCLAW_ROOT}/bashclaw.json"

  if [[ -z "${MCP_ENDPOINT}" && -f "${config_file}" ]]; then
    if command -v jq &>/dev/null; then
      MCP_ENDPOINT=$(jq -r '.knowledge.mcp_endpoint // ""' "${config_file}" 2>/dev/null) || true
    fi
  fi

  # 也检查项目根目录的 .mcp.json
  local mcp_json="${BASHCLAW_ROOT}/.mcp.json"
  if [[ -z "${MCP_ENDPOINT}" && -f "${mcp_json}" ]]; then
    if command -v jq &>/dev/null; then
      # 尝试从 .mcp.json 中提取 knowledge-sync 的 endpoint
      MCP_ENDPOINT=$(jq -r '
        .mcpServers["knowledge-sync"].url //
        .mcpServers["knowledge-sync"].endpoint //
        ""' "${mcp_json}" 2>/dev/null) || true
    fi
  fi
}

###############################################################################
# mcp_available — 检查 MCP Server 是否可用
#
# 返回：0=可用, 1=不可用
# 副作用：设置 _MCP_AVAILABLE 缓存
###############################################################################
mcp_available() {
  # 如果已经探测过，直接返回缓存结果
  if [[ "${_MCP_AVAILABLE}" == "yes" ]]; then
    return 0
  elif [[ "${_MCP_AVAILABLE}" == "no" ]]; then
    return 1
  fi

  # 加载配置
  _mcp_load_config

  # 检查 HTTP endpoint 可用性
  if [[ -n "${MCP_ENDPOINT}" ]]; then
    if command -v curl &>/dev/null; then
      local http_code
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "${MCP_TIMEOUT}" \
        "${MCP_ENDPOINT}/health" 2>/dev/null) || http_code="000"
      if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
        _MCP_AVAILABLE="yes"
        return 0
      fi
    fi
  fi

  # MCP 不可用
  _MCP_AVAILABLE="no"
  return 1
}

###############################################################################
# mcp_reset — 重置 MCP 可用性缓存（用于测试或重试）
###############################################################################
mcp_reset() {
  _MCP_AVAILABLE=""
  MCP_ENDPOINT="${MCP_ENDPOINT:-}"
}

###############################################################################
# _mcp_call — 底层 MCP HTTP 调用
#
# 参数：
#   $1 = 工具名（如 search_knowledge）
#   $2 = JSON 请求体
#
# 输出：MCP 返回的 JSON
# 返回：0=成功, 1=失败
###############################################################################
_mcp_call() {
  local tool_name="$1"
  local payload="$2"

  if ! mcp_available; then
    return 1
  fi

  local response
  response=$(curl -s --connect-timeout "${MCP_TIMEOUT}" \
    --max-time "$((MCP_TIMEOUT * 3))" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${MCP_ENDPOINT}/tools/${tool_name}" 2>/dev/null) || {
    echo "[MCP] HTTP 调用失败: tool=${tool_name}" >&2
    return 1
  }

  # 检查返回是否为有效 JSON
  if command -v jq &>/dev/null; then
    if ! echo "${response}" | jq empty 2>/dev/null; then
      echo "[MCP] 返回非法 JSON: tool=${tool_name}" >&2
      return 1
    fi
    # 检查是否包含 error 字段
    local has_error
    has_error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null) || true
    if [[ -n "${has_error}" ]]; then
      echo "[MCP] 服务端错误: ${has_error}" >&2
      return 1
    fi
  fi

  echo "${response}"
  return 0
}

###############################################################################
# mcp_search_knowledge — 语义搜索知识库
#
# 参数：
#   $1 = query — 搜索查询
#   $2 = top_k — 返回条数（默认 5）
#
# 输出：JSON 格式的搜索结果
# 返回：0=成功, 1=MCP 不可用或调用失败
###############################################################################
mcp_search_knowledge() {
  local query="${1:-}"
  local top_k="${2:-5}"

  if [[ -z "${query}" ]]; then
    echo "[]"
    return 1
  fi

  # 构建请求体
  local payload
  if command -v jq &>/dev/null; then
    payload=$(jq -n --arg q "${query}" '{"query": $q}')
  else
    # 手工转义双引号
    local escaped_query
    escaped_query=$(echo "${query}" | sed 's/"/\\"/g')
    payload="{\"query\": \"${escaped_query}\"}"
  fi

  local response
  response=$(_mcp_call "search_knowledge" "${payload}") || {
    echo "[]"
    return 1
  }

  echo "${response}"
  return 0
}

###############################################################################
# mcp_save_decision — 保存技术决策到知识库
#
# 参数：
#   $1 = decision — 决定内容
#   $2 = reason — 选择原因
#   $3 = tags — 标签，逗号分隔（可选）
#   $4 = alternatives — 放弃的替代方案（可选）
#
# 输出：MCP 返回结果
# 返回：0=成功, 1=MCP 不可用或调用失败
###############################################################################
mcp_save_decision() {
  local decision="${1:-}"
  local reason="${2:-}"
  local tags="${3:-}"
  local alternatives="${4:-}"

  if [[ -z "${decision}" || -z "${reason}" ]]; then
    echo "[MCP] save_decision 缺少必填参数: decision, reason" >&2
    return 1
  fi

  local payload
  if command -v jq &>/dev/null; then
    payload=$(jq -n \
      --arg d "${decision}" \
      --arg r "${reason}" \
      --arg t "${tags}" \
      --arg a "${alternatives}" \
      '{decision: $d, reason: $r} +
       (if $t != "" then {tags: $t} else {} end) +
       (if $a != "" then {alternatives: $a} else {} end)')
  else
    local escaped_d escaped_r
    escaped_d=$(echo "${decision}" | sed 's/"/\\"/g')
    escaped_r=$(echo "${reason}" | sed 's/"/\\"/g')
    payload="{\"decision\": \"${escaped_d}\", \"reason\": \"${escaped_r}\""
    [[ -n "${tags}" ]] && payload="${payload}, \"tags\": \"${tags}\""
    [[ -n "${alternatives}" ]] && payload="${payload}, \"alternatives\": \"${alternatives}\""
    payload="${payload}}"
  fi

  local response
  response=$(_mcp_call "save_decision" "${payload}") || return 1

  echo "${response}"
  return 0
}

###############################################################################
# mcp_save_lesson — 保存踩坑经验到知识库
#
# 参数：
#   $1 = problem — 遇到的问题
#   $2 = solution — 解决方案
#   $3 = tags — 标签，逗号分隔（可选）
#   $4 = root_cause — 根本原因（可选）
#
# 输出：MCP 返回结果
# 返回：0=成功, 1=MCP 不可用或调用失败
###############################################################################
mcp_save_lesson() {
  local problem="${1:-}"
  local solution="${2:-}"
  local tags="${3:-}"
  local root_cause="${4:-}"

  if [[ -z "${problem}" || -z "${solution}" ]]; then
    echo "[MCP] save_lesson 缺少必填参数: problem, solution" >&2
    return 1
  fi

  local payload
  if command -v jq &>/dev/null; then
    payload=$(jq -n \
      --arg p "${problem}" \
      --arg s "${solution}" \
      --arg t "${tags}" \
      --arg rc "${root_cause}" \
      '{problem: $p, solution: $s} +
       (if $t != "" then {tags: $t} else {} end) +
       (if $rc != "" then {root_cause: $rc} else {} end)')
  else
    local escaped_p escaped_s
    escaped_p=$(echo "${problem}" | sed 's/"/\\"/g')
    escaped_s=$(echo "${solution}" | sed 's/"/\\"/g')
    payload="{\"problem\": \"${escaped_p}\", \"solution\": \"${escaped_s}\""
    [[ -n "${tags}" ]] && payload="${payload}, \"tags\": \"${tags}\""
    [[ -n "${root_cause}" ]] && payload="${payload}, \"root_cause\": \"${root_cause}\""
    payload="${payload}}"
  fi

  local response
  response=$(_mcp_call "save_lesson" "${payload}") || return 1

  echo "${response}"
  return 0
}

###############################################################################
# mcp_get_related — 获取与主题相关的知识卡片
#
# 参数：
#   $1 = topic — 主题关键词
#   $2 = limit — 返回数量（默认 5）
#
# 输出：JSON 格式的相关知识
# 返回：0=成功, 1=MCP 不可用或调用失败
###############################################################################
mcp_get_related() {
  local topic="${1:-}"
  local limit="${2:-5}"

  if [[ -z "${topic}" ]]; then
    echo "[]"
    return 1
  fi

  local payload
  if command -v jq &>/dev/null; then
    payload=$(jq -n \
      --arg t "${topic}" \
      --argjson l "${limit}" \
      '{topic: $t, limit: $l}')
  else
    payload="{\"topic\": \"${topic}\", \"limit\": ${limit}}"
  fi

  local response
  response=$(_mcp_call "get_related" "${payload}") || {
    echo "[]"
    return 1
  }

  echo "${response}"
  return 0
}

###############################################################################
# mcp_get_card_detail — 获取知识卡片详情
#
# 参数：
#   $1 = title — 卡片标题
#
# 输出：JSON 格式的卡片详情
# 返回：0=成功, 1=MCP 不可用或调用失败
###############################################################################
mcp_get_card_detail() {
  local title="${1:-}"

  if [[ -z "${title}" ]]; then
    echo "{}"
    return 1
  fi

  local payload
  if command -v jq &>/dev/null; then
    payload=$(jq -n --arg t "${title}" '{title: $t}')
  else
    local escaped_t
    escaped_t=$(echo "${title}" | sed 's/"/\\"/g')
    payload="{\"title\": \"${escaped_t}\"}"
  fi

  local response
  response=$(_mcp_call "get_card_detail" "${payload}") || {
    echo "{}"
    return 1
  }

  echo "${response}"
  return 0
}

###############################################################################
# mcp_parse_search_results — 解析 MCP 搜索结果为 knowledge_gate 格式
#
# 将 MCP search_knowledge 返回的结果转换为 knowledge_gate 所需的结构，
# 提取 similar_decisions、known_pitfalls、recommended_patterns。
#
# 参数：
#   $1 = MCP 搜索返回的 JSON
#   $2 = min_similarity — 最低相似度阈值（默认 0.75）
#
# 输出：JSON 对象，包含 similar_decisions / known_pitfalls /
#        recommended_patterns / hit_count
###############################################################################
mcp_parse_search_results() {
  local raw_json="${1:-[]}"
  local min_similarity="${2:-0.75}"

  if ! command -v jq &>/dev/null; then
    # 没有 jq 时返回空结构
    cat <<'EOF'
{"similar_decisions":[],"known_pitfalls":[],"recommended_patterns":[],"hit_count":0}
EOF
    return 0
  fi

  # MCP search_knowledge 返回格式可能是：
  #   - 直接数组: [{title, content, similarity, ...}, ...]
  #   - 包装对象: {results: [...], total: N}
  #   - 纯文本消息（当无结果时）
  #
  # 我们统一处理为数组

  local results
  results=$(echo "${raw_json}" | jq -c '
    if type == "array" then .
    elif type == "object" and has("results") then .results
    elif type == "object" and has("cards") then .cards
    else []
    end
  ' 2>/dev/null) || results="[]"

  # 按相似度过滤（如果有 similarity 字段）
  local filtered
  filtered=$(echo "${results}" | jq -c --argjson min "${min_similarity}" '
    [.[] | select(
      (.similarity // .score // 1.0) >= $min
    )]
  ' 2>/dev/null) || filtered="${results}"

  # 提取 similar_decisions（标题列表）
  local similar_decisions
  similar_decisions=$(echo "${filtered}" | jq -c '
    [.[] | .title // .decision_title // .name // "unknown"]
  ' 2>/dev/null) || similar_decisions="[]"

  # 提取 known_pitfalls（从各条目的 pitfalls/known_pitfalls 字段合并）
  local known_pitfalls
  known_pitfalls=$(echo "${filtered}" | jq -c '
    [.[] |
      (.known_pitfalls // .pitfalls // []) |
      if type == "array" then .[] else . end
    ] | unique
  ' 2>/dev/null) || known_pitfalls="[]"

  # 提取 recommended_patterns
  local recommended_patterns
  recommended_patterns=$(echo "${filtered}" | jq -c '
    [.[] |
      (.recommended_patterns // .patterns // []) |
      if type == "array" then .[] else . end
    ] | unique
  ' 2>/dev/null) || recommended_patterns="[]"

  # 计算命中数
  local hit_count
  hit_count=$(echo "${filtered}" | jq 'length' 2>/dev/null) || hit_count=0

  jq -n \
    --argjson sd "${similar_decisions}" \
    --argjson kp "${known_pitfalls}" \
    --argjson rp "${recommended_patterns}" \
    --argjson hc "${hit_count}" \
    '{
      similar_decisions: $sd,
      known_pitfalls: $kp,
      recommended_patterns: $rp,
      hit_count: $hc
    }'
}
