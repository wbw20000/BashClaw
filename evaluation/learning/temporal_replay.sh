#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# temporal_replay.sh — 第二层：闭环学习实验 - 时间顺序回放（文档第23节）
#
# 核心原则（23.1）：必须按时间顺序回放！
# - 第1天只能看到第1天之前的知识
# - 第2天可以使用第1天新增的知识
# - 第N天可以使用前N-1天累计知识
# 不允许偷看未来答案！
#
# 两组对比：
# - WITH_MEMORY:  完整系统（含 Knowledge Gate + Memory Writeback）
# - NO_MEMORY:    同配置但无第二大脑（无 KG, 无 MW）
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${EVAL_ROOT}/eval_common.sh"

RESULTS_DIR="${EVAL_ROOT}/results/learning"
mkdir -p "${RESULTS_DIR}"

# --real 参数：使用真实场景数据集（task_sequence_real.json），默认使用模拟数据（task_sequence.json）
USE_REAL_DATA=false
for arg in "$@"; do
  case "$arg" in
    --real) USE_REAL_DATA=true ;;
  esac
done

if [[ "$USE_REAL_DATA" == "true" ]]; then
  TASK_FILE="${EVAL_DATA}/task_sequence_real.json"
  echo "[MODE] Using REAL task sequence data: ${TASK_FILE}"
else
  TASK_FILE="${EVAL_DATA}/task_sequence.json"
  echo "[MODE] Using simulated task sequence data: ${TASK_FILE}"
fi

echo "============================================================"
echo "  BashClaw V1 — 闭环学习时间顺序回放实验 (文档第23节)"
echo "  Start: $(eval_timestamp)"
echo "============================================================"

if [[ ! -f "$TASK_FILE" ]]; then
  echo "ERROR: Task data not found: $TASK_FILE" >&2
  exit 1
fi

_require_jq

TASK_COUNT=$(get_task_count "$TASK_FILE")
echo "Task count: ${TASK_COUNT}"

# 获取任务的天数范围
MAX_DAY=$(jq '[.[].day] | max' "$TASK_FILE")
MIN_DAY=$(jq '[.[].day] | min' "$TASK_FILE")
echo "Day range: ${MIN_DAY} - ${MAX_DAY}"
echo ""

###############################################################################
# GROUP 1: WITH_MEMORY — 完整系统（闭环学习启用）
###############################################################################

echo "=== Group: WITH_MEMORY (完整系统 + 闭环学习) ==="

KNOWLEDGE_DB_MEMORY="${RESULTS_DIR}/knowledge_db_with_memory.json"
echo "[]" > "$KNOWLEDGE_DB_MEMORY"

RESULTS_MEMORY="${RESULTS_DIR}/results_with_memory.json"
echo "[]" > "$RESULTS_MEMORY"

# 按天分别记录，用于观察趋势
DAILY_MEMORY="${RESULTS_DIR}/daily_with_memory.json"
echo "[]" > "$DAILY_MEMORY"

config_with_memory=$(make_component_config 1 1 1 1 1 "with_memory")

for ((day = MIN_DAY; day <= MAX_DAY; day++)); do
  echo "  Day ${day}:"

  # 获取当天的任务
  day_tasks=$(jq --argjson d "$day" '[.[] | select(.day == $d)]' "$TASK_FILE")
  day_count=$(echo "$day_tasks" | jq 'length')

  if (( day_count == 0 )); then
    echo "    No tasks"
    continue
  fi

  echo "    Tasks: ${day_count}"
  echo "    Knowledge DB size: $(jq 'length' "$KNOWLEDGE_DB_MEMORY") entries"

  day_results="[]"

  for ((i = 0; i < day_count; i++)); do
    task_json=$(echo "$day_tasks" | jq ".[$i]")

    # 只能使用当天之前积累的知识（时间顺序保证）
    result=$(simulate_task_execution "$task_json" "$config_with_memory" "$KNOWLEDGE_DB_MEMORY")

    # 追加到总结果
    json_append_to_array "$RESULTS_MEMORY" "$result"

    # 追加到当天结果
    day_results=$(echo "$day_results" | jq --argjson r "$result" '. + [$r]')

    # 如果解决了，将经验回写知识库（供后续天使用）
    resolved=$(echo "$result" | jq -r '.resolved')
    if [[ "$resolved" == "true" ]]; then
      task_id=$(echo "$result" | jq -r '.task_id')
      cluster_id=$(echo "$result" | jq -r '.cluster_id')
      knowledge_entry=$(jq -n \
        --arg tid "$task_id" \
        --arg cid "$cluster_id" \
        --argjson day "$day" \
        --arg ts "$(eval_timestamp)" \
        '{"task_id": $tid, "cluster_id": $cid, "day": $day, "timestamp": $ts}')
      json_append_to_array "$KNOWLEDGE_DB_MEMORY" "$knowledge_entry"
    fi
  done

  # 保存当天汇总
  day_resolved=$(echo "$day_results" | jq '[.[] | select(.resolved == true)] | length')
  day_total_tokens=$(echo "$day_results" | jq '[.[].token_total] | add // 0')
  day_review_count=$(echo "$day_results" | jq '[.[] | select(.review_triggered == true)] | length')
  day_human_count=$(echo "$day_results" | jq '[.[] | select(.human_escalated == true)] | length')
  day_kb_hits=$(echo "$day_results" | jq '[.[] | select(.knowledge_hit == true)] | length')
  day_kb_helpful=$(echo "$day_results" | jq '[.[] | select(.knowledge_helpful == true)] | length')
  day_kb_harmful=$(echo "$day_results" | jq '[.[] | select(.knowledge_harmful == true)] | length')

  day_summary=$(jq -n \
    --argjson day "$day" \
    --argjson task_count "$day_count" \
    --argjson resolved "$day_resolved" \
    --argjson total_tokens "$day_total_tokens" \
    --argjson review_triggered "$day_review_count" \
    --argjson human_escalated "$day_human_count" \
    --argjson kb_hits "$day_kb_hits" \
    --argjson kb_helpful "$day_kb_helpful" \
    --argjson kb_harmful "$day_kb_harmful" \
    --argjson kb_size "$(jq 'length' "$KNOWLEDGE_DB_MEMORY")" \
    '{
      "day": $day,
      "group": "with_memory",
      "task_count": $task_count,
      "resolved": $resolved,
      "resolved_rate": (if $task_count > 0 then ($resolved / $task_count * 100) else 0 end),
      "total_tokens": $total_tokens,
      "token_per_resolved": (if $resolved > 0 then ($total_tokens / $resolved) else 0 end),
      "review_triggered": $review_triggered,
      "review_trigger_rate": (if $task_count > 0 then ($review_triggered / $task_count * 100) else 0 end),
      "human_escalated": $human_escalated,
      "human_escalation_rate": (if $task_count > 0 then ($human_escalated / $task_count * 100) else 0 end),
      "knowledge_hits": $kb_hits,
      "knowledge_helpful": $kb_helpful,
      "knowledge_harmful": $kb_harmful,
      "knowledge_hit_precision": (if $kb_hits > 0 then ($kb_helpful / $kb_hits * 100) else 0 end),
      "harmful_retrieval_rate": (if $kb_hits > 0 then ($kb_harmful / $kb_hits * 100) else 0 end),
      "knowledge_db_size": $kb_size
    }')

  json_append_to_array "$DAILY_MEMORY" "$day_summary"

  echo "    Resolved: ${day_resolved}/${day_count}"
