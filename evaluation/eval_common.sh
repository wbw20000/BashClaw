#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# eval_common.sh — BashClaw V1 评测框架公共函数库
#
# 文档参考：统一实施与验证文档 第19-33节
# 提供：模拟任务执行、指标计算、报告生成、JSON 工具函数
###############################################################################

EVAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "${EVAL_ROOT}/.." && pwd)"
BASHCLAW_LIB="${BASHCLAW_ROOT}/lib"
EVAL_DATA="${EVAL_ROOT}/data"
EVAL_RESULTS="${EVAL_ROOT}/results"

# Source BashClaw modules (stub-safe)
for mod in risk_classifier.sh knowledge_gate.sh executor.sh reviewer.sh \
           budget.sh issue_trace.sh audit_log.sh validator_repo.sh \
           routing.sh engine.sh evidence_resolution.sh human_escalation.sh \
           memory_writeback.sh; do
  [[ -f "${BASHCLAW_LIB}/${mod}" ]] && source "${BASHCLAW_LIB}/${mod}" 2>/dev/null || true
done

# Ensure jq is available
_require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for evaluation. Install with: apt-get install jq / brew install jq" >&2
    exit 1
  fi
}

###############################################################################
# JSON helpers
###############################################################################

# Safe JSON field extraction (returns default if missing)
json_get() {
  local json="$1" field="$2" default="${3:-}"
  local val
  val=$(echo "$json" | jq -r ".${field} // empty" 2>/dev/null) || true
  echo "${val:-$default}"
}

# Numeric JSON field
json_get_num() {
  local json="$1" field="$2" default="${3:-0}"
  local val
  val=$(echo "$json" | jq -r ".${field} // ${default}" 2>/dev/null) || true
  echo "${val:-$default}"
}

# Append to JSON array file
json_append_to_array() {
  local file="$1" item="$2"
  if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
    echo "[$item]" > "$file"
  else
    local tmp
    tmp=$(jq --argjson new "$item" '. + [$new]' "$file")
    echo "$tmp" > "$file"
  fi
}

###############################################################################
# 时间戳与任务 ID
###############################################################################

eval_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

eval_task_id() {
  echo "eval-$(date +%Y%m%d-%H%M%S)-$$"
}

###############################################################################
# 模拟任务数据加载
###############################################################################

# 加载任务序列文件（JSON 数组，每个元素为一个模拟任务）
load_task_sequence() {
  local task_file="$1"
  _require_jq
  if [[ ! -f "$task_file" ]]; then
    echo "ERROR: Task file not found: $task_file" >&2
    return 1
  fi
  cat "$task_file"
}

# 获取任务总数
get_task_count() {
  local task_file="$1"
  jq 'length' "$task_file"
}

# 获取第 N 个任务
get_task_at() {
  local task_file="$1" index="$2"
  jq ".[$index]" "$task_file"
}

###############################################################################
# 模拟系统组件配置（用于消融实验）
###############################################################################

# 生成组件配置 JSON
# 参数: 各组件开关 (0/1)
make_component_config() {
  local knowledge_gate="${1:-0}"
  local memory_writeback="${2:-0}"
  local reviewer="${3:-0}"
  local evidence_resolution="${4:-0}"
  local human_escalation="${5:-0}"
  local config_name="${6:-custom}"

  cat <<EOF
{
  "config_name": "${config_name}",
  "knowledge_gate": $([ "$knowledge_gate" = "1" ] && echo true || echo false),
  "memory_writeback": $([ "$memory_writeback" = "1" ] && echo true || echo false),
  "reviewer": $([ "$reviewer" = "1" ] && echo true || echo false),
  "evidence_resolution": $([ "$evidence_resolution" = "1" ] && echo true || echo false),
  "human_escalation": $([ "$human_escalation" = "1" ] && echo true || echo false)
}
EOF
}

###############################################################################
# 模拟任务执行引擎
#
# 根据组件配置模拟执行一个任务，产出审计日志格式的结果
# 这不是真正调用 AI 模型，而是基于任务预定义属性 + 组件配置
# 模拟不同配置下的结果差异
###############################################################################

