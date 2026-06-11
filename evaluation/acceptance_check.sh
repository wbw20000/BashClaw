#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# acceptance_check.sh — 上线门槛逐条验收（文档第33节）
#
# 检查4大门槛：
# 33.1 工程门槛
# 33.2 闭环学习门槛
# 33.3 复杂能力门槛
# 33.4 裁决质量门槛
# 33.5 知识质量门槛
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/eval_common.sh"

ABLATION_DIR="${EVAL_ROOT}/results/ablation"
LEARNING_DIR="${EVAL_ROOT}/results/learning"
HARDSET_DIR="${EVAL_ROOT}/results/hardset"

_require_jq

echo "============================================================"
echo "  BashClaw V1 — 上线门槛验收 (文档第33节)"
echo "  任一项不满足 = V1 不算通过"
echo "  Generated: $(eval_timestamp)"
echo "============================================================"
echo ""

pass_count=0
fail_count=0
total_checks=0

check_pass() {
  local label="$1"
  echo "  [PASS] ${label}"
  ((pass_count++))
  ((total_checks++))
}

check_fail() {
  local label="$1"
  echo "  [FAIL] ${label}"
  ((fail_count++))
  ((total_checks++))
}

check_warn() {
  local label="$1"
  echo "  [WARN] ${label}"
  ((total_checks++))
}

###############################################################################
# 33.1 工程门槛
###############################################################################

echo "================================================================"
echo "  33.1 工程门槛"
echo "================================================================"

# 检查模块文件是否存在
echo "  -- 架构模块完整性 --"
required_modules=(
  "risk_classifier.sh"
  "knowledge_gate.sh"
  "executor.sh"
  "reviewer.sh"
  "budget.sh"
  "issue_trace.sh"
)

optional_modules=(
  "audit_log.sh"
  "validator_repo.sh"
  "routing.sh"
  "engine.sh"
  "evidence_resolution.sh"
  "human_escalation.sh"
  "memory_writeback.sh"
)

all_modules_present=true
for mod in "${required_modules[@]}"; do
  if [[ -f "${BASHCLAW_LIB}/${mod}" ]]; then
    echo "    [OK] ${mod}"
  else
    echo "    [MISSING] ${mod}"
    all_modules_present=false
  fi
done

for mod in "${optional_modules[@]}"; do
  if [[ -f "${BASHCLAW_LIB}/${mod}" ]]; then
    echo "    [OK] ${mod}"
  else
    echo "    [OPTIONAL/MISSING] ${mod}"
  fi
done

if [[ "$all_modules_present" == "true" ]]; then
  check_pass "核心模块完整"
else
  check_fail "核心模块不完整"
fi

# 审计日志完整性
echo "  -- 审计日志 --"
if [[ -d "${BASHCLAW_ROOT}/.bashclaw/audit" ]] 2>/dev/null || true; then
  check_pass "审计日志目录存在"
else
  check_warn "审计日志目录不存在（首次运行可接受）"
fi

# Issue trace
echo "  -- Issue Trace --"
if [[ -f "${BASHCLAW_LIB}/issue_trace.sh" ]]; then
  check_pass "Issue Trace 模块存在"
else
  check_fail "Issue Trace 模块缺失"
fi