done
echo ""

###############################################################################
# GROUP 2: NO_MEMORY — 同配置但无第二大脑
###############################################################################

echo "=== Group: NO_MEMORY (同配置但无 Knowledge Gate / Memory Writeback) ==="

RESULTS_NO_MEMORY="${RESULTS_DIR}/results_no_memory.json"
echo "[]" > "$RESULTS_NO_MEMORY"

DAILY_NO_MEMORY="${RESULTS_DIR}/daily_no_memory.json"
echo "[]" > "$DAILY_NO_MEMORY"

config_no_memory=$(make_component_config 0 0 1 1 1 "no_memory")

for ((day = MIN_DAY; day <= MAX_DAY; day++)); do
  echo "  Day ${day}:"

  day_tasks=$(jq --argjson d "$day" '[.[] | select(.day == $d)]' "$TASK_FILE")
  day_count=$(echo "$day_tasks" | jq 'length')

  if (( day_count == 0 )); then
    echo "    No tasks"
    continue
  fi

  echo "    Tasks: ${day_count}"

  day_results="[]"

  for ((i = 0; i < day_count; i++)); do
    task_json=$(echo "$day_tasks" | jq ".[$i]")

    # 无知识库
    result=$(simulate_task_execution "$task_json" "$config_no_memory" "")

    json_append_to_array "$RESULTS_NO_MEMORY" "$result"
    day_results=$(echo "$day_results" | jq --argjson r "$result" '. + [$r]')
  done

  day_resolved=$(echo "$day_results" | jq '[.[] | select(.resolved == true)] | length')
  day_total_tokens=$(echo "$day_results" | jq '[.[].token_total] | add // 0')
  day_review_count=$(echo "$day_results" | jq '[.[] | select(.review_triggered == true)] | length')
  day_human_count=$(echo "$day_results" | jq '[.[] | select(.human_escalated == true)] | length')

  day_summary=$(jq -n \
    --argjson day "$day" \
    --argjson task_count "$day_count" \
    --argjson resolved "$day_resolved" \
    --argjson total_tokens "$day_total_tokens" \
    --argjson review_triggered "$day_review_count" \
    --argjson human_escalated "$day_human_count" \
    '{
      "day": $day,
      "group": "no_memory",
      "task_count": $task_count,
      "resolved": $resolved,
      "resolved_rate": (if $task_count > 0 then ($resolved / $task_count * 100) else 0 end),
      "total_tokens": $total_tokens,
      "token_per_resolved": (if $resolved > 0 then ($total_tokens / $resolved) else 0 end),
      "review_triggered": $review_triggered,
      "review_trigger_rate": (if $task_count > 0 then ($review_triggered / $task_count * 100) else 0 end),
      "human_escalated": $human_escalated,
      "human_escalation_rate": (if $task_count > 0 then ($human_escalated / $task_count * 100) else 0 end),
      "knowledge_hits": 0,
      "knowledge_helpful": 0,
      "knowledge_harmful": 0,
      "knowledge_hit_precision": 0,
      "harmful_retrieval_rate": 0,
      "knowledge_db_size": 0
    }')

  json_append_to_array "$DAILY_NO_MEMORY" "$day_summary"
  echo "    Resolved: ${day_resolved}/${day_count}"
done

echo ""
echo "============================================================"
echo "  Temporal replay complete"
echo "  Results (with memory):    ${RESULTS_MEMORY}"
echo "  Results (no memory):      ${RESULTS_NO_MEMORY}"
echo "  Daily trends (memory):    ${DAILY_MEMORY}"
echo "  Daily trends (no memory): ${DAILY_NO_MEMORY}"
echo "  End: $(eval_timestamp)"
echo "============================================================"