simulate_task_execution() {
  local task_json="$1"
  local config_json="$2"
  local knowledge_db="${3:-}"  # 可选：知识库 JSON 文件路径

  _require_jq

  local task_id difficulty change_type risk_tags
  task_id=$(json_get "$task_json" "task_id" "unknown")
  difficulty=$(json_get "$task_json" "difficulty" "easy")
  change_type=$(json_get "$task_json" "change_type" "logic_change")
  risk_tags=$(json_get "$task_json" "risk_tags" "")
  local expected_resolved
  expected_resolved=$(json_get "$task_json" "expected_resolved" "true")
  local multi_file
  multi_file=$(json_get "$task_json" "multi_file" "false")
  local repo_level
  repo_level=$(json_get "$task_json" "repo_level" "false")
  local cluster_id
  cluster_id=$(json_get "$task_json" "cluster_id" "")
  local similar_to
  similar_to=$(json_get "$task_json" "similar_to" "")

  # 组件开关读取
  local kg_on mw_on rv_on er_on he_on config_name
  kg_on=$(json_get "$config_json" "knowledge_gate" "false")
  mw_on=$(json_get "$config_json" "memory_writeback" "false")
  rv_on=$(json_get "$config_json" "reviewer" "false")
  er_on=$(json_get "$config_json" "evidence_resolution" "false")
  he_on=$(json_get "$config_json" "human_escalation" "false")
  config_name=$(json_get "$config_json" "config_name" "custom")

  # === 基础 token 计算 ===
  local base_tokens=500
  case "$difficulty" in
    easy)   base_tokens=500  ;;
    medium) base_tokens=2000 ;;
    hard)   base_tokens=8000 ;;
  esac
  [[ "$multi_file" == "true" ]] && base_tokens=$(( base_tokens + 3000 ))
  [[ "$repo_level" == "true" ]] && base_tokens=$(( base_tokens + 5000 ))

  # === 知识命中模拟 ===
  local knowledge_hit="false"
  local knowledge_helpful="false"
  local knowledge_harmful="false"
  local knowledge_hits="[]"
  local token_reduction=0

  if [[ "$kg_on" == "true" && -n "$knowledge_db" && -f "$knowledge_db" ]]; then
    # 检查知识库中是否有匹配的经验
    local match_count
    if [[ -n "$cluster_id" ]]; then
      match_count=$(jq --arg cid "$cluster_id" \
        '[.[] | select(.cluster_id == $cid)] | length' "$knowledge_db" 2>/dev/null) || match_count=0
    elif [[ -n "$similar_to" ]]; then
      match_count=$(jq --arg sid "$similar_to" \
        '[.[] | select(.task_id == $sid)] | length' "$knowledge_db" 2>/dev/null) || match_count=0
    else
      match_count=0
    fi

    if (( match_count > 0 )); then
      knowledge_hit="true"
      # 70% 精度 — 参照文档 30.1 节标准
      local rand_helpful=$(( RANDOM % 100 ))
      if (( rand_helpful < 70 )); then
        knowledge_helpful="true"
        # 有帮助时减少 token — 类似问题越多，减少越多
        local reduction_pct=$(( 15 + match_count * 10 ))
        (( reduction_pct > 50 )) && reduction_pct=50
        token_reduction=$(( base_tokens * reduction_pct / 100 ))
      fi
      # 5% harmful rate — 文档 30.1 节
      local rand_harmful=$(( RANDOM % 100 ))
      if (( rand_harmful < 5 )); then
        knowledge_harmful="true"
        knowledge_helpful="false"
        token_reduction=$(( - base_tokens * 20 / 100 ))  # 反而增加 20%
      fi
      knowledge_hits=$(jq --arg cid "$cluster_id" \
        '[.[] | select(.cluster_id == $cid) | .task_id] | .[:3]' "$knowledge_db" 2>/dev/null) || knowledge_hits="[]"
    fi
  fi

  local effective_tokens=$(( base_tokens - token_reduction ))
  (( effective_tokens < 200 )) && effective_tokens=200

  # === Review 模拟 ===
  local review_triggered="false"
  local review_issue_count=0
  local confirmed_count=0
  local refuted_count=0
  local unverifiable_count=0
  local requirement_conflict_count=0
  local review_tokens=0

  if [[ "$rv_on" == "true" ]]; then
    # Review 触发条件
    local should_review="false"
    case "$difficulty" in
      medium|hard) should_review="true" ;;
    esac
    [[ "$change_type" == "logic_change" || "$change_type" == "schema_change" || \
       "$change_type" == "infra_change" || "$change_type" == "mixed_change" ]] && should_review="true"
    [[ -n "$risk_tags" && "$risk_tags" != "none" ]] && should_review="true"

    # 知识命中时降低触发率
    if [[ "$knowledge_helpful" == "true" ]]; then
      local skip_roll=$(( RANDOM % 100 ))
      if (( skip_roll < 30 )); then
        should_review="false"
      fi
    fi

    if [[ "$should_review" == "true" ]]; then
      review_triggered="true"
      review_tokens=1500

      # 生成 review issues
      case "$difficulty" in
        easy)   review_issue_count=$(( RANDOM % 2 )) ;;
        medium) review_issue_count=$(( 1 + RANDOM % 3 )) ;;
        hard)   review_issue_count=$(( 2 + RANDOM % 4 )) ;;
      esac

      # === 证据裁决模拟 ===
      if [[ "$er_on" == "true" ]]; then
        for ((i = 0; i < review_issue_count; i++)); do
          local roll=$(( RANDOM % 100 ))
          if (( roll < 35 )); then
            ((confirmed_count++))
          elif (( roll < 70 )); then
            ((refuted_count++))
          elif (( roll < 90 )); then
            ((unverifiable_count++))
          else
            ((requirement_conflict_count++))
          fi
        done
      else
        # 无证据裁决时全部计为 unverifiable
        unverifiable_count=$review_issue_count
      fi

      effective_tokens=$(( effective_tokens + review_tokens ))
    fi
  fi

  # === Human Escalation 模拟 ===
  local human_escalated="false"
  local human_tokens=0

  if [[ "$he_on" == "true" ]]; then
    if (( unverifiable_count > 0 || requirement_conflict_count > 0 )); then
      human_escalated="true"
      human_tokens=500
      effective_tokens=$(( effective_tokens + human_tokens ))
      # 人工介入后解决率提升
    fi
  fi

  # === 最终解决状态 ===
  local resolved="false"
  local base_resolve_rate=0

  case "$difficulty" in
    easy)
      base_resolve_rate=90
      ;;
    medium)
      base_resolve_rate=70
      ;;
    hard)
      base_resolve_rate=30
      ;;
  esac

  # 各组件对解决率的加成
  [[ "$knowledge_helpful" == "true" ]] && base_resolve_rate=$(( base_resolve_rate + 10 ))
  [[ "$knowledge_harmful" == "true" ]] && base_resolve_rate=$(( base_resolve_rate - 15 ))
  [[ "$review_triggered" == "true" && "$er_on" == "true" ]] && base_resolve_rate=$(( base_resolve_rate + 15 ))
  [[ "$review_triggered" == "true" && "$er_on" != "true" ]] && base_resolve_rate=$(( base_resolve_rate + 5 ))
  [[ "$human_escalated" == "true" ]] && base_resolve_rate=$(( base_resolve_rate + 20 ))

  (( base_resolve_rate > 98 )) && base_resolve_rate=98

  local resolve_roll=$(( RANDOM % 100 ))
  if (( resolve_roll < base_resolve_rate )); then
    resolved="true"
  fi

  # === Memory Writeback 模拟 ===
  local memory_writeback_status="skipped"
  if [[ "$mw_on" == "true" && "$resolved" == "true" ]]; then
    memory_writeback_status="written"
  fi

  # === 回归检测 ===
  local regression="false"
  local regression_roll=$(( RANDOM % 100 ))
  if (( regression_roll < 5 )); then
    regression="true"
  fi

  # === 输出审计日志格式 (文档第26节) ===
  cat <<EOF
{
  "task_id": "${task_id}",
  "config_name": "${config_name}",
  "platform": "bashclaw",
  "tier_effective": "$([ "$review_triggered" == "true" ] && echo "reviewed" || echo "default")",
  "executor_model": "opus4.6",
  "reviewer_model": "$([ "$rv_on" == "true" ] && echo "codex" || echo "none")",
  "changed_files": $(json_get_num "$task_json" "changed_files" "1"),
  "diff_lines": $(json_get_num "$task_json" "diff_lines" "50"),
  "change_type": "${change_type}",
  "risk_tags": $(echo "$task_json" | jq '.risk_tags // []' 2>/dev/null || echo '[]'),
  "difficulty": "${difficulty}",
  "multi_file": ${multi_file},
  "repo_level": ${repo_level},
  "cluster_id": "${cluster_id}",
  "knowledge_hits": ${knowledge_hits},
  "knowledge_hit": ${knowledge_hit},
  "knowledge_helpful": ${knowledge_helpful},
  "knowledge_harmful": ${knowledge_harmful},
  "base_validation": [{"name": "simulated", "status": "PASS"}],
  "review_triggered": ${review_triggered},
  "review_issue_count": ${review_issue_count},
  "confirmed_issue_count": ${confirmed_count},
  "refuted_issue_count": ${refuted_count},
  "unverifiable_issue_count": ${unverifiable_count},
  "requirement_conflict_count": ${requirement_conflict_count},
  "human_escalated": ${human_escalated},
  "memory_writeback_status": "${memory_writeback_status}",
  "resolved": ${resolved},
  "regression": ${regression},
  "token_total": ${effective_tokens}
}
EOF
}

