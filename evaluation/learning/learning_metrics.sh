#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# learning_metrics.sh — 闭环学习指标计算（文档第23.3节）
#
# 观察随 memory 累积的变化趋势：
# - resolved_rate
# - token_per_resolved_issue
# - review_trigger_rate
# - human_escalation_rate
# - knowledge_hit_precision
# - harmful_retrieval_rate
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/learning"
_require_jq

DAILY_MEMORY="${RESULTS_DIR}/daily_with_memory.json"
DAILY_NO_MEMORY="${RESULTS_DIR}/daily_no_memory.json"
RESULTS_MEMORY="${RESULTS_DIR}/results_with_memory.json"
RESULTS_NO_MEMORY="${RESULTS_DIR}/results_no_memory.json"

for f in "$DAILY_MEMORY" "$DAILY_NO_MEMORY" "$RESULTS_MEMORY" "$RESULTS_NO_MEMORY"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Missing file: $f" >&2
    echo "Run temporal_replay.sh first." >&2
    exit 1
  fi
done

echo "============================================================"
echo "  BashClaw V1 — 闭环学习指标分析"
echo "  Generated: $(eval_timestamp)"
echo "============================================================"
echo ""

###############################################################################
# 总体对比指标
###############################################################################

echo "=== 总体对比: WITH_MEMORY vs NO_MEMORY ==="

mem_resolved=$(calc_resolved_rate "$RESULTS_MEMORY")
nomem_resolved=$(calc_resolved_rate "$RESULTS_NO_MEMORY")
echo "  Resolved Rate:          WITH=${mem_resolved}%  NO=${nomem_resolved}%"

mem_tokens=$(calc_token_per_resolved "$RESULTS_MEMORY")
nomem_tokens=$(calc_token_per_resolved "$RESULTS_NO_MEMORY")
echo "  Token/Resolved:         WITH=${mem_tokens}    NO=${nomem_tokens}"

mem_review=$(calc_review_trigger_rate "$RESULTS_MEMORY")
nomem_review=$(calc_review_trigger_rate "$RESULTS_NO_MEMORY")
echo "  Review Trigger Rate:    WITH=${mem_review}%   NO=${nomem_review}%"

mem_human=$(calc_human_escalation_rate "$RESULTS_MEMORY")
nomem_human=$(calc_human_escalation_rate "$RESULTS_NO_MEMORY")
echo "  Human Escalation Rate:  WITH=${mem_human}%   NO=${nomem_human}%"

mem_precision=$(calc_knowledge_hit_precision "$RESULTS_MEMORY")
echo "  Knowledge Hit Precision: ${mem_precision}%"

mem_harmful=$(calc_harmful_retrieval_rate "$RESULTS_MEMORY")
echo "  Harmful Retrieval Rate:  ${mem_harmful}%"

echo ""

###############################################################################
# 计算变化率
###############################################################################

echo "=== 变化率（相对 NO_MEMORY baseline）==="

# token_per_resolved 变化
if (( $(echo "$nomem_tokens > 0" | bc -l 2>/dev/null || echo "0") )); then
  token_change_pct=$(echo "scale=1; ($nomem_tokens - $mem_tokens) / $nomem_tokens * 100" | bc -l 2>/dev/null || echo "0")
  echo "  Token/Resolved 变化: ${token_change_pct}% (正值=下降=好)"
else
  token_change_pct="0"
  echo "  Token/Resolved 变化: N/A"
fi

# resolved_rate 变化
resolved_delta=$(echo "$mem_resolved - $nomem_resolved" | bc -l 2>/dev/null || echo "0")
echo "  Resolved Rate 变化: ${resolved_delta} pp"

# review trigger rate 变化
review_delta=$(echo "$nomem_review - $mem_review" | bc -l 2>/dev/null || echo "0")
echo "  Review Trigger Rate 变化: ${review_delta} pp (正值=下降=好)"

# human escalation rate 变化
human_delta=$(echo "$nomem_human - $mem_human" | bc -l 2>/dev/null || echo "0")
echo "  Human Escalation Rate 变化: ${human_delta} pp (正值=下降=好)"

echo ""

###############################################################################
# 按天趋势分析
###############################################################################

echo "=== 按天趋势 (WITH_MEMORY) ==="
printf "%-6s %-10s %-12s %-10s %-10s %-10s %-8s\n" \
  "Day" "Resolved%" "Tok/Rslv" "Review%" "Human%" "KBPrec%" "KB_Size"
printf "%-6s %-10s %-12s %-10s %-10s %-10s %-8s\n" \
  "---" "--------" "--------" "-------" "------" "-------" "-------"

