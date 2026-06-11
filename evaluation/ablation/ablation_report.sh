#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ablation_report.sh — 消融实验报告生成（文档第22.3节 + 第32节）
#
# 回答5个核心问题：
# 1. Knowledge Gate 独立带来多少收益？
# 2. Memory Writeback 独立带来多少收益？
# 3. Reviewer 不加证据裁决时噪声多大？
# 4. Evidence Resolution 降低多少 unverifiable 比例？
# 5. Human Escalation 去掉后哪些问题最先失效？
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/ablation"
REPORT_DIR="${RESULTS_DIR}"
_require_jq

SUMMARY="${RESULTS_DIR}/ablation_summary.json"

if [[ ! -f "$SUMMARY" ]]; then
  echo "ERROR: Ablation results not found. Run run_ablation.sh first." >&2
  exit 1
fi

echo "============================================================"
echo "  BashClaw V1 — 组件消融分析报告"
echo "  Generated: $(eval_timestamp)"
echo "============================================================"
echo ""

###############################################################################
# 读取各组数据
###############################################################################

get_group_metric() {
  local group="$1" metric="$2"
  jq --arg g "$group" --arg m "$metric" \
    '[.[] | select(.group == $g)] | .[0][$m] // 0' "$SUMMARY"
}

# Baseline (A0)
A0_RESOLVED=$(get_group_metric "A0" "resolved_rate")
A0_TOKENS=$(get_group_metric "A0" "token_per_resolved")
A0_REVIEW=$(get_group_metric "A0" "review_trigger_rate")
A0_HUMAN=$(get_group_metric "A0" "human_escalation_rate")
A0_REGRESSION=$(get_group_metric "A0" "regression_rate")

echo "=== Baseline (A0: 单模型 + Base Validation) ==="
echo "  Resolved Rate:         ${A0_RESOLVED}%"
echo "  Token/Resolved:        ${A0_TOKENS}"
echo "  Review Trigger Rate:   ${A0_REVIEW}%"
echo "  Human Escalation Rate: ${A0_HUMAN}%"
echo "  Regression Rate:       ${A0_REGRESSION}%"
echo ""

###############################################################################
# 问题1: Knowledge Gate 独立带来多少收益？ (A1 vs A0)
###############################################################################

echo "=== 问题1: Knowledge Gate 独立收益 (A1 vs A0) ==="
A1_RESOLVED=$(get_group_metric "A1" "resolved_rate")
A1_TOKENS=$(get_group_metric "A1" "token_per_resolved")

resolved_delta=$(echo "$A1_RESOLVED - $A0_RESOLVED" | bc -l 2>/dev/null || echo "0")
token_delta=$(echo "$A0_TOKENS - $A1_TOKENS" | bc -l 2>/dev/null || echo "0")
if (( $(echo "$A0_TOKENS > 0" | bc -l 2>/dev/null || echo "0") )); then
  token_pct=$(echo "scale=1; $token_delta / $A0_TOKENS * 100" | bc -l 2>/dev/null || echo "0")
else
  token_pct="0"
fi

echo "  Resolved Rate Delta:  ${resolved_delta} pp"
echo "  Token Reduction:      ${token_delta} (${token_pct}%)"

if (( $(echo "$token_delta > 0" | bc -l 2>/dev/null || echo "0") )); then
  echo "  --> Knowledge Gate 提供正向收益"
else
  echo "  --> Knowledge Gate 未提供显著收益"
fi
echo ""

###############################################################################
# 问题2: Memory Writeback 独立收益？ (A2 vs A1)
###############################################################################

echo "=== 问题2: Memory Writeback 独立收益 (A2 vs A1) ==="
A2_RESOLVED=$(get_group_metric "A2" "resolved_rate")
A2_TOKENS=$(get_group_metric "A2" "token_per_resolved")

mw_resolved_delta=$(echo "$A2_RESOLVED - $A1_RESOLVED" | bc -l 2>/dev/null || echo "0")
mw_token_delta=$(echo "$A1_TOKENS - $A2_TOKENS" | bc -l 2>/dev/null || echo "0")
if (( $(echo "$A1_TOKENS > 0" | bc -l 2>/dev/null || echo "0") )); then
  mw_token_pct=$(echo "scale=1; $mw_token_delta / $A1_TOKENS * 100" | bc -l 2>/dev/null || echo "0")
else
  mw_token_pct="0"
fi

echo "  Resolved Rate Delta:  ${mw_resolved_delta} pp"
echo "  Token Reduction:      ${mw_token_delta} (${mw_token_pct}%)"

if (( $(echo "$mw_token_delta > 0" | bc -l 2>/dev/null || echo "0") )); then
  echo "  --> Memory Writeback 提供增益（闭环学习有效）"
else
  echo "  --> Memory Writeback 未提供增量收益"
