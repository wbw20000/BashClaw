#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# learning_report.sh — 闭环学习验收报告（文档第30.3节）
#
# 验收判定（必须全部满足）：
# 1. Token per Resolved Issue 下降 >= 30%
# 2. 相似问题簇 Review Trigger Rate 下降 >= 20%
# 3. 相似问题簇 Human Escalation Rate 下降 >= 20%
# 4. Harmful Retrieval Rate <= 5%
# 5. Resolved Rate 不下降超过 2 个百分点
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/learning"
_require_jq

METRICS="${RESULTS_DIR}/learning_metrics.json"
RESULTS_MEMORY="${RESULTS_DIR}/results_with_memory.json"
RESULTS_NO_MEMORY="${RESULTS_DIR}/results_no_memory.json"

if [[ ! -f "$METRICS" ]]; then
  echo "ERROR: Learning metrics not found. Run learning_metrics.sh first." >&2
  exit 1
fi

echo "============================================================"
echo "  BashClaw V1 — 闭环学习验收报告"
echo "  文档参考: 第30.3节"
echo "  Generated: $(eval_timestamp)"
echo "============================================================"
echo ""

# 读取指标
token_reduction=$(jq '.deltas.token_per_resolved_reduction_pct' "$METRICS")
resolved_delta=$(jq '.deltas.resolved_rate_delta_pp' "$METRICS")
review_reduction=$(jq '.deltas.review_trigger_rate_reduction_pp' "$METRICS")
human_reduction=$(jq '.deltas.human_escalation_rate_reduction_pp' "$METRICS")
harmful_rate=$(jq '.with_memory.harmful_retrieval_rate' "$METRICS")

echo "=== 核心指标 ==="
echo "  Token/Resolved 下降:          ${token_reduction}%"
echo "  Resolved Rate 变化:           ${resolved_delta} pp"
echo "  Review Trigger Rate 下降:     ${review_reduction} pp"
echo "  Human Escalation Rate 下降:   ${human_reduction} pp"
echo "  Harmful Retrieval Rate:       ${harmful_rate}%"
echo ""

###############################################################################
# 按簇计算变化（文档要求"相似问题簇"的降幅）
###############################################################################

echo "=== 按相似问题簇分析 ==="

best_review_reduction=0
best_human_reduction=0
cluster_review_pass=0
cluster_human_pass=0
cluster_count=0

for cluster in auth-token payment-validation auth-permission schema-migration infra-deploy; do
  c_count=$(jq --arg c "$cluster" '[.[] | select(.cluster_id == $c)] | length' "$RESULTS_MEMORY" 2>/dev/null || echo "0")
  (( c_count < 2 )) && continue
  ((cluster_count++))

  mem_review=$(calc_cluster_review_trigger_rate "$RESULTS_MEMORY" "$cluster")
  nomem_review=$(calc_cluster_review_trigger_rate "$RESULTS_NO_MEMORY" "$cluster")
  mem_human=$(calc_cluster_human_rate "$RESULTS_MEMORY" "$cluster")
  nomem_human=$(calc_cluster_human_rate "$RESULTS_NO_MEMORY" "$cluster")

  c_review_delta=$(echo "$nomem_review - $mem_review" | bc -l 2>/dev/null || echo "0")
  c_human_delta=$(echo "$nomem_human - $mem_human" | bc -l 2>/dev/null || echo "0")

  echo "  ${cluster} (${c_count} tasks):"
  echo "    Review: ${nomem_review}% -> ${mem_review}% (delta: ${c_review_delta}pp)"
  echo "    Human:  ${nomem_human}% -> ${mem_human}% (delta: ${c_human_delta}pp)"

  # 检查是否达到 20% 降幅
  if (( $(echo "$c_review_delta >= 20" | bc -l 2>/dev/null || echo "0") )); then
    ((cluster_review_pass++))
  fi
  if (( $(echo "$c_human_delta >= 20" | bc -l 2>/dev/null || echo "0") )); then
    ((cluster_human_pass++))
  fi

  # 记录最大降幅
  if (( $(echo "$c_review_delta > $best_review_reduction" | bc -l 2>/dev/null || echo "0") )); then
    best_review_reduction="$c_review_delta"
  fi
  if (( $(echo "$c_human_delta > $best_human_reduction" | bc -l 2>/dev/null || echo "0") )); then
    best_human_reduction="$c_human_delta"
  fi
done

echo ""
echo "  Best cluster review reduction: ${best_review_reduction}pp"
echo "  Best cluster human reduction:  ${best_human_reduction}pp"
echo "  Clusters with review >= 20% reduction: ${cluster_review_pass}/${cluster_count}"
echo "  Clusters with human >= 20% reduction:  ${cluster_human_pass}/${cluster_count}"
echo ""

###############################################################################
# 验收判定（文档第30.3节 通过标准）
###############################################################################

echo "============================================================"
echo "  验收判定（文档第30.3节 — 必须全部满足）"
echo "============================================================"
echo ""

pass_count=0
total_checks=5

