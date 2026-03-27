#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run_hardset.sh — 第三层：Hard Set 能力实验（文档第24.3节）
#
# 4组对比：
# H0: 最强单模型 baseline (Opus + Base Validation)
# H1: 单模型 + Reviewer
# H2: Knowledge + 单模型 + Base Validation
# H3: 完整系统
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/hardset"
mkdir -p "${RESULTS_DIR}"

# --real 参数：使用真实场景数据集（hard_set_real.json），默认使用模拟数据（hard_set.json）
USE_REAL_DATA=false
for arg in "$@"; do
  case "$arg" in
    --real) USE_REAL_DATA=true ;;
  esac
done

if [[ "$USE_REAL_DATA" == "true" ]]; then
  HARD_SET_FILE="${EVAL_DATA}/hard_set_real.json"
  echo "[MODE] Using REAL hard set data: ${HARD_SET_FILE}"
else
  HARD_SET_FILE="${EVAL_DATA}/hard_set.json"
  echo "[MODE] Using simulated hard set data: ${HARD_SET_FILE}"
fi
KNOWLEDGE_DB="${RESULTS_DIR}/hardset_knowledge_db.json"

echo "============================================================"
echo "  BashClaw V1 — Hard Set 能力实验 (文档第24.3节)"
echo "  Start: $(eval_timestamp)"
echo "============================================================"

if [[ ! -f "$HARD_SET_FILE" ]]; then
  echo "ERROR: Hard set data not found: $HARD_SET_FILE" >&2
  exit 1
fi

_require_jq

TASK_COUNT=$(jq 'length' "$HARD_SET_FILE")
echo "Hard Set tasks: ${TASK_COUNT}"
echo ""

###############################################################################
# 定义4组对比配置 (文档 24.3)
#
# 参数: knowledge_gate, memory_writeback, reviewer, evidence_resolution, human_escalation
###############################################################################

get_hardset_config() {
  case "$1" in
    H0) echo "0 0 0 0 0 H0-baseline" ;;
    H1) echo "0 0 1 1 0 H1-reviewer" ;;
    H2) echo "1 1 0 0 0 H2-knowledge" ;;
    H3) echo "1 1 1 1 1 H3-full-system" ;;
    *)  echo "" ;;
  esac
}

HS_GROUPS="H0 H1 H2 H3"

for group in ${HS_GROUPS}; do
  # shellcheck disable=SC2086
  config_val="$(get_hardset_config "${group}")"
  [[ -n "${config_val}" ]] || continue
  read -r kg mw rv er he name <<< "${config_val}"

  echo "--- Running group: ${group} (${name}) ---"
  echo "  Knowledge Gate: ${kg}, Memory Writeback: ${mw}, Reviewer: ${rv}"
  echo "  Evidence Resolution: ${er}, Human Escalation: ${he}"

  config_json=$(make_component_config "$kg" "$mw" "$rv" "$er" "$he" "$name")

  # 初始化知识库（H2/H3需要）
  # 为了公平起见，预装一些基础知识条目模拟实际使用场景
  if [[ "$kg" == "1" ]]; then
    cat > "$KNOWLEDGE_DB" <<'PRELOAD'
[
  {"task_id": "KB-001", "cluster_id": "auth-token", "timestamp": "2026-03-01T00:00:00Z"},
  {"task_id": "KB-002", "cluster_id": "payment-validation", "timestamp": "2026-03-01T00:00:00Z"},
  {"task_id": "KB-003", "cluster_id": "auth-permission", "timestamp": "2026-03-01T00:00:00Z"},
  {"task_id": "KB-004", "cluster_id": "schema-migration", "timestamp": "2026-03-01T00:00:00Z"},
  {"task_id": "KB-005", "cluster_id": "infra-deploy", "timestamp": "2026-03-01T00:00:00Z"}
]
PRELOAD
  fi

  results_file="${RESULTS_DIR}/results_${group}.json"
  echo "[]" > "$results_file"

  for ((i = 0; i < TASK_COUNT; i++)); do
    task_json=$(jq ".[$i]" "$HARD_SET_FILE")

    local_kb=""
    if [[ "$kg" == "1" && -f "$KNOWLEDGE_DB" ]]; then
      local_kb="$KNOWLEDGE_DB"
    fi

    result=$(simulate_task_execution "$task_json" "$config_json" "$local_kb")
    json_append_to_array "$results_file" "$result"

    # Memory writeback
    if [[ "$mw" == "1" ]]; then
      resolved=$(echo "$result" | jq -r '.resolved')
      if [[ "$resolved" == "true" ]]; then
        task_id=$(echo "$result" | jq -r '.task_id')
        cluster_id=$(echo "$result" | jq -r '.cluster_id')
        entry=$(jq -n --arg t "$task_id" --arg c "$cluster_id" --arg ts "$(eval_timestamp)" \
          '{"task_id": $t, "cluster_id": $c, "timestamp": $ts}')
        json_append_to_array "$KNOWLEDGE_DB" "$entry"
      fi
    fi
  done

  # 计算指标
  solve_rate=$(calc_hard_solve_rate "$results_file")
  token_per_solved=$(calc_token_per_hard_solved "$results_file")
  regression_rate=$(calc_regression_rate "$results_file")
  human_rate=$(calc_human_intervention_rate "$results_file")
  resolved_count=$(jq '[.[] | select(.resolved == true)] | length' "$results_file")

  echo "  Results:"
  echo "    Solve Rate:       ${solve_rate}% (${resolved_count}/${TASK_COUNT})"
  echo "    Token/Solved:     ${token_per_solved}"
  echo "    Regression Rate:  ${regression_rate}%"
  echo "    Human Rate:       ${human_rate}%"

  # 保存组级汇总
  jq -n \
    --arg group "$group" \
    --arg name "$name" \
    --argjson solve_rate "$solve_rate" \
    --argjson token_per_solved "$token_per_solved" \
    --argjson regression_rate "$regression_rate" \
    --argjson human_rate "$human_rate" \
    --argjson resolved_count "$resolved_count" \
    --argjson total "$TASK_COUNT" \
    '{
      "group": $group,
      "config_name": $name,
      "solve_rate": $solve_rate,
      "token_per_hard_solved": $token_per_solved,
      "regression_rate": $regression_rate,
      "human_intervention_rate": $human_rate,
      "resolved_count": $resolved_count,
      "total_tasks": $total
    }' > "${RESULTS_DIR}/summary_${group}.json"

  echo ""
done

# 合并所有组汇总
{
  echo "["
  first=true
  for group in ${HS_GROUPS}; do
    [[ "$first" == "true" ]] && first=false || echo ","
    cat "${RESULTS_DIR}/summary_${group}.json"
  done
  echo "]"
} | jq '.' > "${RESULTS_DIR}/hardset_summary.json"

echo "============================================================"
echo "  Hard Set experiment complete"
echo "  Results: ${RESULTS_DIR}/hardset_summary.json"
echo "  End: $(eval_timestamp)"
echo "============================================================"