fi
echo ""

###############################################################################
# 问题3: Reviewer 不加证据裁决时噪声多大？ (B1 unverifiable rate)
###############################################################################

echo "=== 问题3: Reviewer 无证据裁决时的噪声 (B1) ==="
B1_RESOLVED=$(get_group_metric "B1" "resolved_rate")
B1_TOKENS=$(get_group_metric "B1" "token_per_resolved")

B1_RESULTS="${RESULTS_DIR}/results_B1.json"
if [[ -f "$B1_RESULTS" ]]; then
  b1_unv_rate=$(calc_unverifiable_rate "$B1_RESULTS")
  b1_evidence_rate=$(calc_evidence_auto_resolution_rate "$B1_RESULTS")
  echo "  Unverifiable Issue Rate:   ${b1_unv_rate}%"
  echo "  Evidence Auto-Resolution:  ${b1_evidence_rate}%"
  echo "  --> 无证据裁决时，所有 review issues 均为 unverifiable"
else
  echo "  (B1 详细结果文件不可用)"
fi
echo ""

###############################################################################
# 问题4: Evidence Resolution 降低多少 unverifiable 比例？ (B2 vs B1)
###############################################################################

echo "=== 问题4: Evidence Resolution 效果 (B2 vs B1) ==="
B2_RESOLVED=$(get_group_metric "B2" "resolved_rate")
B2_TOKENS=$(get_group_metric "B2" "token_per_resolved")

B2_RESULTS="${RESULTS_DIR}/results_B2.json"
if [[ -f "$B2_RESULTS" ]]; then
  b2_unv_rate=$(calc_unverifiable_rate "$B2_RESULTS")
  b2_evidence_rate=$(calc_evidence_auto_resolution_rate "$B2_RESULTS")
  echo "  B1 Unverifiable Rate: ${b1_unv_rate:-N/A}%"
  echo "  B2 Unverifiable Rate: ${b2_unv_rate}%"
  echo "  B2 Evidence Auto-Resolution: ${b2_evidence_rate}%"

  if [[ -n "${b1_unv_rate:-}" ]]; then
    unv_reduction=$(echo "${b1_unv_rate} - ${b2_unv_rate}" | bc -l 2>/dev/null || echo "0")
    echo "  Unverifiable Reduction: ${unv_reduction} pp"
    echo "  --> Evidence Resolution 将 ${unv_reduction}pp 的 issues 从 unverifiable 转为可裁决"
  fi
else
  echo "  (B2 详细结果文件不可用)"
fi
echo ""

###############################################################################
# 问题5: Human Escalation 去掉后哪些问题最先失效？ (C4 vs C1, 如果有)
###############################################################################

echo "=== 问题5: Human Escalation 的价值 ==="
C1_RESOLVED=$(get_group_metric "C1" "resolved_rate")
C1_TOKENS=$(get_group_metric "C1" "token_per_resolved")

# 检查是否有 C4 扩展组
C4_RESOLVED=$(get_group_metric "C4" "resolved_rate")
if [[ "$C4_RESOLVED" != "0" ]]; then
  he_delta=$(echo "$C1_RESOLVED - $C4_RESOLVED" | bc -l 2>/dev/null || echo "0")
  echo "  C1 (full) Resolved Rate: ${C1_RESOLVED}%"
  echo "  C4 (no HE) Resolved Rate: ${C4_RESOLVED}%"
  echo "  Delta: ${he_delta} pp"

  # 分析哪些类别问题失效
  C4_RESULTS="${RESULTS_DIR}/results_C4.json"
  C1_RESULTS="${RESULTS_DIR}/results_C1.json"
  if [[ -f "$C4_RESULTS" && -f "$C1_RESULTS" ]]; then
    echo ""
    echo "  失效分析（C1能解 C4不能解的任务）:"

    # 按 cluster 分析
    for cluster in auth-token payment-validation auth-permission schema-migration infra-deploy; do
      c1_solve=$(jq --arg c "$cluster" \
        '[.[] | select(.cluster_id == $c and .resolved == true)] | length' "$C1_RESULTS")
      c4_solve=$(jq --arg c "$cluster" \
        '[.[] | select(.cluster_id == $c and .resolved == true)] | length' "$C4_RESULTS")
      c_total=$(jq --arg c "$cluster" \
        '[.[] | select(.cluster_id == $c)] | length' "$C1_RESULTS")

      if (( c_total > 0 )); then
        echo "    ${cluster}: C1=${c1_solve}/${c_total}, C4=${c4_solve}/${c_total}"
      fi
    done
  fi
else
  echo "  (C4 扩展组未运行，使用 --extended 参数运行完整矩阵)"
fi
echo ""

###############################################################################
# 总体汇总表
###############################################################################