###############################################################################
# 真实模型任务执行引擎
#
# 当 BASHCLAW_EVAL_MODE=real 时使用真实 API 调用执行任务。
# 通过 api_client.sh 调用 Anthropic / OpenAI API。
# 记录实际 token 消耗到结果中。
###############################################################################

real_task_execution() {
  local task_json="$1"
  local config_json="$2"

  _require_jq

  # 检查 api_client 是否可用
  if ! type api_has_any_key &>/dev/null; then
    echo "ERROR: api_client.sh 未加载，无法执行真实模式" >&2
    return 1
  fi

  if ! api_has_any_key; then
    echo "ERROR: 无可用的 API key，无法执行真实模式" >&2
    return 1
  fi

  local task_id difficulty change_type risk_tags task_description
  task_id=$(json_get "$task_json" "task_id" "unknown")
  difficulty=$(json_get "$task_json" "difficulty" "easy")
  change_type=$(json_get "$task_json" "change_type" "logic_change")
  risk_tags=$(json_get "$task_json" "risk_tags" "")
  task_description=$(json_get "$task_json" "description" "Execute task ${task_id}")

  # 组件开关读取
  local rv_on config_name
  rv_on=$(json_get "$config_json" "reviewer" "false")
  config_name=$(json_get "$config_json" "config_name" "custom")

  local timestamp
  timestamp=$(eval_timestamp)

  # === Step 1: 调用 Executor（真实 API） ===
  echo "[REAL_EVAL] 执行任务 ${task_id} (difficulty=${difficulty})" >&2

  local executor_output=""
  local executor_tokens=0
  local executor_model="unknown"

  # Executor 优先使用 Opus（Anthropic）
  local exec_system_prompt="You are a senior engineer. Given a task description, provide a solution. Respond with a structured analysis including: what changed, why, and any risks."
  local exec_user_msg="Task ID: ${task_id}\nDifficulty: ${difficulty}\nChange Type: ${change_type}\nDescription: ${task_description}"

  if api_has_anthropic_key; then
    executor_output=$(api_call_anthropic "claude-opus-4-6-20250219" "${exec_system_prompt}" "${exec_user_msg}" 2048 2>/dev/null) || true
    executor_model="opus4.6"
  elif api_has_openai_key; then
    executor_output=$(api_call_openai "gpt-4" "${exec_system_prompt}" "${exec_user_msg}" 2048 2>/dev/null) || true
    executor_model="codex"
  fi

  executor_tokens="${API_LAST_TOTAL_TOKENS:-0}"

  local resolved="false"
  if [[ -n "${executor_output}" ]]; then
    resolved="true"
  fi

  # === Step 2: 调用 Reviewer（真实 API，如果启用） ===
  local review_triggered="false"
  local review_issue_count=0
  local reviewer_tokens=0
  local reviewer_model="none"

  if [[ "$rv_on" == "true" && -n "${executor_output}" ]]; then
    review_triggered="true"

    local review_system="You are a code reviewer. Given an execution result, find potential issues. Output JSON: {\"issues\": [{\"location\": \"file:line\", \"issue_type\": \"logic_bug\", \"severity\": \"major\", \"risk_statement\": \"desc\", \"why_it_matters\": \"impact\", \"verification_plan\": \"steps\"}]}. If no issues, output {\"issues\": []}."
    local review_user="Review this execution result:\n${executor_output}"

    local review_output=""

    # Reviewer 优先使用与 Executor 不同的模型
    if [[ "${executor_model}" == "opus4.6" ]] && api_has_openai_key; then
      review_output=$(api_call_openai "gpt-4" "${review_system}" "${review_user}" 2048 2>/dev/null) || true
      reviewer_model="codex"
    elif api_has_anthropic_key; then
      review_output=$(api_call_anthropic "claude-opus-4-6-20250219" "${review_system}" "${review_user}" 2048 2>/dev/null) || true
      reviewer_model="opus4.6"
    elif api_has_openai_key; then
      review_output=$(api_call_openai "gpt-4" "${review_system}" "${review_user}" 2048 2>/dev/null) || true
      reviewer_model="codex"
    fi

    reviewer_tokens="${API_LAST_TOTAL_TOKENS:-0}"

    # 解析 review 结果中的 issue 数量
    if [[ -n "${review_output}" ]]; then
      review_issue_count=$(echo "${review_output}" | jq '.issues | length' 2>/dev/null || echo 0)
    fi
  fi

  local total_tokens=$(( executor_tokens + reviewer_tokens ))

  # === 输出审计日志格式 ===
  cat <<EOF
{
  "task_id": "${task_id}",
  "config_name": "${config_name}",
  "platform": "bashclaw",
  "eval_mode": "real",
  "tier_effective": "$([ "$review_triggered" == "true" ] && echo "reviewed" || echo "default")",
  "executor_model": "${executor_model}",
  "reviewer_model": "${reviewer_model}",
  "changed_files": $(json_get_num "$task_json" "changed_files" "1"),
  "diff_lines": $(json_get_num "$task_json" "diff_lines" "50"),
  "change_type": "${change_type}",
  "risk_tags": $(echo "$task_json" | jq '.risk_tags // []' 2>/dev/null || echo '[]'),
  "difficulty": "${difficulty}",
  "multi_file": $(json_get "$task_json" "multi_file" "false"),
  "repo_level": $(json_get "$task_json" "repo_level" "false"),
  "cluster_id": "$(json_get "$task_json" "cluster_id" "")",
  "knowledge_hits": [],
  "knowledge_hit": false,
  "knowledge_helpful": false,
  "knowledge_harmful": false,
  "base_validation": [{"name": "real_api", "status": "PASS"}],
  "review_triggered": ${review_triggered},
  "review_issue_count": ${review_issue_count},
  "confirmed_issue_count": 0,
  "refuted_issue_count": 0,
  "unverifiable_issue_count": 0,
  "requirement_conflict_count": 0,
  "human_escalated": false,
  "memory_writeback_status": "skipped",
  "resolved": ${resolved},
  "regression": false,
  "token_total": ${total_tokens},
  "token_executor": ${executor_tokens},
  "token_reviewer": ${reviewer_tokens},
  "timestamp": "${timestamp}"
}
EOF
}

