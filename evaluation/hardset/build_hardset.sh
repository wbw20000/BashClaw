#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# build_hardset.sh — 第三层：构建 Hard-50 数据集（文档第24节）
#
# Hard Set 要求（文档第31.1节）：
# - 至少50个任务
# - >= 70% 真实仓库问题场景
# - >= 50% 多文件问题
# - >= 30% 需要 repo 级理解
# - >= 20% 涉及高风险域或需求歧义
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/hardset"
mkdir -p "${RESULTS_DIR}"

HARD_SET_FILE="${EVAL_DATA}/hard_set.json"
_require_jq

echo "============================================================"
echo "  BashClaw V1 — Hard-50 数据集构建与验证 (文档第24节)"
echo "  Generated: $(eval_timestamp)"
echo "============================================================"
echo ""

if [[ ! -f "$HARD_SET_FILE" ]]; then
  echo "ERROR: Hard set data not found: $HARD_SET_FILE" >&2
  exit 1
fi

###############################################################################
# 验证 Hard Set 定义（文档第31.1节）
###############################################################################

total=$(jq 'length' "$HARD_SET_FILE")
real_repo=$(jq '[.[] | select(.category == "real_repo")] | length' "$HARD_SET_FILE")
multi_file=$(jq '[.[] | select(.multi_file == true)] | length' "$HARD_SET_FILE")
repo_level=$(jq '[.[] | select(.repo_level == true)] | length' "$HARD_SET_FILE")
high_risk_or_ambiguity=$(jq '[.[] | select(
  (.risk_tags | length > 0) or .requires_ambiguity == true
)] | length' "$HARD_SET_FILE")
ambiguity_only=$(jq '[.[] | select(.requires_ambiguity == true)] | length' "$HARD_SET_FILE")

echo "=== Hard Set 组成 ==="
echo "  Total tasks:          ${total}"
echo "  Real repo problems:   ${real_repo} ($(echo "scale=0; $real_repo * 100 / $total" | bc)%)"
echo "  Multi-file problems:  ${multi_file} ($(echo "scale=0; $multi_file * 100 / $total" | bc)%)"
echo "  Repo-level problems:  ${repo_level} ($(echo "scale=0; $repo_level * 100 / $total" | bc)%)"
echo "  High-risk/Ambiguity:  ${high_risk_or_ambiguity} ($(echo "scale=0; $high_risk_or_ambiguity * 100 / $total" | bc)%)"
echo "  Ambiguity only:       ${ambiguity_only}"
echo ""

echo "=== 问题类别分布 ==="
echo "  Auth/Token:           $(jq '[.[] | select(.cluster_id == "auth-token")] | length' "$HARD_SET_FILE")"
echo "  Payment/Billing:      $(jq '[.[] | select(.cluster_id == "payment-validation")] | length' "$HARD_SET_FILE")"
echo "  Auth/Permission:      $(jq '[.[] | select(.cluster_id == "auth-permission")] | length' "$HARD_SET_FILE")"
echo "  Schema/Migration:     $(jq '[.[] | select(.cluster_id == "schema-migration")] | length' "$HARD_SET_FILE")"
echo "  Infra/Deploy:         $(jq '[.[] | select(.cluster_id == "infra-deploy")] | length' "$HARD_SET_FILE")"
echo "  API Security:         $(jq '[.[] | select(.cluster_id == "api-security")] | length' "$HARD_SET_FILE")"
echo "  Performance:          $(jq '[.[] | select(.cluster_id == "perf-optimization")] | length' "$HARD_SET_FILE")"
echo "  API Features:         $(jq '[.[] | select(.cluster_id == "api-features")] | length' "$HARD_SET_FILE")"
echo ""

###############################################################################
# 定义验收检查
###############################################################################

echo "=== Hard Set 定义验收（文档第31.1节）==="

pass_count=0
total_checks=5

# 至少50个任务
echo "检查1: 至少50个任务"
if (( total >= 50 )); then
  echo "  [PASS] ${total} tasks"
  ((pass_count++))
else
  echo "  [FAIL] ${total} tasks (需要 >= 50)"
fi

# >= 70% 真实仓库问题
real_pct=$(echo "scale=0; $real_repo * 100 / $total" | bc)
echo "检查2: >= 70% 真实仓库问题"
if (( real_pct >= 70 )); then
  echo "  [PASS] ${real_pct}%"
  ((pass_count++))
else
  echo "  [FAIL] ${real_pct}% (需要 >= 70%)"
fi

# >= 50% 多文件问题
multi_pct=$(echo "scale=0; $multi_file * 100 / $total" | bc)
echo "检查3: >= 50% 多文件问题"
if (( multi_pct >= 50 )); then
  echo "  [PASS] ${multi_pct}%"
  ((pass_count++))
else
  echo "  [FAIL] ${multi_pct}% (需要 >= 50%)"
fi

# >= 30% 需要 repo 级理解
repo_pct=$(echo "scale=0; $repo_level * 100 / $total" | bc)
echo "检查4: >= 30% 需要 repo 级理解"
if (( repo_pct >= 30 )); then
  echo "  [PASS] ${repo_pct}%"
  ((pass_count++))
else
  echo "  [FAIL] ${repo_pct}% (需要 >= 30%)"
fi

# >= 20% 涉及高风险域或需求歧义
risk_pct=$(echo "scale=0; $high_risk_or_ambiguity * 100 / $total" | bc)
echo "检查5: >= 20% 涉及高风险域或需求歧义"
if (( risk_pct >= 20 )); then
  echo "  [PASS] ${risk_pct}%"
  ((pass_count++))
else
  echo "  [FAIL] ${risk_pct}% (需要 >= 20%)"
fi

echo ""
echo "Hard Set 定义验收: ${pass_count}/${total_checks}"
if (( pass_count == total_checks )); then
  echo "==> Hard Set 定义验收: PASS"
  hs_verdict="PASS"
else
  echo "==> Hard Set 定义验收: FAIL"
  hs_verdict="FAIL"
fi
echo ""

###############################################################################
# 输出验证报告
###############################################################################

jq -n \
  --argjson total "$total" \
  --argjson real_repo "$real_repo" \
  --argjson multi_file "$multi_file" \
  --argjson repo_level "$repo_level" \
  --argjson high_risk "$high_risk_or_ambiguity" \
  --argjson ambiguity "$ambiguity_only" \
  --argjson pass_count "$pass_count" \
  --argjson total_checks "$total_checks" \
  --arg verdict "$hs_verdict" \
  '{
    "hard_set_validation": {
      "total_tasks": $total,
      "real_repo_pct": ($real_repo / $total * 100),
      "multi_file_pct": ($multi_file / $total * 100),
      "repo_level_pct": ($repo_level / $total * 100),
      "high_risk_ambiguity_pct": ($high_risk / $total * 100),
      "ambiguity_count": $ambiguity,
      "checks_passed": $pass_count,
      "checks_total": $total_checks,
      "verdict": $verdict
    }
  }' > "${RESULTS_DIR}/hardset_validation.json"

echo "Validation JSON: ${RESULTS_DIR}/hardset_validation.json"