jq -r '.[] | [.day, .resolved_rate, .token_per_resolved, .review_trigger_rate, .human_escalation_rate, .knowledge_hit_precision, .knowledge_db_size] | @tsv' \
  "$DAILY_MEMORY" | while IFS=$'\t' read -r d rr tr rvr hr kp ks; do
  printf "%-6s %-10s %-12s %-10s %-10s %-10s %-8s\n" "$d" "$rr" "$tr" "$rvr" "$hr" "$kp" "$ks"
done

echo ""
echo "=== 按天趋势 (NO_MEMORY) ==="
printf "%-6s %-10s %-12s %-10s %-10s\n" \
  "Day" "Resolved%" "Tok/Rslv" "Review%" "Human%"
printf "%-6s %-10s %-12s %-10s %-10s\n" \
  "---" "--------" "--------" "-------" "------"

jq -r '.[] | [.day, .resolved_rate, .token_per_resolved, .review_trigger_rate, .human_escalation_rate] | @tsv' \
  "$DAILY_NO_MEMORY" | while IFS=$'\t' read -r d rr tr rvr hr; do
  printf "%-6s %-10s %-12s %-10s %-10s\n" "$d" "$rr" "$tr" "$rvr" "$hr"
done

echo ""

###############################################################################
# 按问题簇分析 review trigger rate 变化
###############################################################################

echo "=== 按问题簇分析 (高频相似问题簇) ==="

for cluster in auth-token payment-validation auth-permission schema-migration infra-deploy; do
  mem_cluster_review=$(calc_cluster_review_trigger_rate "$RESULTS_MEMORY" "$cluster")
  nomem_cluster_review=$(calc_cluster_review_trigger_rate "$RESULTS_NO_MEMORY" "$cluster")
  mem_cluster_human=$(calc_cluster_human_rate "$RESULTS_MEMORY" "$cluster")
  nomem_cluster_human=$(calc_cluster_human_rate "$RESULTS_NO_MEMORY" "$cluster")

  cluster_count=$(jq --arg c "$cluster" '[.[] | select(.cluster_id == $c)] | length' "$RESULTS_MEMORY")

  echo "  Cluster: ${cluster} (${cluster_count} tasks)"
  echo "    Review Rate:    WITH=${mem_cluster_review}%  NO=${nomem_cluster_review}%"
  echo "    Human Rate:     WITH=${mem_cluster_human}%  NO=${nomem_cluster_human}%"

  cluster_review_delta=$(echo "$nomem_cluster_review - $mem_cluster_review" | bc -l 2>/dev/null || echo "0")
  cluster_human_delta=$(echo "$nomem_cluster_human - $mem_cluster_human" | bc -l 2>/dev/null || echo "0")
  echo "    Review Delta:   ${cluster_review_delta} pp"
  echo "    Human Delta:    ${cluster_human_delta} pp"
  echo ""
done

###############################################################################
# 输出结构化 JSON
###############################################################################

METRICS_JSON=$(jq -n \
  --argjson mem_resolved "$mem_resolved" \
  --argjson nomem_resolved "$nomem_resolved" \
  --argjson mem_tokens "$mem_tokens" \
  --argjson nomem_tokens "$nomem_tokens" \
  --argjson mem_review "$mem_review" \
  --argjson nomem_review "$nomem_review" \
  --argjson mem_human "$mem_human" \
  --argjson nomem_human "$nomem_human" \
  --argjson mem_precision "$mem_precision" \
  --argjson mem_harmful "$mem_harmful" \
  --argjson token_change_pct "${token_change_pct}" \
  --argjson resolved_delta "${resolved_delta}" \
  '{
    "metrics_type": "learning_comparison",
    "with_memory": {
      "resolved_rate": $mem_resolved,
      "token_per_resolved": $mem_tokens,
      "review_trigger_rate": $mem_review,
      "human_escalation_rate": $mem_human,
      "knowledge_hit_precision": $mem_precision,
      "harmful_retrieval_rate": $mem_harmful
    },
    "no_memory": {
      "resolved_rate": $nomem_resolved,
      "token_per_resolved": $nomem_tokens,
      "review_trigger_rate": $nomem_review,
      "human_escalation_rate": $nomem_human
    },
    "deltas": {
      "token_per_resolved_reduction_pct": $token_change_pct,
      "resolved_rate_delta_pp": $resolved_delta,
      "review_trigger_rate_reduction_pp": ($nomem_review - $mem_review),
      "human_escalation_rate_reduction_pp": ($nomem_human - $mem_human)
    }
  }')

echo "$METRICS_JSON" | jq '.' > "${RESULTS_DIR}/learning_metrics.json"
echo "Metrics JSON: ${RESULTS_DIR}/learning_metrics.json"