echo "============================================================"
echo "  消融实验汇总表"
echo "============================================================"
printf "%-8s %-12s %-14s %-12s %-12s %-10s\n" \
  "Group" "Resolved%" "Tokens/Rslv" "Review%" "Human%" "Regress%"
printf "%-8s %-12s %-14s %-12s %-12s %-10s\n" \
  "-----" "--------" "-----------" "-------" "------" "--------"

jq -r '.[] | [.group, .resolved_rate, .token_per_resolved, .review_trigger_rate, .human_escalation_rate, .regression_rate] |
  @tsv' "$SUMMARY" | while IFS=$'\t' read -r g rr tr rvr hr regr; do
  printf "%-8s %-12s %-14s %-12s %-12s %-10s\n" "$g" "$rr" "$tr" "$rvr" "$hr" "$regr"
done

echo ""

###############################################################################
# 验收判定（文档第32节）
###############################################################################

echo "============================================================"
echo "  消融验收判定（文档第32.2节）"
echo "============================================================"

pass_count=0
total_checks=5

# 1. Knowledge Gate 是否独立带来收益
echo "检查1: Knowledge Gate 是否独立带来收益"
if (( $(echo "${token_delta:-0} > 0" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] Knowledge Gate 减少了 ${token_pct}% 的 token 消耗"
  ((pass_count++))
else
  echo "  [FAIL] Knowledge Gate 未减少 token 消耗"
fi

# 2. Memory Writeback 是否独立带来收益
echo "检查2: Memory Writeback 是否独立带来收益"
if (( $(echo "${mw_token_delta:-0} > 0" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] Memory Writeback 额外减少了 ${mw_token_pct}% 的 token"
  ((pass_count++))
else
  echo "  [FAIL] Memory Writeback 未提供增量收益"
fi

# 3. Reviewer 不加证据裁决时是否存在明显噪声
echo "检查3: Reviewer 不加证据裁决时是否存在明显噪声"
if [[ -n "${b1_unv_rate:-}" ]] && (( $(echo "${b1_unv_rate} > 50" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] 未加证据裁决时 unverifiable rate = ${b1_unv_rate}%（证明证据裁决的必要性）"
  ((pass_count++))
else
  echo "  [WARN] 数据不足或未达阈值"
fi

# 4. Evidence Resolution 是否显著降低 unverifiable 比例
echo "检查4: Evidence Resolution 是否显著降低 unverifiable 比例"
if [[ -n "${unv_reduction:-}" ]] && (( $(echo "${unv_reduction} > 20" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] Evidence Resolution 降低了 ${unv_reduction}pp 的 unverifiable rate"
  ((pass_count++))
else
  echo "  [WARN] 降低幅度不足或数据不可用"
fi

# 5. Human Escalation 去掉后哪些类问题最先失效
echo "检查5: Human Escalation 去掉后有无明显失效"
if [[ -n "${he_delta:-}" ]] && (( $(echo "${he_delta} > 2" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] 去掉 Human Escalation 后 resolved rate 下降 ${he_delta}pp"
  ((pass_count++))
else
  echo "  [INFO] 需要运行 C4 扩展组才能完整判定"
fi

echo ""
echo "消融验收结果: ${pass_count}/${total_checks} 项通过"
if (( pass_count >= 4 )); then
  echo "==> 消融验收: PASS"
else
  echo "==> 消融验收: NEEDS REVIEW"
fi

###############################################################################
# 输出结构化 JSON 报告
###############################################################################

REPORT_JSON=$(jq -n \
  --slurpfile summary "$SUMMARY" \
  --argjson kg_token_reduction "${token_delta:-0}" \
  --argjson mw_token_reduction "${mw_token_delta:-0}" \
  --argjson unv_reduction "${unv_reduction:-0}" \
  --argjson he_delta "${he_delta:-0}" \
  --argjson pass_count "$pass_count" \
  --argjson total_checks "$total_checks" \
  '{
    "report_type": "ablation",
    "group_summaries": $summary[0],
    "analysis": {
      "knowledge_gate_token_reduction_pct": (if ($summary[0] | map(select(.group == "A0")) | .[0].token_per_resolved) > 0
        then ($kg_token_reduction / ($summary[0] | map(select(.group == "A0")) | .[0].token_per_resolved) * 100)
        else 0 end),
      "memory_writeback_additional_reduction": $mw_token_reduction,
      "unverifiable_reduction_pp": $unv_reduction,
      "human_escalation_value_pp": $he_delta
    },
    "acceptance": {
      "checks_passed": $pass_count,
      "checks_total": $total_checks,
      "verdict": (if $pass_count >= 4 then "PASS" else "NEEDS_REVIEW" end)
    }
  }')

echo "$REPORT_JSON" | jq '.' > "${RESULTS_DIR}/ablation_report.json"
echo ""
echo "JSON report: ${RESULTS_DIR}/ablation_report.json"
