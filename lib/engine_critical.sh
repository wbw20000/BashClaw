#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# engine_critical.sh — BashClaw V1 Tier 3 Critical 编排引擎
#
# 文档参考：统一实施与验证文档 第6.3节
#
# 完整流程：
#   Knowledge Gate → Executor → Base Validation → Reviewer →
#   Evidence Resolution → Human Escalation → 人类裁决 →
#   必须回写第二大脑
#
# 核心原则：
#   - 不再是"调 OpenClaw 假装仲裁模型"
#   - 而是高风险问题的证据裁决与人工裁决流程
#   - 人类决策必须回写第二大脑
###############################################################################

# 防止重复 source
[[ -n "${_ENGINE_CRITICAL_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_ENGINE_CRITICAL_SH_LOADED=1

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── source 所有依赖模块 ──────────────────────────────────────────────
# 知识门（dev-1）— P0修复：移除旧stub knowledge_gate_query，实际函数为 knowledge_gate_run
if [[ -f "${BASHCLAW_ROOT}/lib/knowledge_gate.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/knowledge_gate.sh"
else
  # stub: 如果 knowledge_gate.sh 还不存在，使用正确的函数名 knowledge_gate_run
  knowledge_gate_run() {
    echo '{"knowledge_gate":"stub","similar_decisions":[],"known_pitfalls":[],"recommended_patterns":[],"confidence":"low","action_hint":"require_review"}'
  }
fi

# 执行器（dev-1）
if [[ -f "${BASHCLAW_ROOT}/lib/executor.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/executor.sh"
else
  executor_run() {
    echo "[EXECUTOR] (stub - module not yet available)"
    echo "SUMMARY: stub execution"
    return 0
  }
fi

# 基础验证（dev-1）— P0修复：移除旧stub base_validation_run，实际函数为 validator_run（来自 validator_repo.sh）
if [[ -f "${BASHCLAW_ROOT}/lib/validator_repo.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/validator_repo.sh"
else
  # stub: 如果 validator_repo.sh 还不存在，使用正确的函数名 validator_run
  validator_run() {
    echo '{"validation":{"status":"PASS","results":[]}}'
    return 0
  }
fi

# Reviewer（dev-2）— P0修复：移除旧stub reviewer_run，实际函数为 run_review（来自 reviewer.sh）
if [[ -f "${BASHCLAW_ROOT}/lib/reviewer.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/reviewer.sh"
else
  # stub: 如果 reviewer.sh 还不存在，使用正确的函数名 run_review
  run_review() {
    echo '{"issues":[],"status":"COMPLETED","valid_count":0}'
    return 0
  }
fi

# 证据驱动裁决（dev-2）— P0修复：移除旧stub evidence_resolution_run，实际函数为 run_evidence_resolution（来自 evidence_resolution.sh）
if [[ -f "${BASHCLAW_ROOT}/lib/evidence_resolution.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/evidence_resolution.sh"
else
  # stub: 如果 evidence_resolution.sh 还不存在，使用正确的函数名 run_evidence_resolution
  run_evidence_resolution() {
    local issues_file="${1:-}"
    if [[ -f "${issues_file}" ]]; then
      cat "${issues_file}"
    else
      echo "[]"
    fi
  }
fi

# 人工升级
# shellcheck source=/dev/null
source "${BASHCLAW_ROOT}/lib/human_escalation.sh"

# 知识回写
# shellcheck source=/dev/null
source "${BASHCLAW_ROOT}/lib/memory_writeback.sh"

# 预算
# shellcheck source=/dev/null
source "${BASHCLAW_ROOT}/lib/budget.sh"

# Issue Trace
# shellcheck source=/dev/null
source "${BASHCLAW_ROOT}/lib/issue_trace.sh"

# 审计日志
if [[ -f "${BASHCLAW_ROOT}/lib/audit_log.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/audit_log.sh"
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
# engine_critical_run — 执行 Tier 3 Critical 完整流程
#
# 参数：
#   $1 = task_id — 唯一任务标识
#   $2 = original_requirement — 原始需求描述
#   $3 = (可选) context_json — 任务上下文 JSON 文件
#
# 返回：
#   0 = 最终交付成功
#   1 = 流程中断（需人工介入后继续）
#
# 输出：流程各阶段结果到 stdout
###############################################################################
engine_critical_run() {
  local task_id="$1"
  local original_requirement="$2"
  local context_file="${3:-}"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local work_dir="${BASHCLAW_ROOT}/.bashclaw/runs/${task_id}"
  mkdir -p "${work_dir}"

  echo "=========================================="
  echo "[CRITICAL] 开始 Tier 3 流程: ${task_id}"
  echo "[CRITICAL] 时间: ${timestamp}"
  echo "=========================================="

  # ── Step 0: 预算检查 ──────────────────────────────────────────────
  budget_init
  if ! budget_check_tier3; then
    echo "[CRITICAL] Tier3 超预算。需要显式升级才能继续。" >&2
    issue_trace_create "${task_id}" "${original_requirement}" "tier3" > /dev/null
    issue_trace_record "${task_id}" "INTAKE" \
      "Tier3 流程启动被预算限制阻止。"
    audit_log_event "ENGINE_CRITICAL" "budget_blocked" "task_id=${task_id}"
    return 1
  fi
  budget_record_tier3

  # ── Step 1: 创建 Issue Trace ──────────────────────────────────────
  issue_trace_create "${task_id}" "${original_requirement}" "tier3" > /dev/null
  echo "[CRITICAL] Step 1/8: Issue Trace 已创建"

  # ── Step 2: Knowledge Gate ────────────────────────────────────────
  # P0修复：knowledge_gate_query → knowledge_gate_run（来自 lib/knowledge_gate.sh）
  echo "[CRITICAL] Step 2/8: Knowledge Gate 预检..."
  local knowledge_result
  knowledge_result=$(knowledge_gate_run "${original_requirement}" "${original_requirement}" "" "" "" "" "" "3" 2>/dev/null || echo "(knowledge gate unavailable)")
  echo "${knowledge_result}" > "${work_dir}/knowledge_precheck.txt"
  issue_trace_record_knowledge_precheck "${task_id}" "${knowledge_result}"
  echo "[CRITICAL] Knowledge Gate 完成"

  # ── Step 3: Executor ──────────────────────────────────────────────
  echo "[CRITICAL] Step 3/8: Executor 执行..."
  local executor_result
  executor_result=$(executor_run "${original_requirement}" "${work_dir}/knowledge_precheck.txt" 2>/dev/null || echo "(executor unavailable)")
  echo "${executor_result}" > "${work_dir}/executor_result.txt"
  issue_trace_record_executor_result "${task_id}" "Executor 已完成执行"
  echo "[CRITICAL] Executor 完成"

  # ── Step 4: Base Validation ───────────────────────────────────────
  # P0修复：base_validation_run → validator_run（来自 lib/validator_repo.sh）
  echo "[CRITICAL] Step 4/8: Base Validation..."
  local validation_result
  validation_result=$(validator_run "." "" 2>/dev/null || echo "NO_VALIDATOR_FOUND")
  echo "${validation_result}" > "${work_dir}/base_validation.txt"
  issue_trace_record_base_validation "${task_id}" "Base Validation 结果: ${validation_result}"
  echo "[CRITICAL] Base Validation 结果: ${validation_result}"

  # ── Step 5: Reviewer ──────────────────────────────────────────────
  # P0修复：reviewer_run → run_review（来自 lib/reviewer.sh）
  echo "[CRITICAL] Step 5/8: Reviewer 复查..."
  local reviewer_issues
  reviewer_issues=$(run_review "${original_requirement}" "" "${validation_result}" "${knowledge_result}" "" "" 2>/dev/null || echo '{"issues":[]}')
  echo "${reviewer_issues}" > "${work_dir}/reviewer_issues.json"
  issue_trace_record_review_issues "${task_id}" \
    "Reviewer 提出 issues（详见 artifact）" \
    "${work_dir}/reviewer_issues.json"
  echo "[CRITICAL] Reviewer 完成"

  # ── Step 6: Evidence-Driven Resolution ────────────────────────────
  # P0修复：evidence_resolution_run → run_evidence_resolution（来自 lib/evidence_resolution.sh）
  echo "[CRITICAL] Step 6/8: 证据驱动裁决..."
  local resolution_result
  resolution_result=$(run_evidence_resolution "${reviewer_issues}" "${validation_result}" "." "" 2>/dev/null || echo "[]")
  echo "${resolution_result}" > "${work_dir}/resolution_results.json"

  # 统计裁决结果
  local confirmed=0 refuted=0 unverifiable=0 req_conflict=0
  if command -v jq &>/dev/null && [[ -f "${work_dir}/resolution_results.json" ]]; then
    confirmed=$(jq '[.[] | select(.verdict == "CONFIRMED")] | length' "${work_dir}/resolution_results.json" 2>/dev/null || echo 0)
    refuted=$(jq '[.[] | select(.verdict == "REFUTED")] | length' "${work_dir}/resolution_results.json" 2>/dev/null || echo 0)
    unverifiable=$(jq '[.[] | select(.verdict == "UNVERIFIABLE")] | length' "${work_dir}/resolution_results.json" 2>/dev/null || echo 0)
    req_conflict=$(jq '[.[] | select(.verdict == "REQUIREMENT_CONFLICT")] | length' "${work_dir}/resolution_results.json" 2>/dev/null || echo 0)
  fi

  local resolution_summary="裁决结果: CONFIRMED=${confirmed} REFUTED=${refuted} UNVERIFIABLE=${unverifiable} REQUIREMENT_CONFLICT=${req_conflict}"
  issue_trace_record_evidence_resolution "${task_id}" "${resolution_summary}"
  echo "[CRITICAL] ${resolution_summary}"

  # ── Step 7: Human Escalation（Tier 3 必须经过人工） ──────────────
  echo "[CRITICAL] Step 7/8: Human Escalation..."

  # 检查是否需要升级（Tier 3 默认需要人工）
  local needs_escalation=true
  local trigger_reasons="Tier 3 Critical 流程默认需要人工裁决"

  # 额外检查：是否有 UNVERIFIABLE 或 REQUIREMENT_CONFLICT
  if [[ -f "${work_dir}/resolution_results.json" ]]; then
    local extra_reasons
    extra_reasons=$(escalation_should_trigger "${work_dir}/resolution_results.json" 2>/dev/null || true)
    if [[ -n "${extra_reasons}" ]]; then
      trigger_reasons="${trigger_reasons}\n${extra_reasons}"
    fi
  fi

  # 执行升级
  local escalation_report
  escalation_report=$(escalation_execute \
    "${task_id}" \
    "${original_requirement}" \
    "$(cat "${work_dir}/knowledge_precheck.txt" 2>/dev/null || echo "N/A")" \
    "$(cat "${work_dir}/executor_result.txt" 2>/dev/null || echo "N/A")" \
    "$(cat "${work_dir}/base_validation.txt" 2>/dev/null || echo "N/A")" \
    "${work_dir}/reviewer_issues.json" \
    "${work_dir}/resolution_results.json" \
    2>/dev/null)

  echo "${escalation_report}"
  echo ""
  echo "[CRITICAL] 人工升级报告已生成，等待人工裁决。"
  echo "[CRITICAL] 请调用 engine_critical_complete_decision 提交裁决结果。"

  # 保存中间状态
  echo "AWAITING_HUMAN_DECISION" > "${work_dir}/status"

  audit_log_event "ENGINE_CRITICAL" "awaiting_human" "task_id=${task_id}"

  return 1
}

###############################################################################
# engine_critical_complete_decision — 人工裁决后完成 Tier 3 流程
#
# 参数：
#   $1 = task_id
#   $2 = decision (ACCEPT/REJECT/MODIFY/NEED_MORE_INFO)
#   $3 = decision_detail (裁决说明)
#
# 返回：0=完成, 1=需要更多信息
###############################################################################
engine_critical_complete_decision() {
  local task_id="$1"
  local decision="$2"
  local decision_detail="$3"

  local work_dir="${BASHCLAW_ROOT}/.bashclaw/runs/${task_id}"

  if [[ ! -d "${work_dir}" ]]; then
    echo "[CRITICAL] 找不到任务工作目录: ${task_id}" >&2
    return 1
  fi

  local status_file="${work_dir}/status"
  if [[ -f "${status_file}" ]]; then
    local current_status
    current_status=$(cat "${status_file}")
    if [[ "${current_status}" != "AWAITING_HUMAN_DECISION" ]]; then
      echo "[CRITICAL] 任务状态不正确: ${current_status}，期望 AWAITING_HUMAN_DECISION" >&2
      return 1
    fi
  fi

  echo "=========================================="
  echo "[CRITICAL] 接收人工裁决: ${task_id}"
  echo "[CRITICAL] 裁决: ${decision}"
  echo "=========================================="

  # ── 记录人工裁决 ──────────────────────────────────────────────────
  local decision_file
  decision_file=$(escalation_record_decision "${task_id}" "${decision}" "${decision_detail}")
  echo "[CRITICAL] 裁决已记录: ${decision_file}"

  # 如果需要更多信息，暂不完成流程
  if [[ "${decision}" == "NEED_MORE_INFO" ]]; then
    echo "NEED_MORE_INFO" > "${work_dir}/status"
    echo "[CRITICAL] 需要更多信息，流程暂停。"
    audit_log_event "ENGINE_CRITICAL" "need_more_info" "task_id=${task_id}"
    return 1
  fi

  # ── Step 8: 必须回写第二大脑 ──────────────────────────────────────
  echo "[CRITICAL] Step 8/8: Memory Writeback..."

  # 构建回写上下文
  local context_file="${work_dir}/writeback_context.json"
  _critical_build_writeback_context "${task_id}" "${decision}" "${decision_detail}" > "${context_file}"

  # 执行回写
  local writeback_result
  writeback_result=$(writeback_from_escalation \
    "${task_id}" \
    "${decision_file}" \
    "${context_file}" 2>&1)
  echo "[CRITICAL] 知识回写完成: ${writeback_result}"

  # 记录到 issue trace
  issue_trace_record_memory_writeback "${task_id}" \
    "Tier3 人工裁决知识已回写: ${writeback_result}"

  # ── 最终交付 ──────────────────────────────────────────────────────
  local final_status
  case "${decision}" in
    ACCEPT)
      final_status="DELIVERED"
      ;;
    REJECT)
      final_status="REJECTED"
      ;;
    MODIFY)
      final_status="DELIVERED_WITH_MODIFICATIONS"
      ;;
    *)
      final_status="COMPLETED"
      ;;
  esac

  issue_trace_record_final_delivery "${task_id}" \
    "Tier3 流程完成。人工裁决: ${decision}。最终状态: ${final_status}"

  echo "${final_status}" > "${work_dir}/status"

  echo "=========================================="
  echo "[CRITICAL] Tier 3 流程完成"
  echo "[CRITICAL] 最终状态: ${final_status}"
  echo "=========================================="

  audit_log_event "ENGINE_CRITICAL" "completed" \
    "task_id=${task_id} decision=${decision} status=${final_status}"

  return 0
}

###############################################################################
# _critical_build_writeback_context — 构建回写所需的上下文 JSON
# 参数：$1=task_id, $2=decision, $3=detail
# 输出：JSON 到 stdout
###############################################################################
_critical_build_writeback_context() {
  local task_id="$1"
  local decision="$2"
  local detail="$3"
  local work_dir="${BASHCLAW_ROOT}/.bashclaw/runs/${task_id}"

  local knowledge_summary="N/A"
  if [[ -f "${work_dir}/knowledge_precheck.txt" ]]; then
    knowledge_summary=$(head -5 "${work_dir}/knowledge_precheck.txt")
  fi

  cat <<EOF
{
  "task_id": "${task_id}",
  "decision_title": "Critical decision: ${task_id}",
  "task_summary": "Tier 3 critical task with human decision: ${decision}",
  "applicable_scope": "$(echo "${knowledge_summary}" | head -1)",
  "non_applicable_scope": "",
  "final_decision": "${decision}",
  "why": "${detail}",
  "knowledge_precheck": "${knowledge_summary}"
}
EOF
}

###############################################################################
# engine_critical_get_status — 获取 Tier 3 任务当前状态
# 参数：$1 = task_id
# 输出：状态字符串
###############################################################################
engine_critical_get_status() {
  local task_id="$1"
  local work_dir="${BASHCLAW_ROOT}/.bashclaw/runs/${task_id}"
  local status_file="${work_dir}/status"

  if [[ ! -f "${status_file}" ]]; then
    echo "NOT_FOUND"
    return 1
  fi

  cat "${status_file}"
}
