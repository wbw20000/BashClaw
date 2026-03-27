#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# human_escalation.sh — BashClaw V1 人工升级兜底
#
# 文档参考：统一实施与验证文档 第12节
#
# 触发条件（6种）：
#   1. issue 被判定 UNVERIFIABLE
#   2. issue 被判定 REQUIREMENT_CONFLICT
#   3. 高风险域存在重大未裁决问题
#   4. 证据之间互相冲突
#   5. targeted validation 本身不可靠
#   6. 多个 issue 累积后总体风险过高
#
# 人类应看到的结构化上下文（不允许要求人去读原始对话）：
#   - 原始需求
#   - knowledge 预检摘要
#   - patch 摘要
#   - Base Validation 结果
#   - Reviewer issues
#   - 每个 issue 的裁决状态
#   - 推荐动作
###############################################################################

# 防止重复 source
[[ -n "${_HUMAN_ESCALATION_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_HUMAN_ESCALATION_SH_LOADED=1

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASHCLAW_CONFIG="${BASHCLAW_ROOT}/bashclaw.json"
ESCALATION_DIR="${BASHCLAW_ROOT}/.bashclaw/escalations"

# ── source 依赖 ──────────────────────────────────────────────────────
if [[ -f "${BASHCLAW_ROOT}/lib/budget.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/budget.sh"
fi

if [[ -f "${BASHCLAW_ROOT}/lib/issue_trace.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/issue_trace.sh"
fi

if [[ -f "${BASHCLAW_ROOT}/lib/audit_log.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/audit_log.sh"
fi


# 高风险域关键词（与 bashclaw.json 中 risk_keywords 对齐）
readonly HIGH_RISK_DOMAINS=("auth" "payment" "migration" "deploy" "permission" "billing" "schema" "prod")

###############################################################################
# escalation_init — 初始化升级目录
###############################################################################
escalation_init() {
  mkdir -p "${ESCALATION_DIR}"
}

###############################################################################
# _escalation_check_high_risk_domain — 检查 risk_tags 是否命中高风险域
# 参数：$1 = risk_tags (逗号分隔)
# 返回：0=命中, 1=未命中
###############################################################################
_escalation_check_high_risk_domain() {
  local risk_tags="$1"
  local domain
  for domain in "${HIGH_RISK_DOMAINS[@]}"; do
    if echo "${risk_tags}" | grep -qi "${domain}"; then
      return 0
    fi
  done
  return 1
}

###############################################################################
# escalation_should_trigger — 判断是否需要触发人工升级
#
# 参数（通过环境变量或函数参数传入）：
#   $1 = issues_json — 裁决结果 JSON 文件路径，格式：
#        [{ "id": "...", "verdict": "CONFIRMED|REFUTED|UNVERIFIABLE|REQUIREMENT_CONFLICT",
#           "severity": "...", "risk_tags": "...", "evidence_conflict": true/false,
#           "validation_unreliable": true/false }]
#
# 返回：0=需要升级, 1=不需要
# 输出到 stdout：触发原因（可能多条）
###############################################################################
escalation_should_trigger() {
  local issues_json="$1"
  local triggered=1
  local reasons=""

  if [[ ! -f "${issues_json}" ]]; then
    echo "[ESCALATION] issues 文件不存在: ${issues_json}" >&2
    return 1
  fi

  # 统计各种裁决状态
  local unverifiable_count=0
  local req_conflict_count=0
  local evidence_conflict_count=0
  local validation_unreliable_count=0
  local high_risk_unresolved=0
  local total_unresolved=0

  if command -v jq &>/dev/null; then
    unverifiable_count=$(jq '[.[] | select(.verdict == "UNVERIFIABLE")] | length' "${issues_json}")
    req_conflict_count=$(jq '[.[] | select(.verdict == "REQUIREMENT_CONFLICT")] | length' "${issues_json}")
    evidence_conflict_count=$(jq '[.[] | select(.evidence_conflict == true)] | length' "${issues_json}")
    validation_unreliable_count=$(jq '[.[] | select(.validation_unreliable == true)] | length' "${issues_json}")

    # 高风险域未裁决问题
    local risk_domains_pattern
    risk_domains_pattern=$(printf '%s|' "${HIGH_RISK_DOMAINS[@]}")
    risk_domains_pattern="${risk_domains_pattern%|}"
    high_risk_unresolved=$(jq --arg p "${risk_domains_pattern}" \
      '[.[] | select((.verdict == "UNVERIFIABLE" or .verdict == "REQUIREMENT_CONFLICT") and (.risk_tags | test($p; "i")))] | length' \
      "${issues_json}")

    total_unresolved=$(jq '[.[] | select(.verdict == "UNVERIFIABLE" or .verdict == "REQUIREMENT_CONFLICT")] | length' "${issues_json}")
  else
    # 简易 fallback：用 grep 统计
    unverifiable_count=$(grep -c '"UNVERIFIABLE"' "${issues_json}" || true)
    req_conflict_count=$(grep -c '"REQUIREMENT_CONFLICT"' "${issues_json}" || true)
    evidence_conflict_count=$(grep -c '"evidence_conflict": true' "${issues_json}" || true)
    validation_unreliable_count=$(grep -c '"validation_unreliable": true' "${issues_json}" || true)
    total_unresolved=$(( unverifiable_count + req_conflict_count ))
  fi

  # 条件1：存在 UNVERIFIABLE issue
  if (( unverifiable_count > 0 )); then
    reasons="${reasons}[UNVERIFIABLE] ${unverifiable_count} 个 issue 无法通过证据裁决\n"
    triggered=0
  fi

  # 条件2：存在 REQUIREMENT_CONFLICT issue
  if (( req_conflict_count > 0 )); then
    reasons="${reasons}[REQUIREMENT_CONFLICT] ${req_conflict_count} 个 issue 存在需求冲突\n"
    triggered=0
  fi

  # 条件3：高风险域存在重大未裁决问题
  if (( high_risk_unresolved > 0 )); then
    reasons="${reasons}[HIGH_RISK_UNRESOLVED] ${high_risk_unresolved} 个高风险域问题未裁决\n"
    triggered=0
  fi

  # 条件4：证据之间互相冲突
  if (( evidence_conflict_count > 0 )); then
    reasons="${reasons}[EVIDENCE_CONFLICT] ${evidence_conflict_count} 个 issue 的证据互相冲突\n"
    triggered=0
  fi

  # 条件5：targeted validation 本身不可靠
  if (( validation_unreliable_count > 0 )); then
    reasons="${reasons}[VALIDATION_UNRELIABLE] ${validation_unreliable_count} 个 issue 的定向验证不可靠\n"
    triggered=0
  fi

  # 条件6：多个 issue 累积后总体风险过高（阈值：>=3 个未裁决）
  if (( total_unresolved >= 3 )); then
    reasons="${reasons}[ACCUMULATED_RISK] 累计 ${total_unresolved} 个未裁决问题，总体风险过高\n"
    triggered=0
  fi

  # 额外：预算检查 — 单任务 UNVERIFIABLE 超阈值
  if type budget_check_unverifiable &>/dev/null; then
    if ! budget_check_unverifiable "${unverifiable_count}"; then
      reasons="${reasons}[BUDGET_FORCED] 单任务 UNVERIFIABLE 超预算阈值，强制人工\n"
      triggered=0
    fi
  fi

  if (( triggered == 0 )); then
    echo -e "${reasons}"
  fi

  return "${triggered}"
}

###############################################################################
# escalation_build_context — 构建人类应看到的结构化上下文
#
# 参数：
#   $1 = task_id
#   $2 = original_requirement (原始需求)
#   $3 = knowledge_precheck (知识预检摘要)
#   $4 = patch_summary (patch 摘要)
#   $5 = base_validation_result (基础验证结果)
#   $6 = reviewer_issues_file (reviewer issues JSON 文件)
#   $7 = resolution_results_file (裁决结果 JSON 文件)
#   $8 = trigger_reasons (触发原因)
#
# 输出：结构化的人类可读上下文（markdown 格式）
###############################################################################
escalation_build_context() {
  local task_id="$1"
  local original_requirement="$2"
  local knowledge_precheck="$3"
  local patch_summary="$4"
  local base_validation_result="$5"
  local reviewer_issues_file="$6"
  local resolution_results_file="$7"
  local trigger_reasons="$8"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat <<EOF
# Human Escalation Report

**Task**: ${task_id}
**Time**: ${timestamp}

---

## 1. 升级原因

${trigger_reasons}

---

## 2. 原始需求

${original_requirement}

---

## 3. Knowledge 预检摘要

${knowledge_precheck}

---

## 4. Patch 摘要

${patch_summary}

---

## 5. Base Validation 结果

${base_validation_result}

---

## 6. Reviewer Issues

$(if [[ -f "${reviewer_issues_file}" ]]; then
    if command -v jq &>/dev/null; then
      jq -r '.[] | "- [\(.issue_type)] \(.location): \(.risk_statement) (severity: \(.severity))"' "${reviewer_issues_file}" 2>/dev/null || cat "${reviewer_issues_file}"
    else
      cat "${reviewer_issues_file}"
    fi
  else
    echo "(无 reviewer issues 文件)"
  fi)

---

## 7. 裁决状态

$(if [[ -f "${resolution_results_file}" ]]; then
    if command -v jq &>/dev/null; then
      jq -r '.[] | "- [\(.verdict)] \(.id // .location): \(.risk_statement // .summary // "N/A")"' "${resolution_results_file}" 2>/dev/null || cat "${resolution_results_file}"
    else
      cat "${resolution_results_file}"
    fi
  else
    echo "(无裁决结果文件)"
  fi)

---

## 8. 推荐动作

$(escalation_recommend_actions "${resolution_results_file}" "${trigger_reasons}")

---

> **注意**：请直接根据以上结构化信息做出裁决，无需阅读原始对话。
> 您的裁决将被记录到 issue trace 并回写到第二大脑。
EOF
}

###############################################################################
# escalation_recommend_actions — 根据裁决状态生成推荐动作
# 参数：$1 = resolution results file
#        $2 = trigger reasons
# 输出：推荐动作列表
###############################################################################
escalation_recommend_actions() {
  local resolution_file="$1"
  local reasons="$2"
  local actions=""

  # 根据触发原因给出推荐
  if echo "${reasons}" | grep -q "UNVERIFIABLE"; then
    actions="${actions}- 对 UNVERIFIABLE issues 做出明确裁决（接受/拒绝/需要补充信息）\n"
  fi

  if echo "${reasons}" | grep -q "REQUIREMENT_CONFLICT"; then
    actions="${actions}- 明确需求意图，解决冲突\n"
  fi

  if echo "${reasons}" | grep -q "HIGH_RISK_UNRESOLVED"; then
    actions="${actions}- 重点审视高风险域的未裁决问题\n"
  fi

  if echo "${reasons}" | grep -q "EVIDENCE_CONFLICT"; then
    actions="${actions}- 检查冲突证据，确认哪方结论正确\n"
  fi

  if echo "${reasons}" | grep -q "VALIDATION_UNRELIABLE"; then
    actions="${actions}- 评估定向验证的可靠性，考虑手动验证\n"
  fi

  if echo "${reasons}" | grep -q "ACCUMULATED_RISK"; then
    actions="${actions}- 综合评估累积风险，考虑是否需要整体重新设计\n"
  fi

  if [[ -z "${actions}" ]]; then
    actions="- 审阅所有未裁决问题并做出最终决定\n"
  fi

  echo -e "${actions}"
}

###############################################################################
# escalation_execute — 执行人工升级流程
#
# 参数：
#   $1 = task_id
#   $2 = original_requirement
#   $3 = knowledge_precheck
#   $4 = patch_summary
#   $5 = base_validation_result
#   $6 = reviewer_issues_file
#   $7 = resolution_results_file
#
# 输出：escalation report 文件路径
###############################################################################
escalation_execute() {
  local task_id="$1"
  local original_requirement="$2"
  local knowledge_precheck="$3"
  local patch_summary="$4"
  local base_validation_result="$5"
  local reviewer_issues_file="$6"
  local resolution_results_file="$7"

  escalation_init

  # 检查预算
  if type budget_check_human_escalation &>/dev/null; then
    if ! budget_check_human_escalation; then
      echo "[ESCALATION] 人工升级超预算，但因安全原因仍需上报" >&2
      # 超预算不阻止升级，只记录警告
    fi
  fi

  # 获取触发原因
  local trigger_reasons=""
  if [[ -f "${resolution_results_file}" ]]; then
    trigger_reasons=$(escalation_should_trigger "${resolution_results_file}" 2>/dev/null || true)
  fi

  if [[ -z "${trigger_reasons}" ]]; then
    trigger_reasons="手动触发或条件未通过标准检查"
  fi

  # 构建结构化上下文
  local report
  report=$(escalation_build_context \
    "${task_id}" \
    "${original_requirement}" \
    "${knowledge_precheck}" \
    "${patch_summary}" \
    "${base_validation_result}" \
    "${reviewer_issues_file}" \
    "${resolution_results_file}" \
    "${trigger_reasons}")

  # 保存 escalation report
  local timestamp_short
  timestamp_short="$(date +%Y%m%d_%H%M%S)"
  local report_file="${ESCALATION_DIR}/${task_id}_${timestamp_short}.md"
  echo "${report}" > "${report_file}"

  # 记录预算
  if type budget_record_human_escalation &>/dev/null; then
    budget_record_human_escalation
  fi

  # 记录到 issue trace
  if type issue_trace_record &>/dev/null; then
    issue_trace_record "${task_id}" "HUMAN_DECISION" \
      "人工升级已触发。原因: ${trigger_reasons}。等待人工裁决。"
  fi

  # 审计日志
  audit_log_event "HUMAN_ESCALATION" "executed" \
    "task_id=${task_id} report=${report_file}"

  # 输出 report 到 stdout 供调用方展示给用户
  echo "${report}"

  # 返回文件路径到 stderr
  echo "${report_file}" >&2
}

###############################################################################
# escalation_record_decision — 记录人工裁决结果
#
# 参数：
#   $1 = task_id
#   $2 = decision (ACCEPT/REJECT/MODIFY/NEED_MORE_INFO)
#   $3 = decision_detail (人工裁决说明)
#   $4 = (可选) 需要回写知识库的内容
###############################################################################
escalation_record_decision() {
  local task_id="$1"
  local decision="$2"
  local decision_detail="$3"
  local writeback_content="${4:-}"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 保存裁决到文件
  local decision_file="${ESCALATION_DIR}/${task_id}_decision.json"
  cat > "${decision_file}" <<EOF
{
  "task_id": "${task_id}",
  "decision": "${decision}",
  "detail": $(echo "${decision_detail}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"${decision_detail}\""),
  "timestamp": "${timestamp}",
  "needs_writeback": $(if [[ -n "${writeback_content}" ]]; then echo "true"; else echo "false"; fi)
}
EOF

  # 记录到 issue trace
  if type issue_trace_record_human_decision &>/dev/null; then
    issue_trace_record_human_decision "${task_id}" \
      "人工裁决: ${decision}。${decision_detail}"
  fi

  audit_log_event "HUMAN_ESCALATION" "decision_recorded" \
    "task_id=${task_id} decision=${decision}"

  echo "${decision_file}"
}
