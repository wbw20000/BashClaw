#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# issue_trace.sh — BashClaw V1 Issue Trace 过程留痕
#
# 文档参考：统一实施与验证文档 第14节
#
# 功能：
#   - 一任务一 issue，维护 ledger（结构化注释流）
#   - 10个记录节点：INTAKE / KNOWLEDGE_PRECHECK / PLAN / EXECUTOR_RESULT /
#     BASE_VALIDATION / REVIEW_ISSUES / EVIDENCE_RESOLUTION / HUMAN_DECISION /
#     MEMORY_WRITEBACK / FINAL_DELIVERY
#   - 沉淀关键决策，不沉淀全部原始对话
#   - 长日志放 artifact/markdown
#   - ledger comment 更新机制
###############################################################################

# 防止重复 source
[[ -n "${_ISSUE_TRACE_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_ISSUE_TRACE_SH_LOADED=1

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ISSUE_TRACE_DIR="${BASHCLAW_ROOT}/.bashclaw/issue_trace"
ARTIFACT_DIR="${BASHCLAW_ROOT}/.bashclaw/artifacts"

# GitHub Issue 集成的 ledger 标记
_GH_LEDGER_MARKER="${_GH_LEDGER_MARKER:-<!-- BASHCLAW_LEDGER -->}"

# ── stub imports ──────────────────────────────────────────────────────
if [[ -f "${BASHCLAW_ROOT}/lib/audit_log.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/audit_log.sh"
fi


# 有效的记录节点（仅在首次 source 时定义）
if [[ -z "${_TRACE_NODES_DEFINED:-}" ]]; then
readonly TRACE_NODES=(
  "INTAKE"
  "KNOWLEDGE_PRECHECK"
  "PLAN"
  "EXECUTOR_RESULT"
  "BASE_VALIDATION"
  "REVIEW_ISSUES"
  "EVIDENCE_RESOLUTION"
  "HUMAN_DECISION"
  "MEMORY_WRITEBACK"
  "FINAL_DELIVERY"
)
_TRACE_NODES_DEFINED=1
fi

###############################################################################
# issue_trace_init — 初始化 issue trace 目录
###############################################################################
issue_trace_init() {
  mkdir -p "${ISSUE_TRACE_DIR}"
  mkdir -p "${ARTIFACT_DIR}"
}

###############################################################################
# _trace_validate_node — 验证节点名称是否合法
# 参数：$1 = node name
# 返回：0=合法, 1=非法
###############################################################################
_trace_validate_node() {
  local node="$1"
  local valid
  for valid in "${TRACE_NODES[@]}"; do
    if [[ "${valid}" == "${node}" ]]; then
      return 0
    fi
  done
  echo "[ISSUE_TRACE] 无效的记录节点: ${node}" >&2
  return 1
}

###############################################################################
# issue_trace_create — 创建新 issue trace
# 参数：$1 = task_id
#        $2 = 原始需求摘要
#        $3 = tier (tier1/tier2/tier3)
# 输出：issue trace 文件路径
###############################################################################
issue_trace_create() {
  local task_id="$1"
  local requirement_summary="$2"
  local tier="${3:-tier1}"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  issue_trace_init

  local trace_file="${ISSUE_TRACE_DIR}/${task_id}.md"

  cat > "${trace_file}" <<EOF
# Issue Trace: ${task_id}

- **创建时间**: ${timestamp}
- **Tier**: ${tier}
- **状态**: OPEN

## 需求摘要
${requirement_summary}

## Ledger

EOF

  # 自动记录 INTAKE 节点
  _trace_append_ledger "${trace_file}" "INTAKE" "任务已接收。Tier: ${tier}" "${timestamp}"

  audit_log_event "ISSUE_TRACE" "created" "task_id=${task_id} tier=${tier}"

  # GitHub 集成：创建对应的 GitHub issue（优雅降级）
  issue_trace_gh_create_issue "${task_id}" \
    "[BashClaw] ${task_id}" "${requirement_summary}" > /dev/null 2>&1 || true

  echo "${trace_file}"
}

###############################################################################
# _trace_append_ledger — 向 ledger 追加一条记录（内部函数）
# 参数：$1 = trace file path
#        $2 = node name
#        $3 = content (单行或多行摘要)
#        $4 = timestamp (可选，默认当前时间)
###############################################################################
_trace_append_ledger() {
  local trace_file="$1"
  local node="$2"
  local content="$3"
  local timestamp="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  cat >> "${trace_file}" <<EOF
### [${timestamp}] ${node}
${content}

EOF
}

###############################################################################
# issue_trace_record — 记录一个节点到 issue trace
# 参数：$1 = task_id
#        $2 = node name (必须是 TRACE_NODES 之一)
#        $3 = 摘要内容
#        $4 = (可选) 详细内容文件路径（长内容放 artifact）
###############################################################################
issue_trace_record() {
  local task_id="$1"
  local node="$2"
  local summary="$3"
  local detail_file="${4:-}"

  _trace_validate_node "${node}" || return 1

  local trace_file="${ISSUE_TRACE_DIR}/${task_id}.md"
  if [[ ! -f "${trace_file}" ]]; then
    echo "[ISSUE_TRACE] trace 不存在: ${task_id}，自动创建" >&2
    issue_trace_create "${task_id}" "(auto-created)" "unknown" > /dev/null
  fi

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local content="${summary}"

  # 如果提供了详细内容文件，将其保存为 artifact 并在 ledger 中引用
  if [[ -n "${detail_file}" && -f "${detail_file}" ]]; then
    local artifact_name="${task_id}_${node}_$(date +%s).md"
    local artifact_path="${ARTIFACT_DIR}/${artifact_name}"
    cp "${detail_file}" "${artifact_path}"
    content="${summary}
> 详细内容: artifacts/${artifact_name}"
  fi

  _trace_append_ledger "${trace_file}" "${node}" "${content}" "${timestamp}"

  audit_log_event "ISSUE_TRACE" "node_recorded" \
    "task_id=${task_id} node=${node}"

  # GitHub 集成：同步到 GitHub issue（优雅降级）
  _issue_trace_gh_sync "${task_id}" "${node}" "${summary}" || true
}

###############################################################################
# issue_trace_record_knowledge_precheck — 记录知识预检结果
# 参数：$1 = task_id
#        $2 = precheck summary (多行文本)
###############################################################################
issue_trace_record_knowledge_precheck() {
  local task_id="$1"
  local precheck_summary="$2"
  issue_trace_record "${task_id}" "KNOWLEDGE_PRECHECK" "${precheck_summary}"
}

###############################################################################
# issue_trace_record_plan — 记录执行计划
# 参数：$1 = task_id
#        $2 = plan summary
###############################################################################
issue_trace_record_plan() {
  local task_id="$1"
  local plan_summary="$2"
  issue_trace_record "${task_id}" "PLAN" "${plan_summary}"
}

###############################################################################
# issue_trace_record_executor_result — 记录执行器结果
# 参数：$1 = task_id
#        $2 = result summary
#        $3 = (可选) 详细 diff 文件
###############################################################################
issue_trace_record_executor_result() {
  local task_id="$1"
  local result_summary="$2"
  local detail_file="${3:-}"
  issue_trace_record "${task_id}" "EXECUTOR_RESULT" "${result_summary}" "${detail_file}"
}

###############################################################################
# issue_trace_record_base_validation — 记录基础验证结果
# 参数：$1 = task_id
#        $2 = validation summary
###############################################################################
issue_trace_record_base_validation() {
  local task_id="$1"
  local validation_summary="$2"
  issue_trace_record "${task_id}" "BASE_VALIDATION" "${validation_summary}"
}

###############################################################################
# issue_trace_record_review_issues — 记录 Reviewer 提出的 issues
# 参数：$1 = task_id
#        $2 = issues summary
#        $3 = (可选) 详细 issues 文件
###############################################################################
issue_trace_record_review_issues() {
  local task_id="$1"
  local issues_summary="$2"
  local detail_file="${3:-}"
  issue_trace_record "${task_id}" "REVIEW_ISSUES" "${issues_summary}" "${detail_file}"
}

###############################################################################
# issue_trace_record_evidence_resolution — 记录证据裁决结果
# 参数：$1 = task_id
#        $2 = resolution summary (包含每个 issue 的裁决状态)
###############################################################################
issue_trace_record_evidence_resolution() {
  local task_id="$1"
  local resolution_summary="$2"
  issue_trace_record "${task_id}" "EVIDENCE_RESOLUTION" "${resolution_summary}"
}

###############################################################################
# issue_trace_record_human_decision — 记录人工裁决结果
# 参数：$1 = task_id
#        $2 = decision summary
###############################################################################
issue_trace_record_human_decision() {
  local task_id="$1"
  local decision_summary="$2"
  issue_trace_record "${task_id}" "HUMAN_DECISION" "${decision_summary}"
}

###############################################################################
# issue_trace_record_memory_writeback — 记录知识回写
# 参数：$1 = task_id
#        $2 = writeback summary
###############################################################################
issue_trace_record_memory_writeback() {
  local task_id="$1"
  local writeback_summary="$2"
  issue_trace_record "${task_id}" "MEMORY_WRITEBACK" "${writeback_summary}"
}

###############################################################################
# issue_trace_record_final_delivery — 记录最终交付
# 参数：$1 = task_id
#        $2 = delivery summary
###############################################################################
issue_trace_record_final_delivery() {
  local task_id="$1"
  local delivery_summary="$2"
  issue_trace_record "${task_id}" "FINAL_DELIVERY" "${delivery_summary}"

  # 标记 issue 为 CLOSED
  local trace_file="${ISSUE_TRACE_DIR}/${task_id}.md"
  if [[ -f "${trace_file}" ]]; then
    sed -i 's/- \*\*状态\*\*: OPEN/- **状态**: CLOSED/' "${trace_file}"
  fi

  # GitHub 集成：关闭 GitHub issue（优雅降级）
  issue_trace_gh_close "${task_id}" || true
}

###############################################################################
# issue_trace_get — 读取 issue trace 内容
# 参数：$1 = task_id
# 输出：trace 文件内容
###############################################################################
issue_trace_get() {
  local task_id="$1"
  local trace_file="${ISSUE_TRACE_DIR}/${task_id}.md"
  if [[ ! -f "${trace_file}" ]]; then
    echo "[ISSUE_TRACE] trace 不存在: ${task_id}" >&2
    return 1
  fi
  cat "${trace_file}"
}

###############################################################################
# issue_trace_list — 列出所有 issue trace
# 输出：task_id 列表
###############################################################################
issue_trace_list() {
  issue_trace_init
  local f
  for f in "${ISSUE_TRACE_DIR}"/*.md; do
    if [[ -f "${f}" ]]; then
      basename "${f}" .md
    fi
  done
}

###############################################################################
# issue_trace_create_sub_issue — 为长任务创建 sub-issue
# 参数：$1 = parent task_id
#        $2 = sub_id (例如 "sub1")
#        $3 = 子任务摘要
# 输出：sub-issue trace 文件路径
###############################################################################
issue_trace_create_sub_issue() {
  local parent_id="$1"
  local sub_id="$2"
  local summary="$3"

  local full_id="${parent_id}_${sub_id}"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local trace_file="${ISSUE_TRACE_DIR}/${full_id}.md"

  cat > "${trace_file}" <<EOF
# Sub-Issue Trace: ${full_id}

- **父任务**: ${parent_id}
- **创建时间**: ${timestamp}
- **状态**: OPEN

## 子任务摘要
${summary}

## Ledger

EOF

  _trace_append_ledger "${trace_file}" "INTAKE" "子任务已创建。父任务: ${parent_id}" "${timestamp}"

  # 在父 issue 中记录
  issue_trace_record "${parent_id}" "PLAN" "创建子任务: ${full_id} — ${summary}"

  echo "${trace_file}"
}

###############################################################################
# ── GitHub Issue 集成 ────────────────────────────────────────────────────────
# 文档第14节要求：一任务一 issue、ledger comment
# 所有 GitHub 操作优雅降级：gh 不可用时不报错，只写本地文件
###############################################################################

###############################################################################
# _trace_sanitize_for_github — 过滤敏感信息，防止 API key/token/密码泄露到 GitHub
# 参数：$1 = 原始文本
# 输出：过滤后的文本（敏感内容替换为 [REDACTED]）
# 匹配规则：
#   - sk-... / sk_... 风格 API key（OpenAI/Anthropic 等）
#   - Bearer token
#   - password=... / passwd=... / pwd=...
#   - token=... / api_key=... / apikey=... / secret=...
#   - AWS 风格 AKIA... key
#   - ghp_... / gho_... / ghs_... GitHub token
#   - Base64 风格长密钥串（40+ 连续字母数字）
###############################################################################
_trace_sanitize_for_github() {
  local text="$1"
  # sk-... 或 sk_live_... 风格 API key
  text=$(echo "${text}" | sed -E 's/sk[-_][A-Za-z0-9_-]{20,}/[REDACTED]/g')
  # Bearer token
  text=$(echo "${text}" | sed -E 's/Bearer [A-Za-z0-9._-]+/Bearer [REDACTED]/gi')
  # password=... / passwd=... / pwd=...（等号或冒号后面的值）
  text=$(echo "${text}" | sed -E 's/(password|passwd|pwd)[=:][^ "'\'']+/\1=[REDACTED]/gi')
  # token=... / api_key=... / apikey=... / secret=... / access_key=...
  text=$(echo "${text}" | sed -E 's/(token|api_key|apikey|secret|access_key|secret_key)[=:][^ "'\'']+/\1=[REDACTED]/gi')
  # AWS AKIA... style key
  text=$(echo "${text}" | sed -E 's/AKIA[A-Z0-9]{16}/[REDACTED]/g')
  # GitHub personal/OAuth/server token (ghp_... gho_... ghs_...)
  text=$(echo "${text}" | sed -E 's/gh[pos]_[A-Za-z0-9_]{36,}/[REDACTED]/g')
  echo "${text}"
}

###############################################################################
# issue_trace_gh_available — 检查 gh CLI 是否可用且已认证
# 返回：0=可用, 1=不可用
###############################################################################
issue_trace_gh_available() {
  command -v gh &>/dev/null || return 1
  gh auth status &>/dev/null 2>&1 || return 1
  return 0
}

###############################################################################
# _issue_trace_gh_enabled — 检查配置中 GitHub 集成是否启用且 gh 可用
# 读取 bashclaw.json 的 issue_trace.github.enabled 字段
# 返回：0=已启用, 1=未启用
###############################################################################
_issue_trace_gh_enabled() {
  local config_file="${BASHCLAW_ROOT}/bashclaw.json"
  if [[ ! -f "${config_file}" ]]; then
    return 1
  fi

  # 需要 jq 来解析 JSON 配置
  if ! command -v jq &>/dev/null; then
    return 1
  fi

  local enabled
  enabled=$(jq -r '.issue_trace.github.enabled // false' "${config_file}" 2>/dev/null) || return 1
  if [[ "${enabled}" != "true" ]]; then
    return 1
  fi

  # 检查 gh 是否可用且已认证
  issue_trace_gh_available || return 1
  return 0
}

###############################################################################
# issue_trace_gh_create_issue — 使用 gh issue create 创建 GitHub issue
# 参数：$1 = task_id
#        $2 = title
#        $3 = body (可选)
# 输出：issue number（成功时），空字符串（失败/降级时）
# 返回：0=成功或优雅降级, 1 不使用（始终 0 以避免中断流程）
###############################################################################
issue_trace_gh_create_issue() {
  local task_id="$1"
  local title="$2"
  local body="${3:-}"

  if ! _issue_trace_gh_enabled; then
    echo ""
    return 0
  fi

  # Medium #13 修复：过滤敏感信息，防止 API key/token/密码泄露到 GitHub
  title=$(_trace_sanitize_for_github "${title}")
  body=$(_trace_sanitize_for_github "${body}")

  # 读取标签配置
  local config_file="${BASHCLAW_ROOT}/bashclaw.json"
  local labels
  labels=$(jq -r '(.issue_trace.github.labels // []) | join(",")' "${config_file}" 2>/dev/null) || labels=""

  # 构建 issue body，包含 ledger 标记以便后续查找更新
  local issue_body="${_GH_LEDGER_MARKER}
## BashClaw Task: ${task_id}

${body}

---
*Auto-created by BashClaw V1 Issue Trace*"

  # 创建 GitHub issue
  local gh_args=("issue" "create" "--title" "${title}" "--body" "${issue_body}")
  if [[ -n "${labels}" ]]; then
    gh_args+=("--label" "${labels}")
  fi

  local issue_num
  issue_num=$(gh "${gh_args[@]}" 2>/dev/null | grep -oE '[0-9]+$') || true

  if [[ -n "${issue_num}" ]]; then
    # 保存 task_id -> issue_number 映射
    local map_file="${ISSUE_TRACE_DIR}/.gh_issue_map"
    mkdir -p "${ISSUE_TRACE_DIR}"
    echo "${task_id}=${issue_num}" >> "${map_file}"
    audit_log_event "ISSUE_TRACE" "gh_issue_created" \
      "task_id=${task_id} issue=#${issue_num}"
  fi

  echo "${issue_num}"
}

###############################################################################
# _issue_trace_gh_get_number — 获取 task_id 对应的 GitHub issue number
# 参数：$1 = task_id
# 输出：issue number
# 返回：0=找到, 1=未找到
###############################################################################
_issue_trace_gh_get_number() {
  local task_id="$1"
  local map_file="${ISSUE_TRACE_DIR}/.gh_issue_map"
  [[ -f "${map_file}" ]] || return 1
  local line
  line=$(grep "^${task_id}=" "${map_file}" | tail -1) || return 1
  local num="${line#*=}"
  [[ -n "${num}" ]] || return 1
  echo "${num}"
}

###############################################################################
# issue_trace_gh_add_comment — 使用 gh issue comment 添加评论
# 参数：$1 = issue_number
#        $2 = body
# 返回：0=成功或优雅降级
###############################################################################
issue_trace_gh_add_comment() {
  local issue_number="$1"
  local body="$2"

  if ! _issue_trace_gh_enabled; then
    return 0
  fi

  # Medium #13 修复：过滤敏感信息，防止泄露到 GitHub comment
  body=$(_trace_sanitize_for_github "${body}")

  gh issue comment "${issue_number}" --body "${body}" &>/dev/null || true
  return 0
}

###############################################################################
# issue_trace_gh_update_ledger — 更新 GitHub issue 的 ledger comment
# 查找带有 <!-- BASHCLAW_LEDGER --> 标记的 comment 并更新
# 如果不存在则创建新 comment
# 参数：$1 = issue_number
#        $2 = ledger_content (完整的 ledger markdown)
# 返回：0=成功或优雅降级
###############################################################################
issue_trace_gh_update_ledger() {
  local issue_number="$1"
  local ledger_content="$2"

  if ! _issue_trace_gh_enabled; then
    return 0
  fi

  # Medium #13 修复：过滤敏感信息，防止泄露到 GitHub ledger comment
  ledger_content=$(_trace_sanitize_for_github "${ledger_content}")

  # 查找已有的 ledger comment（通过标记识别）
  local comment_id
  comment_id=$(gh api "repos/{owner}/{repo}/issues/${issue_number}/comments" \
    --jq ".[] | select(.body | contains(\"${_GH_LEDGER_MARKER}\")) | .id" \
    2>/dev/null | head -1) || true

  local full_body="${_GH_LEDGER_MARKER}
## BashClaw Ledger

${ledger_content}

---
*Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)*"

  if [[ -n "${comment_id}" ]]; then
    # 更新现有 ledger comment
    gh api "repos/{owner}/{repo}/issues/comments/${comment_id}" \
      -X PATCH -f body="${full_body}" &>/dev/null || true
  else
    # 创建新 ledger comment
    gh issue comment "${issue_number}" --body "${full_body}" &>/dev/null || true
  fi

  return 0
}

###############################################################################
# _issue_trace_gh_sync — 在记录节点后同步到 GitHub
# 写本地文件后调用此函数，将关键节点同步到 GitHub issue
# 参数：$1 = task_id
#        $2 = node
#        $3 = summary
# 内部函数，始终返回 0（不对外暴露失败）
###############################################################################
_issue_trace_gh_sync() {
  local task_id="$1"
  local node="$2"
  local summary="$3"

  # 快速检查是否启用
  if ! _issue_trace_gh_enabled; then
    return 0
  fi

  local issue_number
  issue_number=$(_issue_trace_gh_get_number "${task_id}") || return 0

  # 只在关键节点添加独立 comment（避免噪声）
  case "${node}" in
    INTAKE|REVIEW_ISSUES|EVIDENCE_RESOLUTION|HUMAN_DECISION|MEMORY_WRITEBACK|FINAL_DELIVERY)
      issue_trace_gh_add_comment "${issue_number}" \
        "### [$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${node}
${summary}"
      ;;
  esac

  # 读取本地 trace 文件的 Ledger 部分，同步更新 ledger comment
  local trace_file="${ISSUE_TRACE_DIR}/${task_id}.md"
  if [[ -f "${trace_file}" ]]; then
    local ledger_content
    ledger_content=$(sed -n '/^## Ledger/,$ p' "${trace_file}" | tail -n +2) || ledger_content=""
    if [[ -n "${ledger_content}" ]]; then
      issue_trace_gh_update_ledger "${issue_number}" "${ledger_content}" || true
    fi
  fi

  return 0
}

###############################################################################
# issue_trace_gh_close — 关闭 GitHub Issue
# 参数：$1 = task_id
# 返回：0=成功或优雅降级
###############################################################################
issue_trace_gh_close() {
  local task_id="$1"

  if ! _issue_trace_gh_enabled; then
    return 0
  fi

  local issue_num
  issue_num=$(_issue_trace_gh_get_number "${task_id}") || return 0
  [[ -n "${issue_num}" ]] || return 0
  gh issue close "${issue_num}" &>/dev/null || true
  return 0
}