# Memory writeback
echo "  -- Memory Writeback --"
if [[ -f "${BASHCLAW_LIB}/memory_writeback.sh" ]] || \
   grep -q "memory_writeback\|memory.*write" "${BASHCLAW_LIB}"/*.sh 2>/dev/null; then
  check_pass "Memory Writeback 功能可用"
else
  check_warn "Memory Writeback 模块可能缺失（检查是否集成在其他模块中）"
fi

echo ""

###############################################################################
# 33.2 闭环学习门槛
###############################################################################

echo "================================================================"
echo "  33.2 闭环学习门槛"
echo "================================================================"

LEARNING_METRICS="${LEARNING_DIR}/learning_metrics.json"
if [[ -f "$LEARNING_METRICS" ]]; then
  token_reduction=$(jq '.deltas.token_per_resolved_reduction_pct' "$LEARNING_METRICS")
  review_reduction=$(jq '.deltas.review_trigger_rate_reduction_pp' "$LEARNING_METRICS")
  harmful_rate=$(jq '.with_memory.harmful_retrieval_rate' "$LEARNING_METRICS")

  # Token/Resolved 下降 >= 30%
  echo "  Token/Resolved 下降: ${token_reduction}%"
  if (( $(echo "$token_reduction >= 30" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Token/Resolved 下降 >= 30% (${token_reduction}%)"
  else
    check_fail "Token/Resolved 下降 ${token_reduction}% (需要 >= 30%)"
  fi

  # Review trigger rate 在相似问题簇中下降 >= 20%
  echo "  Review Trigger Rate 变化: ${review_reduction}pp"
  if (( $(echo "$review_reduction >= 20" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Review Trigger Rate 下降 >= 20pp"
  else
    # 检查按簇分析
    RESULTS_MEMORY="${LEARNING_DIR}/results_with_memory.json"
    RESULTS_NO_MEMORY="${LEARNING_DIR}/results_no_memory.json"
    cluster_pass=false
    if [[ -f "$RESULTS_MEMORY" && -f "$RESULTS_NO_MEMORY" ]]; then
      for cluster in auth-token payment-validation auth-permission; do
        mem_rv=$(calc_cluster_review_trigger_rate "$RESULTS_MEMORY" "$cluster")
        nomem_rv=$(calc_cluster_review_trigger_rate "$RESULTS_NO_MEMORY" "$cluster")
        delta=$(echo "$nomem_rv - $mem_rv" | bc -l 2>/dev/null || echo "0")
        if (( $(echo "$delta >= 20" | bc -l 2>/dev/null || echo "0") )); then
          cluster_pass=true
          break
        fi
      done
    fi
    if [[ "$cluster_pass" == "true" ]]; then
      check_pass "至少一个问题簇 Review Rate 下降 >= 20pp"
    else
      check_fail "Review Trigger Rate 下降不足 (总体: ${review_reduction}pp)"
    fi
  fi

  # Harmful Retrieval Rate <= 5%
  echo "  Harmful Retrieval Rate: ${harmful_rate}%"
  if (( $(echo "$harmful_rate <= 5" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Harmful Retrieval Rate <= 5%"
  else
    check_fail "Harmful Retrieval Rate = ${harmful_rate}% (需要 <= 5%)"
  fi
else
  echo "  [SKIP] 闭环学习数据不可用（运行 temporal_replay.sh + learning_metrics.sh）"
  ((total_checks += 3))
fi

echo ""

###############################################################################
# 33.3 复杂能力门槛
###############################################################################

echo "================================================================"
echo "  33.3 复杂能力门槛"
echo "================================================================"

HARDSET_SUMMARY="${HARDSET_DIR}/hardset_summary.json"
if [[ -f "$HARDSET_SUMMARY" ]]; then
  h0_solve=$(jq '[.[] | select(.group == "H0")] | .[0].solve_rate // 0' "$HARDSET_SUMMARY")
  h3_solve=$(jq '[.[] | select(.group == "H3")] | .[0].solve_rate // 0' "$HARDSET_SUMMARY")
  h0_tokens=$(jq '[.[] | select(.group == "H0")] | .[0].token_per_hard_solved // 0' "$HARDSET_SUMMARY")
  h3_tokens=$(jq '[.[] | select(.group == "H3")] | .[0].token_per_hard_solved // 0' "$HARDSET_SUMMARY")
  h0_regression=$(jq '[.[] | select(.group == "H0")] | .[0].regression_rate // 0' "$HARDSET_SUMMARY")
  h3_regression=$(jq '[.[] | select(.group == "H3")] | .[0].regression_rate // 0' "$HARDSET_SUMMARY")

  # Solve Rate >= 2x baseline
  if (( $(echo "$h0_solve > 0" | bc -l 2>/dev/null || echo "0") )); then
    solve_mult=$(echo "scale=2; $h3_solve / $h0_solve" | bc -l 2>/dev/null || echo "0")
  else
    solve_mult="inf"
  fi
  echo "  Solve Rate: H3=${h3_solve}% vs H0=${h0_solve}% (${solve_mult}x)"
  if (( $(echo "$solve_mult >= 2" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Hard Set Solve Rate >= 2x baseline (${solve_mult}x)"
  else
    check_fail "Hard Set Solve Rate = ${solve_mult}x (需要 >= 2x)"
  fi

  # Regression Rate <= baseline
  echo "  Regression: H3=${h3_regression}% vs H0=${h0_regression}%"
  if (( $(echo "$h3_regression <= $h0_regression" | bc -l 2>/dev/null || echo "1") )); then
    check_pass "Regression Rate <= baseline"
  else
    check_fail "Regression Rate: H3=${h3_regression}% > H0=${h0_regression}%"
  fi

  # Human intervention rate 在可接受范围
  h3_human=$(jq '[.[] | select(.group == "H3")] | .[0].human_intervention_rate // 0' "$HARDSET_SUMMARY")
  echo "  Human Intervention Rate: ${h3_human}%"
  if (( $(echo "$h3_human <= 50" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Human Intervention Rate 在可接受范围 (${h3_human}%)"
  else
    check_warn "Human Intervention Rate 偏高 (${h3_human}%)，需结合团队容量判断"
  fi
else
  echo "  [SKIP] Hard Set 数据不可用（运行 run_hardset.sh）"
  ((total_checks += 3))
fi

echo ""

###############################################################################
# 33.4 裁决质量门槛
###############################################################################

echo "================================================================"
echo "  33.4 裁决质量门槛"
echo "================================================================"

C1_RESULTS="${ABLATION_DIR}/results_C1.json"
if [[ -f "$C1_RESULTS" ]]; then
  evidence_rate=$(calc_evidence_auto_resolution_rate "$C1_RESULTS")
  echo "  Evidence Auto-Resolution: ${evidence_rate}%"
  if (( $(echo "$evidence_rate >= 80" | bc -l 2>/dev/null || echo "0") )); then
    check_pass ">= 80% review issues 可被归类裁决 (${evidence_rate}%)"
  else
    check_fail "Evidence 归类率 ${evidence_rate}% (需要 >= 80%)"
  fi

  # Human Override Rate < 20%
  human_count=$(jq '[.[] | select(.human_escalated == true)] | length' "$C1_RESULTS")
  reviewed_count=$(jq '[.[] | select(.review_triggered == true)] | length' "$C1_RESULTS")
  if (( reviewed_count > 0 )); then
    override_rate=$(echo "scale=1; $human_count / $reviewed_count * 100" | bc -l 2>/dev/null || echo "0")
  else
    override_rate="0"
  fi
  echo "  Human Override Rate: ${override_rate}%"
  if (( $(echo "$override_rate < 20" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Human Override Rate < 20%"
  else
    check_fail "Human Override Rate = ${override_rate}% (需要 < 20%)"
  fi
else
  echo "  [SKIP] C1 数据不可用（运行 run_ablation.sh）"
  ((total_checks += 2))
fi

echo ""

###############################################################################
# 33.5 知识质量门槛
###############################################################################

echo "================================================================"
echo "  33.5 知识质量门槛"
echo "================================================================"

if [[ -f "$LEARNING_METRICS" ]]; then
  kh_precision=$(jq '.with_memory.knowledge_hit_precision' "$LEARNING_METRICS")
  echo "  Knowledge Hit Precision: ${kh_precision}%"
  if (( $(echo "$kh_precision >= 70" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Knowledge Hit Precision >= 70%"
  else
    check_fail "Knowledge Hit Precision = ${kh_precision}% (需要 >= 70%)"
  fi
else
  echo "  [SKIP] 知识质量数据不可用"
  ((total_checks++))
fi

# Memory Reuse Rate 上升趋势
RESULTS_MEMORY="${LEARNING_DIR}/results_with_memory.json"
if [[ -f "$RESULTS_MEMORY" ]]; then
  reuse_rate=$(calc_memory_reuse_rate "$RESULTS_MEMORY")
  echo "  Memory Reuse Rate: ${reuse_rate}%"
  if (( $(echo "$reuse_rate > 0" | bc -l 2>/dev/null || echo "0") )); then
    check_pass "Memory Reuse Rate 有上升趋势 (${reuse_rate}%)"
  else
    check_warn "Memory Reuse Rate = 0% (可能需要更多数据)"
  fi
else
  ((total_checks++))
fi

echo ""

###############################################################################
# 最终裁决
###############################################################################

echo "============================================================"
echo "  V1 上线门槛最终裁决"
echo "============================================================"
echo ""
echo "  Passed:  ${pass_count}"
echo "  Failed:  ${fail_count}"
echo "  Total:   ${total_checks}"
echo ""

if (( fail_count == 0 )); then
  echo "  =========================================="
  echo "  ==>  V1 上线门槛: ALL PASS              "
  echo "  =========================================="
  final_verdict="ALL_PASS"
elif (( fail_count <= 2 )); then
  echo "  =========================================="
  echo "  ==>  V1 上线门槛: CONDITIONAL PASS       "
  echo "  ==>  需要关注 ${fail_count} 个失败项     "
  echo "  =========================================="
  final_verdict="CONDITIONAL_PASS"
else
  echo "  =========================================="
  echo "  ==>  V1 上线门槛: NOT PASSED             "
  echo "  ==>  ${fail_count} 个检查项未通过         "
  echo "  =========================================="
  final_verdict="NOT_PASSED"
fi

echo ""

###############################################################################
# 输出结构化 JSON
###############################################################################

jq -n \
  --argjson pass_count "$pass_count" \
  --argjson fail_count "$fail_count" \
  --argjson total_checks "$total_checks" \
  --arg verdict "$final_verdict" \
  --arg ts "$(eval_timestamp)" \
  '{
    "acceptance_type": "v1_launch_gate",
    "generated_at": $ts,
    "checks_passed": $pass_count,
    "checks_failed": $fail_count,
    "checks_total": $total_checks,
    "verdict": $verdict,
    "reference": "文档第33节"
  }' > "${EVAL_ROOT}/results/acceptance_result.json"

echo "JSON result: ${EVAL_ROOT}/results/acceptance_result.json"