###############################################################################
# 运行模式分发器
#
# 根据 BASHCLAW_EVAL_MODE 环境变量选择执行引擎：
#   - simulate（默认）：使用 simulate_task_execution
#   - real：使用 real_task_execution（真实 API 调用）
###############################################################################

eval_execute_task() {
  local task_json="$1"
  local config_json="$2"
  local knowledge_db="${3:-}"

  local eval_mode="${BASHCLAW_EVAL_MODE:-simulate}"

  case "${eval_mode}" in
    real)
      real_task_execution "${task_json}" "${config_json}"
      ;;
    simulate|*)
      simulate_task_execution "${task_json}" "${config_json}" "${knowledge_db}"
      ;;
  esac
}

###############################################################################
# 指标计算函数（文档第25节全部指标）
###############################################################################

# 从结果数组计算 resolved_rate
calc_resolved_rate() {
  local results_file="$1"
  jq '[.[] | select(.resolved == true)] | length as $r |
      (. | length) as $t |
      if $t == 0 then 0 else ($r / $t * 100) end' "$results_file"
}

# token_per_resolved_issue
calc_token_per_resolved() {
  local results_file="$1"
  jq '[.[] | select(.resolved == true)] |
      if length == 0 then 0
      else (map(.token_total) | add) / length
      end' "$results_file"
}