# 1. Resolved Rate 不下降超过 2pp
echo "检查1: Resolved Rate 不下降超过 2pp"
resolved_drop=$(echo "0 - $resolved_delta" | bc -l 2>/dev/null || echo "0")
if (( $(echo "$resolved_drop <= 2" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] Resolved Rate 变化 ${resolved_delta}pp (允许下降 <= 2pp)"
  ((pass_count++))
else
  echo "  [FAIL] Resolved Rate 下降 ${resolved_drop}pp (超过 2pp 阈值)"
fi

# 2. Token per Resolved Issue 下降至少 30%
echo "检查2: Token/Resolved 下降 >= 30%"
if (( $(echo "$token_reduction >= 30" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] Token/Resolved 下降 ${token_reduction}%"
  ((pass_count++))
else
  echo "  [FAIL] Token/Resolved 下降 ${token_reduction}% (需要 >= 30%)"
fi

# 3. 相似问题簇 Review Trigger Rate 下降至少 20%
echo "检查3: 相似问题簇 Review Trigger Rate 下降 >= 20pp"
if (( cluster_review_pass > 0 )); then
  echo "  [PASS] ${cluster_review_pass}/${cluster_count} 个簇达到 >= 20pp 降幅 (最佳: ${best_review_reduction}pp)"
  ((pass_count++))
else
  echo "  [FAIL] 无簇达到 20pp 降幅阈值 (最佳: ${best_review_reduction}pp)"
fi

# 4. 相似问题簇 Human Escalation Rate 下降至少 20%
echo "检查4: 相似问题簇 Human Escalation Rate 下降 >= 20pp"
if (( cluster_human_pass > 0 )); then
  echo "  [PASS] ${cluster_human_pass}/${cluster_count} 个簇达到 >= 20pp 降幅 (最佳: ${best_human_reduction}pp)"
  ((pass_count++))
else
  echo "  [FAIL] 无簇达到 20pp 降幅阈值 (最佳: ${best_human_reduction}pp)"
fi

# 5. Harmful Retrieval Rate <= 5%
echo "检查5: Harmful Retrieval Rate <= 5%"
if (( $(echo "$harmful_rate <= 5" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] Harmful Retrieval Rate = ${harmful_rate}%"
  ((pass_count++))
else
  echo "  [FAIL] Harmful Retrieval Rate = ${harmful_rate}% (需要 <= 5%)"
fi

echo ""
echo "============================================================"
echo "  验收结果: ${pass_count}/${total_checks} 项通过"
if (( pass_count == total_checks )); then
  echo "  ==> 闭环学习验收: PASS"
  verdict="PASS"
elif (( pass_count >= 3 )); then
  echo "  ==> 闭环学习验收: PARTIAL (需要关注未通过项)"
  verdict="PARTIAL"
else
  echo "  ==> 闭环学习验收: FAIL"
  verdict="FAIL"
fi
echo "============================================================"

###############################################################################
# 强通过标准检查（文档第30.3节）
###############################################################################

echo ""
echo "=== 强通过标准检查（优秀）==="
strong_count=0

echo "  Token/Resolved 下降 >= 40%: $(echo "$token_reduction" | bc -l 2>/dev/null)%"
if (( $(echo "$token_reduction >= 40" | bc -l 2>/dev/null || echo "0") )); then
  echo "    [STRONG PASS]"
  ((strong_count++))
fi

echo "  Best cluster review reduction >= 30pp: ${best_review_reduction}pp"
if (( $(echo "$best_review_reduction >= 30" | bc -l 2>/dev/null || echo "0") )); then
  echo "    [STRONG PASS]"
  ((strong_count++))
fi

echo "  Best cluster human reduction >= 30pp: ${best_human_reduction}pp"
if (( $(echo "$best_human_reduction >= 30" | bc -l 2>/dev/null || echo "0") )); then
  echo "    [STRONG PASS]"
  ((strong_count++))
fi

echo ""
echo "  Strong criteria met: ${strong_count}/3"
echo ""

###############################################################################
# 输出结构化 JSON 报告
###############################################################################

REPORT_JSON=$(jq -n \
  --argjson token_reduction "$token_reduction" \
  --argjson resolved_delta "$resolved_delta" \
  --argjson review_reduction "$review_reduction" \
  --argjson human_reduction "$human_reduction" \
  --argjson harmful_rate "$harmful_rate" \
  --argjson best_review_reduction "$best_review_reduction" \
  --argjson best_human_reduction "$best_human_reduction" \
  --argjson pass_count "$pass_count" \
  --argjson total_checks "$total_checks" \
  --argjson strong_count "$strong_count" \
  --arg verdict "$verdict" \
  '{
    "report_type": "learning_acceptance",
    "acceptance_criteria": {
      "resolved_rate_delta_pp": $resolved_delta,
      "token_reduction_pct": $token_reduction,
      "review_reduction_pp": $review_reduction,
      "human_reduction_pp": $human_reduction,
      "harmful_retrieval_rate": $harmful_rate,
      "best_cluster_review_reduction_pp": $best_review_reduction,
      "best_cluster_human_reduction_pp": $best_human_reduction
    },
    "thresholds": {
      "resolved_rate_max_drop_pp": 2,
      "token_reduction_min_pct": 30,
      "cluster_review_reduction_min_pp": 20,
      "cluster_human_reduction_min_pp": 20,
      "harmful_retrieval_max_pct": 5
    },
    "result": {
      "checks_passed": $pass_count,
      "checks_total": $total_checks,
      "strong_criteria_met": $strong_count,
      "verdict": $verdict
    }
  }')

echo "$REPORT_JSON" | jq '.' > "${RESULTS_DIR}/learning_report.json"
echo "JSON report: ${RESULTS_DIR}/learning_report.json"
