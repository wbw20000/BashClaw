#!/usr/bin/env bash
set -euo pipefail

# executor.sh — Executor module for BashClaw V1
# Responsible for understanding tasks, referencing Knowledge Gate summaries,
# executing code changes, and producing structured output.
# Supports Opus 4.6 and Codex as execution engines.
# 支持真实 AI 模型 API 调用（Anthropic / OpenAI），无 key 时优雅降级到模板输出。
# Reference: 统一实施文档 第8节

EXECUTOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载 API 客户端（如果存在）
# shellcheck source=lib/api_client.sh
[[ -f "${EXECUTOR_SCRIPT_DIR}/api_client.sh" ]] && source "${EXECUTOR_SCRIPT_DIR}/api_client.sh"

# Determine which engine to use for execution (Section 8.2, 8.3)
# Priority: BASHCLAW_ENGINE_OVERRIDE > tier-based selection > config default
executor_select_engine() {
  local tier="${1:-1}"
  local task_complexity="${2:-low}"

  # Single-use override from environment
  if [[ -n "${BASHCLAW_ENGINE_OVERRIDE:-}" ]]; then
    echo "${BASHCLAW_ENGINE_OVERRIDE}"
    return 0
  fi

  # Engine selection heuristic (Section 8.3)
  # Complex analysis / deep dependencies → Opus
  # Quick implementation / test generation / patch → Codex
  case "${task_complexity}" in
    high|complex)
      echo "opus4.6"
      ;;
    low|simple|patch)
      echo "codex"
      ;;
    *)
      # Default based on tier
      if [[ "${tier}" -ge 3 ]]; then
        echo "opus4.6"
      else
        echo "codex"
      fi
      ;;
  esac
}

# Build executor context from knowledge gate output and task metadata
executor_build_context() {
  local task_description="${1:-}"
  local knowledge_summary="${2:-}"
  local change_type="${3:-}"
  local risk_tags="${4:-}"

  cat <<EOF
EXECUTOR_CONTEXT:
  task: $(echo "${task_description}" | head -c 500)
  change_type: ${change_type}
  risk_tags: ${risk_tags}
  knowledge_summary: $(echo "${knowledge_summary}" | head -c 1000)
EOF
}

# Generate the executor output structure (Section 8.4)
# This is a template — actual code changes happen via the engine
executor_format_output() {
  local summary="${1:-}"
  local changed_files="${2:-}"
  local reason="${3:-}"
  local knowledge_refs="${4:-}"
  local validation_plan="${5:-}"
  local open_risks="${6:-}"

  cat <<EOF
{
  "executor_output": {
    "summary": {
      "description": "$(echo "${summary}" | sed 's/"/\\"/g')",
      "changed_files": "$(echo "${changed_files}" | sed 's/"/\\"/g')",
      "reason": "$(echo "${reason}" | sed 's/"/\\"/g')",
      "knowledge_refs": "$(echo "${knowledge_refs}" | sed 's/"/\\"/g')"
    },
    "validation_plan": "$(echo "${validation_plan}" | sed 's/"/\\"/g')",
    "open_risks": "$(echo "${open_risks}" | sed 's/"/\\"/g')"
  }
}
EOF
}

# -----------------------------------------------------------------------------
# _executor_build_system_prompt — 构建发送给 AI 模型的 system prompt
#
# 参数:
#   $1 - knowledge_summary   Knowledge Gate 摘要
#   $2 - change_type         变更类型
#   $3 - risk_tags           风险标签
# 输出:
#   system prompt 文本（stdout）
# -----------------------------------------------------------------------------
_executor_build_system_prompt() {
  local knowledge_summary="${1:-}"
  local change_type="${2:-}"
  local risk_tags="${3:-}"

  cat <<'SYSPROMPT'
You are a senior software engineer executing a code change task.
You MUST produce output in the following structured format:

## SUMMARY
<concise description of what was done and why>

## CHANGED_FILES
<list of files modified, one per line>

## REASON
<rationale for the approach taken>

## KNOWLEDGE_REFS
<any referenced knowledge items or prior decisions>

## VALIDATION_PLAN
<step-by-step plan to validate the changes>

## OPEN_RISKS
<any remaining risks or concerns>

Be precise and actionable. Do not output vague statements.
SYSPROMPT

  # 附加知识上下文
  if [[ -n "${knowledge_summary}" ]]; then
    echo ""
    echo "=== KNOWLEDGE CONTEXT ==="
    echo "${knowledge_summary}" | head -c 2000
  fi

  # 附加变更元数据
  if [[ -n "${change_type}" || -n "${risk_tags}" ]]; then
    echo ""
    echo "=== CHANGE METADATA ==="
    [[ -n "${change_type}" ]] && echo "Change type: ${change_type}"
    [[ -n "${risk_tags}" ]] && echo "Risk tags: ${risk_tags}"
  fi
}