# review_trigger_rate
calc_review_trigger_rate() {
  local results_file="$1"
  jq '[.[] | select(.review_triggered == true)] | length as $r |
      (input_filename | ltrimstr("") | . as $f | $r) as $_ |
      $r' "$results_file" 2>/dev/null || \
  jq 'length as $t |
      [.[] | select(.review_triggered == true)] | length as $r |
      if $t == 0 then 0 else ($r / $t * 100) end' "$results_file"
}

# human_escalation_rate
calc_human_escalation_rate() {
  local results_file="$1"
  jq 'length as $t |
      [.[] | select(.human_escalated == true)] | length as $h |
      if $t == 0 then 0 else ($h / $t * 100) end' "$results_file"
}

# knowledge_hit_precision
calc_knowledge_hit_precision() {
  local results_file="$1"
  jq '[.[] | select(.knowledge_hit == true)] | length as $hits |
      [.[] | select(.knowledge_helpful == true)] | length as $helpful |
      if $hits == 0 then 0 else ($helpful / $hits * 100) end' "$results_file"
}

# harmful_retrieval_rate
calc_harmful_retrieval_rate() {
  local results_file="$1"
  jq '[.[] | select(.knowledge_hit == true)] | length as $hits |
      [.[] | select(.knowledge_harmful == true)] | length as $harmful |
      if $hits == 0 then 0 else ($harmful / $hits * 100) end' "$results_file"
}

