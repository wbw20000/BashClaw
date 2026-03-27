#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# hardset_report.sh — Hard Set 验收报告（文档第31节）
#
# 验收判定：
# - Solve Rate 提升 >= 2x（相对 H0 baseline）
# - Token per Hard Solved Task <= baseline 5x
# - Regression Rate <= baseline
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/hardset"
_require_jq

SUMMARY="${RESULTS_DIR}/hardset_summary.json"

if [[ ! -f "$SUMMARY" ]]; then
  echo "ERROR: Hard set results not found. Run run_hardset.sh first." >&2
  exit 1
fi

echo "============================================================"
echo "  BashClaw V1 — Hard Set 验收报告"
echo "  文档参考: 第31节"
echo "  Generated: $(eval_timestamp)"
echo "============================================================"
echo ""

###############################################################################
# 读取各组数据
###############################################################################

get_hs_metric() {
  local group="$1" metric="$2"
  jq --arg g "$group" --arg m "$metric" \
    '[.[] | select(.group == $g)] | .[0][$m] // 0' "$SUMMARY"
}

H0_SOLVE=$(get_hs_metric "H0" "solve_rate")
H0_TOKENS=$(get_hs_metric "H0" "token_per_hard_solved")
H0_REGRESSION=$(get_hs_metric "H0" "regression_rate")
H0_HUMAN=$(get_hs_metric "H0" "human_intervention_rate")

H1_SOLVE=$(get_hs_metric "H1" "solve_rate")
H1_TOKENS=$(get_hs_metric "H1" "token_per_hard_solved")
H1_REGRESSION=$(get_hs_metric "H1" "regression_rate")

H2_SOLVE=$(get_hs_metric "H2" "solve_rate")
H2_TOKENS=$(get_hs_metric "H2" "token_per_hard_solved")
H2_REGRESSION=$(get_hs_metric "H2" "regression_rate")

H3_SOLVE=$(get_hs_metric "H3" "solve_rate")
H3_TOKENS=$(get_hs_metric "H3" "token_per_hard_solved")
H3_REGRESSION=$(get_hs_metric "H3" "regression_rate")
H3_HUMAN=$(get_hs_metric "H3" "human_intervention_rate")

echo "=== 各组结果汇总 ==="
printf "%-6s %-12s %-14s %-12s %-10s\n" \
  "Group" "Solve%" "Tok/Solved" "Regress%" "Human%"
printf "%-6s %-12s %-14s %-12s %-10s\n" \
  "-----" "------" "----------" "--------" "------"

jq -r '.[] | [.group, .solve_rate, .token_per_hard_solved, .regression_rate, .human_intervention_rate] | @tsv' \
  "$SUMMARY" | while IFS=$'\t' read -r g sr ts rr hr; do
  printf "%-6s %-12s %-14s %-12s %-10s\n" "$g" "$sr" "$ts" "$rr" "$hr"
done

echo ""

###############################################################################
# 提升分析
###############################################################################

echo "=== 提升分析（相对 H0 baseline）==="

# H3 vs H0 solve rate 倍数
if (( $(echo "$H0_SOLVE > 0" | bc -l 2>/dev/null || echo "0") )); then
  solve_multiplier=$(echo "scale=2; $H3_SOLVE / $H0_SOLVE" | bc -l 2>/dev/null || echo "0")
else
  solve_multiplier="inf"
fi
echo "  H3 Solve Rate / H0 Solve Rate = ${solve_multiplier}x"

# H3 vs H0 token 倍数
if (( $(echo "$H0_TOKENS > 0" | bc -l 2>/dev/null || echo "0") )); then
  token_multiplier=$(echo "scale=2; $H3_TOKENS / $H0_TOKENS" | bc -l 2>/dev/null || echo "0")
else
  token_multiplier="0"
fi
echo "  H3 Token/Solved / H0 Token/Solved = ${token_multiplier}x"

# 各组相对 baseline 的提升
echo ""
echo "  H1 (+ Reviewer):  Solve=${H1_SOLVE}% ($(echo "scale=2; $H1_SOLVE / $H0_SOLVE" | bc -l 2>/dev/null || echo "0")x baseline)"
echo "  H2 (+ Knowledge): Solve=${H2_SOLVE}% ($(echo "scale=2; $H2_SOLVE / $H0_SOLVE" | bc -l 2>/dev/null || echo "0")x baseline)"
echo "  H3 (Full System): Solve=${H3_SOLVE}% (${solve_multiplier}x baseline)"
echo ""

# 分析提升来源
echo "=== 提升来源分析 ==="
h1_lift=$(echo "$H1_SOLVE - $H0_SOLVE" | bc -l 2>/dev/null || echo "0")
h2_lift=$(echo "$H2_SOLVE - $H0_SOLVE" | bc -l 2>/dev/null || echo "0")
h3_lift=$(echo "$H3_SOLVE - $H0_SOLVE" | bc -l 2>/dev/null || echo "0")

echo "  Reviewer 贡献:        ${h1_lift}pp"
echo "  Knowledge 贡献:       ${h2_lift}pp"
echo "  Full System 总提升:   ${h3_lift}pp"
if (( $(echo "$h3_lift > 0" | bc -l 2>/dev/null || echo "0") )); then
  synergy=$(echo "scale=1; $h3_lift - $h1_lift - $h2_lift" | bc -l 2>/dev/null || echo "0")
  echo "  协同/交互效应:        ${synergy}pp"