# -----------------------------------------------------------------------------
# _executor_parse_ai_response — 解析 AI 模型返回的结构化响应
#
# 从 AI 输出中提取 SUMMARY / CHANGED_FILES / REASON / KNOWLEDGE_REFS /
# VALIDATION_PLAN / OPEN_RISKS 各部分，输出为 JSON。
#
# 参数:
#   $1 - AI 模型的原始输出
#   $2 - engine 名称
#   $3 - tier
#   $4 - token_total
# 输出:
#   executor JSON 结果（stdout）
# -----------------------------------------------------------------------------
_executor_parse_ai_response() {
  local raw_output="${1:-}"
  local engine="${2:-opus4.6}"
  local tier="${3:-1}"
  local token_total="${4:-0}"

  # 用 awk 按 section 提取各部分内容
  local summary="" changed_files="" reason="" knowledge_refs="" validation_plan="" open_risks=""

  summary=$(echo "${raw_output}" | sed -n '/^## SUMMARY/,/^## /{/^## SUMMARY/d;/^## /d;p}' | sed 's/^[[:space:]]*//' | head -c 1000)
  changed_files=$(echo "${raw_output}" | sed -n '/^## CHANGED_FILES/,/^## /{/^## CHANGED_FILES/d;/^## /d;p}' | sed 's/^[[:space:]]*//' | tr '\n' ',' | sed 's/,$//')
  reason=$(echo "${raw_output}" | sed -n '/^## REASON/,/^## /{/^## REASON/d;/^## /d;p}' | sed 's/^[[:space:]]*//' | head -c 500)
  knowledge_refs=$(echo "${raw_output}" | sed -n '/^## KNOWLEDGE_REFS/,/^## /{/^## KNOWLEDGE_REFS/d;/^## /d;p}' | sed 's/^[[:space:]]*//' | head -c 500)
  validation_plan=$(echo "${raw_output}" | sed -n '/^## VALIDATION_PLAN/,/^## /{/^## VALIDATION_PLAN/d;/^## /d;p}' | sed 's/^[[:space:]]*//' | head -c 500)
  open_risks=$(echo "${raw_output}" | sed -n '/^## OPEN_RISKS/,/^## \|$/{ /^## OPEN_RISKS/d; /^## /d; p}' | sed 's/^[[:space:]]*//' | head -c 500)

  # 如果提取失败，使用原始输出作为 summary
  [[ -z "${summary}" ]] && summary=$(echo "${raw_output}" | head -c 500)

  # 安全转义并输出 JSON
  jq -n \
    --arg engine "${engine}" \
    --argjson tier "${tier}" \
    --arg summary "${summary}" \
    --arg changed_files "${changed_files}" \
    --arg reason "${reason}" \
    --arg knowledge_refs "${knowledge_refs}" \
    --arg validation_plan "${validation_plan}" \
    --arg open_risks "${open_risks}" \
    --argjson token_total "${token_total}" \
    '{
      "executor": {
        "engine": $engine,
        "tier": $tier,
        "status": "completed",
        "mode": "real_api",
        "token_total": $token_total,
        "output": {
          "summary": $summary,
          "changed_files": $changed_files,
          "reason": $reason,
          "knowledge_refs": $knowledge_refs,
          "validation_plan": $validation_plan,
          "open_risks": $open_risks
        }
      }
    }'
}