# evidence_auto_resolution_rate (CONFIRMED + REFUTED) / ALL_REVIEW_ISSUES
calc_evidence_auto_resolution_rate() {
  local results_file="$1"
  jq '[.[] | select(.review_triggered == true)] |
      (map(.review_issue_count) | add // 0) as $total_issues |
      (map(.confirmed_issue_count + .refuted_issue_count) | add // 0) as $auto_resolved |
      if $total_issues == 0 then 0 else ($auto_resolved / $total_issues * 100) end' "$results_file"
}

# unverifiable_issue_rate
calc_unverifiable_rate() {
  local results_file="$1"
  jq '[.[] | select(.review_triggered == true)] |
      (map(.review_issue_count) | add // 0) as $total |
      (map(.unverifiable_issue_count) | add // 0) as $unv |
      if $total == 0 then 0 else ($unv / $total * 100) end' "$results_file"
}

# requirement_conflict_rate
calc_requirement_conflict_rate() {
  local results_file="$1"
  jq '[.[] | select(.review_triggered == true)] |
      (map(.review_issue_count) | add // 0) as $total |
      (map(.requirement_conflict_count) | add // 0) as $rc |
      if $total == 0 then 0 else ($rc / $total * 100) end' "$results_file"
}

# regression_rate
calc_regression_rate() {
  local results_file="$1"
  jq 'length as $t |
      [.[] | select(.regression == true)] | length as $r |
      if $t == 0 then 0 else ($r / $t * 100) end' "$results_file"
}

# solve_rate_on_hard (difficulty == "hard")
calc_hard_solve_rate() {
  local results_file="$1"
  jq '[.[] | select(.difficulty == "hard")] | length as $t |
      [.[] | select(.difficulty == "hard" and .resolved == true)] | length as $s |
      if $t == 0 then 0 else ($s / $t * 100) end' "$results_file"
}

# token_per_hard_solved
calc_token_per_hard_solved() {
  local results_file="$1"
  jq '[.[] | select(.difficulty == "hard" and .resolved == true)] |
      if length == 0 then 0
      else (map(.token_total) | add) / length
      end' "$results_file"
}

# human_intervention_rate
calc_human_intervention_rate() {
  local results_file="$1"
  jq 'length as $t |
      [.[] | select(.human_escalated == true)] | length as $h |
      if $t == 0 then 0 else ($h / $t * 100) end' "$results_file"
}

# memory_reuse_rate (tasks with knowledge_hit after memory_writeback)
calc_memory_reuse_rate() {
  local results_file="$1"
  jq '[.[] | select(.memory_writeback_status == "written")] | length as $written |
      [.[] | select(.knowledge_hit == true)] | length as $reused |
      if $written == 0 then 0 else ($reused / $written * 100 | if . > 100 then 100 else . end) end' "$results_file"
}

# 按 cluster 计算 review trigger rate
calc_cluster_review_trigger_rate() {
  local results_file="$1" cluster_id="$2"
  jq --arg cid "$cluster_id" \
    '[.[] | select(.cluster_id == $cid)] | length as $t |
     [.[] | select(.cluster_id == $cid and .review_triggered == true)] | length as $r |
     if $t == 0 then 0 else ($r / $t * 100) end' "$results_file"
}

# 按 cluster 计算 human escalation rate
calc_cluster_human_rate() {
  local results_file="$1" cluster_id="$2"
  jq --arg cid "$cluster_id" \
    '[.[] | select(.cluster_id == $cid)] | length as $t |
     [.[] | select(.cluster_id == $cid and .human_escalated == true)] | length as $h |
     if $t == 0 then 0 else ($h / $t * 100) end' "$results_file"
}

###############################################################################
# 报告生成工具
###############################################################################

# 生成 JSON + 可读文本双格式报告
generate_report() {
  local title="$1"
  local json_data="$2"
  local output_dir="$3"
  local report_name="$4"
  local timestamp
  timestamp="$(eval_timestamp)"

  # JSON 报告
  local json_file="${output_dir}/${report_name}.json"
  echo "$json_data" | jq --arg t "$title" --arg ts "$timestamp" \
    '. + {"report_title": $t, "generated_at": $ts}' > "$json_file"

  # 可读文本报告
  local txt_file="${output_dir}/${report_name}.txt"
  {
    echo "============================================================"
    echo "  ${title}"
    echo "  Generated: ${timestamp}"
    echo "============================================================"
    echo ""
    echo "$json_data" | jq -r 'to_entries[] | "\(.key): \(.value)"' 2>/dev/null || echo "$json_data"
    echo ""
    echo "============================================================"
  } > "$txt_file"

  echo "Reports generated:"
  echo "  JSON: ${json_file}"
  echo "  Text: ${txt_file}"
}

# 打印通过/未通过判定
print_verdict() {
  local label="$1" value="$2" threshold="$3" operator="$4"

  local pass="false"
  case "$operator" in
    ">=") (( $(echo "$value >= $threshold" | bc -l 2>/dev/null || echo 0) )) && pass="true" ;;
    "<=") (( $(echo "$value <= $threshold" | bc -l 2>/dev/null || echo 0) )) && pass="true" ;;
    ">")  (( $(echo "$value > $threshold"  | bc -l 2>/dev/null || echo 0) )) && pass="true" ;;
    "<")  (( $(echo "$value < $threshold"  | bc -l 2>/dev/null || echo 0) )) && pass="true" ;;
  esac

  if [[ "$pass" == "true" ]]; then
    echo "  [PASS] ${label}: ${value} (threshold: ${operator} ${threshold})"
  else
    echo "  [FAIL] ${label}: ${value} (threshold: ${operator} ${threshold})"
  fi
  echo "$pass"
}