fi
echo ""

###############################################################################
# 验收判定（文档第31.2节）
###############################################################################

echo "============================================================"
echo "  验收判定（文档第31.2节 — 通过标准）"
echo "============================================================"
echo ""

pass_count=0
total_checks=3

# 1. Solve Rate 提升至少 2x
echo "检查1: Solve Rate 提升 >= 2x"
if (( $(echo "$solve_multiplier >= 2" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] ${solve_multiplier}x (H3=${H3_SOLVE}% vs H0=${H0_SOLVE}%)"
  ((pass_count++))
else
  echo "  [FAIL] ${solve_multiplier}x (需要 >= 2x)"
fi

# 2. Token per Hard Solved Task <= baseline 5x
echo "检查2: Token/Hard Solved <= baseline 5x"
if (( $(echo "$token_multiplier <= 5" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [PASS] ${token_multiplier}x (H3=${H3_TOKENS} vs H0=${H0_TOKENS})"
  ((pass_count++))
else
  echo "  [FAIL] ${token_multiplier}x (需要 <= 5x)"
fi

# 3. Regression Rate <= baseline
echo "检查3: Regression Rate <= baseline"
if (( $(echo "$H3_REGRESSION <= $H0_REGRESSION" | bc -l 2>/dev/null || echo "1") )); then
  echo "  [PASS] H3=${H3_REGRESSION}% vs H0=${H0_REGRESSION}%"
  ((pass_count++))
else
  echo "  [FAIL] H3=${H3_REGRESSION}% > H0=${H0_REGRESSION}%"
fi

echo ""
echo "验收结果: ${pass_count}/${total_checks}"
if (( pass_count == total_checks )); then
  echo "==> Hard Set 验收: PASS"
  verdict="PASS"
else
  echo "==> Hard Set 验收: FAIL"
  verdict="FAIL"
fi
echo ""

###############################################################################
# 强通过标准检查
###############################################################################

echo "=== 强通过标准检查 ==="
strong_count=0

echo "  Solve Rate >= 3x: ${solve_multiplier}x"
if (( $(echo "$solve_multiplier >= 3" | bc -l 2>/dev/null || echo "0") )); then
  echo "    [STRONG PASS]"
  ((strong_count++))
fi

echo "  Token/Solved <= 3x baseline: ${token_multiplier}x"
if (( $(echo "$token_multiplier <= 3" | bc -l 2>/dev/null || echo "0") )); then
  echo "    [STRONG PASS]"
  ((strong_count++))
fi

echo "  Regression Rate <= baseline: H3=${H3_REGRESSION}% vs H0=${H0_REGRESSION}%"
if (( $(echo "$H3_REGRESSION <= $H0_REGRESSION" | bc -l 2>/dev/null || echo "0") )); then
  echo "    [STRONG PASS]"
  ((strong_count++))
fi

echo ""
echo "  Strong criteria met: ${strong_count}/3"

###############################################################################
# 窄口径宣传标准检查（文档第31.2节）
###############################################################################

echo ""
echo "=== 10x 窄口径宣传标准检查 ==="
narrow_pass="false"
if (( $(echo "$H0_SOLVE <= 5" | bc -l 2>/dev/null || echo "0") )) && \
   (( $(echo "$solve_multiplier >= 10" | bc -l 2>/dev/null || echo "0") )); then
  echo "  [OK] Baseline solve rate <= 5% AND improvement >= 10x"
  echo "  WARNING: 此为窄口径 claim，仅限 Hard Subset"
  narrow_pass="true"
else
  echo "  [N/A] 不满足 10x 窄口径宣传条件"
fi
echo ""

###############################################################################
# 输出结构化 JSON 报告
###############################################################################

REPORT_JSON=$(jq -n \
  --slurpfile summary "$SUMMARY" \
  --argjson solve_multiplier "$solve_multiplier" \
  --argjson token_multiplier "$token_multiplier" \
  --argjson h1_lift "$h1_lift" \
  --argjson h2_lift "$h2_lift" \
  --argjson h3_lift "$h3_lift" \
  --argjson pass_count "$pass_count" \
  --argjson total_checks "$total_checks" \
  --argjson strong_count "$strong_count" \
  --arg verdict "$verdict" \
  --arg narrow_claim "$narrow_pass" \
  '{
    "report_type": "hardset_acceptance",
    "group_summaries": $summary[0],
    "analysis": {
      "solve_rate_multiplier": $solve_multiplier,
      "token_cost_multiplier": $token_multiplier,
      "reviewer_lift_pp": $h1_lift,
      "knowledge_lift_pp": $h2_lift,
      "full_system_lift_pp": $h3_lift,
      "synergy_pp": ($h3_lift - $h1_lift - $h2_lift)
    },
    "acceptance": {
      "checks_passed": $pass_count,
      "checks_total": $total_checks,
      "strong_criteria_met": $strong_count,
      "verdict": $verdict,
      "narrow_10x_claim_eligible": ($narrow_claim == "true")
    }
  }')

echo "$REPORT_JSON" | jq '.' > "${RESULTS_DIR}/hardset_report.json"
echo "JSON report: ${RESULTS_DIR}/hardset_report.json"