# Run the executor pipeline
# Produces SUMMARY + VALIDATION_PLAN + OPEN_RISKS (Section 8.4)
# 当有可用的 API key 时调用真实模型，否则优雅降级到模板输出。
executor_run() {
  local task_description="${1:-}"
  local tier="${2:-1}"
  local knowledge_summary="${3:-}"
  local change_type="${4:-logic_change}"
  local risk_tags="${5:-}"
  local task_complexity="${6:-low}"

  # Select engine
  local engine
  engine="$(executor_select_engine "${tier}" "${task_complexity}")"

  # Build context
  local context
  context="$(executor_build_context \
    "${task_description}" "${knowledge_summary}" \
    "${change_type}" "${risk_tags}")"

  # =========================================================================
  # 真实 API 调用模式：当 api_client.sh 已加载且有可用 key 时
  # =========================================================================
  if type api_has_any_key &>/dev/null && api_has_any_key; then
    echo "[EXECUTOR] 使用真实 API 模式 (engine=${engine})" >&2

    # 构建 system prompt
    local system_prompt
    system_prompt=$(_executor_build_system_prompt "${knowledge_summary}" "${change_type}" "${risk_tags}")

    # 构建 user message，包含任务描述和文件上下文
    local user_message="Task: ${task_description}"

    # 附加 git diff 上下文（如果可用）
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
      local diff_context
      diff_context="$(git diff HEAD 2>/dev/null | head -200)" || true
      if [[ -n "${diff_context}" ]]; then
        user_message="${user_message}

=== CURRENT DIFF ===
${diff_context}"
      fi
    fi

    # 选择 API 调用目标
    local api_model=""
    local api_result=""
    local api_success="false"

    # 统一使用 api_call_auto（优先级：claude CLI > Anthropic API > OpenAI API）
    api_result=$(api_call_auto "${engine}" "${system_prompt}" "${user_message}" 4096 2>/dev/null) && api_success="true"
    api_model="${API_LAST_MODEL:-unknown}"

    if [[ "${api_success}" == "true" && -n "${api_result}" ]]; then
      # Critical #1 修复：检查 executor 调用 AI 后是否实际产生了代码变更
      # 防止 AI 只返回文本/元数据但未修改任何文件的静默假成功
      local has_code_changes="false"
      if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local post_diff
        post_diff="$(git diff HEAD 2>/dev/null || true)"
        if [[ -n "${post_diff}" ]]; then
          has_code_changes="true"
        fi
      fi

      # 解析 AI 响应为标准格式，并注入 files_modified 字段
      local parsed_result
      parsed_result="$(_executor_parse_ai_response "${api_result}" "${engine}" "${tier}" "${API_LAST_TOTAL_TOKENS:-0}")"

      # 向输出 JSON 注入 files_modified 标记，供 engine 层判断是否真正有变更
      if command -v jq &>/dev/null; then
        echo "${parsed_result}" | jq --argjson fm "${has_code_changes}" '.executor.files_modified = $fm'
      else
        echo "${parsed_result}"
      fi
      return 0
    fi

    echo "[EXECUTOR] API 调用失败，降级到模板输出模式" >&2
  fi

  # =========================================================================
  # 模板/Mock 输出模式（优雅降级）— 保持原有行为不变
  # =========================================================================

  # Detect changed files from git if available
  local changed_files=""
  if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    changed_files="$(git diff --name-only HEAD 2>/dev/null || echo "")"
  fi

  # Count diff lines
  local diff_lines=0
  if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    diff_lines="$(git diff HEAD --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo "0")"
  fi

  # Critical #1 修复：在模板模式下，基于 git diff 判断是否有真实文件变更
  # files_modified=true 表示 repo 中确实有代码被修改
  local files_modified="false"
  if [[ -n "${changed_files}" ]]; then
    files_modified="true"
  fi

  cat <<EOF
{
  "executor": {
    "engine": "${engine}",
    "tier": ${tier},
    "status": "ready",
    "files_modified": ${files_modified},
    "context": "$(echo "${context}" | sed 's/"/\\"/g' | tr '\n' ' ')",
    "changed_files": "$(echo "${changed_files}" | tr '\n' ',' | sed 's/,$//')",
    "diff_lines": ${diff_lines},
    "output": {
      "summary": "Task received: $(echo "${task_description}" | head -c 200 | sed 's/"/\\"/g')",
      "validation_plan": "Run base validation for ${change_type}",
      "open_risks": "$(echo "${risk_tags}" | sed 's/"/\\"/g')"
    }
  }
}
EOF
}
