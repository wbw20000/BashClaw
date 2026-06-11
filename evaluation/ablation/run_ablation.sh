#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run_ablation.sh — 第一层：组件消融实验（文档第22节）
#
# 实现6组最低实验矩阵 + 可选扩展组
# A0: 单模型 + Base Validation（baseline）
# A1: + Knowledge Gate（只检索不回写）
# A2: + Knowledge Gate + Memory Writeback
# B1: + Reviewer（无证据裁决）
# B2: + Reviewer + Evidence-Driven Resolution
# C1: 完整系统
# C2: 完整系统 - Knowledge Gate (可选)
# C3: 完整系统 - Memory Writeback (可选)
# C4: 完整系统 - Human Escalation (可选)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/ablation"
mkdir -p "${RESULTS_DIR}"

TASK_FILE="${EVAL_DATA}/task_sequence.json"
KNOWLEDGE_DB="${RESULTS_DIR}/knowledge_db.json"

echo "============================================================"
echo "  BashClaw V1 — 组件消融实验 (文档第22节)"
echo "  Start: $(eval_timestamp)"
echo "============================================================"

# 检查任务数据
if [[ ! -f "$TASK_FILE" ]]; then
  echo "ERROR: Task data not found: $TASK_FILE" >&2
  exit 1
fi

_require_jq

TASK_COUNT=$(get_task_count "$TASK_FILE")
echo "Task count: ${TASK_COUNT}"
echo ""

###############################################################################
# 定义6组最低实验矩阵 (文档 22.1)
#
# 参数顺序: knowledge_gate, memory_writeback, reviewer, evidence_resolution, human_escalation, name
###############################################################################

# 获取实验组配置（兼容 MSYS2/Git Bash 不支持 declare -A 的问题）
get_config() {
  case "$1" in
    A0) echo "0 0 0 0 0 A0-baseline" ;;
    A1) echo "1 0 0 0 0 A1-knowledge-readonly" ;;
    A2) echo "1 1 0 0 0 A2-knowledge-writeback" ;;
    B1) echo "0 0 1 0 0 B1-reviewer-no-evidence" ;;
    B2) echo "0 0 1 1 0 B2-reviewer-evidence" ;;
    C1) echo "1 1 1 1 1 C1-full-system" ;;
    C2) echo "0 1 1 1 1 C2-no-knowledge-gate" ;;
    C3) echo "1 0 1 1 1 C3-no-memory-writeback" ;;
    C4) echo "1 1 1 1 0 C4-no-human-escalation" ;;
    *)  echo "" ;;
  esac
}

# 选择实验组（默认6组最低，可通过参数扩展）
RUN_EXTENDED="${1:-false}"
if [[ "$RUN_EXTENDED" == "true" || "$RUN_EXTENDED" == "--extended" ]]; then
  ABLATION_GROUPS="A0 A1 A2 B1 B2 C1 C2 C3 C4"
  echo "Running EXTENDED matrix (9 groups)"
else
  ABLATION_GROUPS="A0 A1 A2 B1 B2 C1"
  echo "Running MINIMUM matrix (6 groups)"
fi
echo ""

###############################################################################
# 执行每组实验
###############################################################################

for group in $ABLATION_GROUPS; do
  # shellcheck disable=SC2086
  config_val="$(get_config "${group}")"
  [[ -n "${config_val}" ]] || { echo "WARN: unknown group ${group}, skipping"; continue; }
  read -r kg mw rv er he name <<< "${config_val}"

  echo "--- Running group: ${group} (${name}) ---"
  echo "  Knowledge Gate: ${kg}, Memory Writeback: ${mw}, Reviewer: ${rv}"
  echo "  Evidence Resolution: ${er}, Human Escalation: ${he}"

  config_json=$(make_component_config "$kg" "$mw" "$rv" "$er" "$he" "$name")

  # 初始化知识库（用于带 memory writeback 的组）
  if [[ "$mw" == "1" ]]; then
    echo "[]" > "$KNOWLEDGE_DB"
  fi

  results_file="${RESULTS_DIR}/results_${group}.json"
  echo "[]" > "$results_file"

  for ((i = 0; i < TASK_COUNT; i++)); do
    task_json=$(get_task_at "$TASK_FILE" "$i")

    # 知识库路径（仅在 kg 启用时传递）
    local_kb=""
    if [[ "$kg" == "1" && -f "$KNOWLEDGE_DB" ]]; then
      local_kb="$KNOWLEDGE_DB"
    fi

    # 模拟执行
    result=$(simulate_task_execution "$task_json" "$config_json" "$local_kb")

    # 追加结果
    json_append_to_array "$results_file" "$result"

    # 如果启用了 memory writeback 且任务解决了，将经验写入知识库
    if [[ "$mw" == "1" ]]; then
      resolved=$(echo "$result" | jq -r '.resolved')
      if [[ "$resolved" == "true" ]]; then
        task_id=$(echo "$result" | jq -r '.task_id')
        cluster_id=$(echo "$result" | jq -r '.cluster_id')
        knowledge_entry=$(jq -n \
          --arg tid "$task_id" \
          --arg cid "$cluster_id" \
          --arg ts "$(eval_timestamp)" \
          '{"task_id": $tid, "cluster_id": $cid, "timestamp": $ts}')
        json_append_to_array "$KNOWLEDGE_DB" "$knowledge_entry"
      fi
    fi
  done

  # 计算该组指标
  resolved_rate=$(calc_resolved_rate "$results_file")
  token_per_resolved=$(calc_token_per_resolved "$results_file")
  review_trigger_rate=$(calc_review_trigger_rate "$results_file")
  human_rate=$(calc_human_escalation_rate "$results_file")
  regression_rate=$(calc_regression_rate "$results_file")

  echo "  Results: resolved=${resolved_rate}%, tokens/resolved=${token_per_resolved}"
  echo "           review_rate=${review_trigger_rate}%, human_rate=${human_rate}%"
  echo "           regression_rate=${regression_rate}%"

  # 保存组级汇总
  jq -n \
    --arg group "$group" \
    --arg name "$name" \
    --argjson resolved_rate "$resolved_rate" \
    --argjson token_per_resolved "$token_per_resolved" \
    --argjson review_trigger_rate "$review_trigger_rate" \
    --argjson human_rate "$human_rate" \
    --argjson regression_rate "$regression_rate" \
    '{
      "group": $group,
      "config_name": $name,
      "resolved_rate": $resolved_rate,
      "token_per_resolved": $token_per_resolved,
      "review_trigger_rate": $review_trigger_rate,
      "human_escalation_rate": $human_rate,
      "regression_rate": $regression_rate
    }' > "${RESULTS_DIR}/summary_${group}.json"

  echo ""
done

# 合并所有组汇总
echo "--- Merging all group summaries ---"
{
  echo "["
  first=true
  for group in $ABLATION_GROUPS; do
    summary_file="${RESULTS_DIR}/summary_${group}.json"
    if [[ -f "$summary_file" ]]; then
      [[ "$first" == "true" ]] && first=false || echo ","
      cat "$summary_file"
    fi
  done
  echo "]"
} | jq '.' > "${RESULTS_DIR}/ablation_summary.json"

echo ""
echo "============================================================"
echo "  Ablation experiment complete"
echo "  Results: ${RESULTS_DIR}/ablation_summary.json"
echo "  End: $(eval_timestamp)"
echo "============================================================"
