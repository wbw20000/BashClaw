#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# consensus_loop.sh — 双模型共识循环
#
# 当证据裁决产生 UNVERIFIABLE 结果时（无法用测试/规则证明对错），
# 让 Executor (Claude) 和 Reviewer (Codex) 多轮讨论，直到双方达成共识。
#
# 适用场景：架构设计讨论、技术路线选择、无明确对错的权衡决策
# 不适用场景：有明确测试可验证的 bug（应由证据裁决处理）
#
# 流程：
#   1. 提取 UNVERIFIABLE issues
#   2. 将 Reviewer 意见发给 Executor 问是否同意
#   3. 将 Executor 回复发回 Reviewer 问是否同意
#   4. 循环直到双方达成一致，或达到最大轮数
#   5. 输出共识结论或分歧摘要
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source API client
[[ -f "${SCRIPT_DIR}/api_client.sh" ]] && source "${SCRIPT_DIR}/api_client.sh"

# 最大讨论轮数
CONSENSUS_MAX_ROUNDS="${CONSENSUS_MAX_ROUNDS:-3}"

# -----------------------------------------------------------------------------
# consensus_extract_unverifiable — 从裁决结果中提取 UNVERIFIABLE issues
#
# 参数:
#   $1 - resolution_result JSON
# 输出:
#   UNVERIFIABLE issues JSON 数组
# -----------------------------------------------------------------------------
consensus_extract_unverifiable() {
    local resolution_result="$1"
    echo "$resolution_result" | jq '[.verdicts[] | select(.verdict == "UNVERIFIABLE")]' 2>/dev/null || echo "[]"
}

# -----------------------------------------------------------------------------
# consensus_build_prompt — 构建讨论 prompt
#
# 参数:
#   $1 - role ("executor" 或 "reviewer")
#   $2 - issue JSON (当前讨论的问题)
#   $3 - opponent_response (对方上一轮的回复，首轮为空)
#   $4 - round_number
#   $5 - user_request (原始任务描述)
# 输出:
#   prompt 文本
# -----------------------------------------------------------------------------
consensus_build_prompt() {
    local role="$1"
    local issue="$2"
    local opponent_response="${3:-}"
    local round="$4"
    local user_request="${5:-}"

    local issue_summary
    issue_summary=$(echo "$issue" | jq -r '.issue.risk_statement // .issue.location // "unknown issue"' 2>/dev/null)

    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue.issue_type // "design_concern"' 2>/dev/null)

    if [[ -z "$opponent_response" ]]; then
        # 首轮：Executor 回应 Reviewer 的 issue
        cat <<PROMPT
你正在参与一个技术方案讨论。原始任务: ${user_request}

另一位工程师（审查者）提出了以下concern:
---
${issue_summary}
类型: ${issue_type}
详情: $(echo "$issue" | jq -r '.issue.why_it_matters // ""' 2>/dev/null)
建议验证方案: $(echo "$issue" | jq -r '.issue.verification_plan // ""' 2>/dev/null)
---

这个问题无法通过测试或静态规则直接验证，需要工程判断。

请回答:
1. 你是否同意这个concern? (AGREE / PARTIALLY_AGREE / DISAGREE)
2. 你的理由是什么?（具体、简洁）
3. 如果不完全同意，你的替代方案是什么?

格式要求: 用 JSON 回答
{"stance": "AGREE|PARTIALLY_AGREE|DISAGREE", "reasoning": "...", "alternative": "..."}
PROMPT
    else
        # 后续轮：回应对方的观点
        local opponent_label
        if [[ "$role" == "executor" ]]; then
            opponent_label="审查者"
        else
            opponent_label="执行者"
        fi

        cat <<PROMPT
技术方案讨论继续（第 ${round} 轮）。原始任务: ${user_request}

讨论的问题: ${issue_summary}

${opponent_label}的最新回复:
---
${opponent_response}
---

请回答:
1. 你是否同意对方的观点? (AGREE / PARTIALLY_AGREE / DISAGREE)
2. 你的理由是什么?
3. 如果仍有分歧，你愿意接受的妥协方案是什么?

格式要求: 用 JSON 回答
{"stance": "AGREE|PARTIALLY_AGREE|DISAGREE", "reasoning": "...", "compromise": "..."}
PROMPT
    fi
}

# -----------------------------------------------------------------------------
# consensus_check_agreement — 检查双方是否达成共识
#
# 参数:
#   $1 - executor_response JSON
#   $2 - reviewer_response JSON
# 输出:
#   "CONSENSUS" 或 "DIVERGENT"
# -----------------------------------------------------------------------------
consensus_check_agreement() {
    local exec_response="$1"
    local review_response="$2"

    local exec_stance
    exec_stance=$(echo "$exec_response" | jq -r '.stance // "UNKNOWN"' 2>/dev/null)
    local review_stance
    review_stance=$(echo "$review_response" | jq -r '.stance // "UNKNOWN"' 2>/dev/null)

    # 双方都 AGREE 或 PARTIALLY_AGREE → 共识达成
    if [[ "$exec_stance" == "AGREE" && "$review_stance" == "AGREE" ]]; then
        echo "CONSENSUS"
    elif [[ "$exec_stance" != "DISAGREE" && "$review_stance" != "DISAGREE" ]]; then
        # 至少一方 PARTIALLY_AGREE 且没人 DISAGREE → 视为共识
        echo "CONSENSUS"
    else
        echo "DIVERGENT"
    fi
}

# -----------------------------------------------------------------------------
# consensus_run_loop — 对单个 issue 执行共识循环
#
# 参数:
#   $1 - issue JSON
#   $2 - user_request
# 输出:
#   共识结果 JSON
# 返回:
#   0 达成共识, 1 未达成共识
# -----------------------------------------------------------------------------
consensus_run_loop() {
    local issue="$1"
    local user_request="$2"

    local system_prompt="你是一位资深软件工程师，正在参与技术方案讨论。保持客观，基于工程事实论证。"
    local round=1
    local executor_response=""
    local reviewer_response=""
    local last_exec_text=""
    local last_review_text=""
    local consensus="DIVERGENT"

    # 读取 reviewer engine 配置
    local reviewer_engine="codex"
    if [[ -n "${BASHCLAW_CONFIG:-}" && -f "${BASHCLAW_CONFIG}" ]] && command -v jq &>/dev/null; then
        reviewer_engine="$(jq -r '.engines.reviewer // "codex"' "${BASHCLAW_CONFIG}" 2>/dev/null)"
    fi

    while [[ $round -le $CONSENSUS_MAX_ROUNDS ]]; do
        echo "[CONSENSUS] Round ${round}/${CONSENSUS_MAX_ROUNDS}" >&2

        # Executor (Claude) 发言
        local exec_prompt
        exec_prompt=$(consensus_build_prompt "executor" "$issue" "$last_review_text" "$round" "$user_request")

        executor_response=$(api_call_auto "opus4.6" "$system_prompt" "$exec_prompt" 2048 2>/dev/null) || {
            echo "[CONSENSUS] Executor API 调用失败，中止循环" >&2
            break
        }
        last_exec_text="$executor_response"
        echo "[CONSENSUS] Executor responded (round ${round})" >&2

        # Reviewer (Codex) 回应
        local review_prompt
        review_prompt=$(consensus_build_prompt "reviewer" "$issue" "$last_exec_text" "$round" "$user_request")

        reviewer_response=$(api_call_auto "${reviewer_engine}" "$system_prompt" "$review_prompt" 2048 2>/dev/null) || {
            echo "[CONSENSUS] Reviewer API 调用失败，中止循环" >&2
            break
        }
        last_review_text="$reviewer_response"
        echo "[CONSENSUS] Reviewer responded (round ${round})" >&2

        # 检查是否达成共识
        # 尝试解析 JSON stance，回退到文本匹配
        local exec_json review_json
        exec_json=$(echo "$executor_response" | jq '.' 2>/dev/null) || exec_json='{"stance":"UNKNOWN","reasoning":"'"$(echo "$executor_response" | head -c 500)"'"}'
        review_json=$(echo "$reviewer_response" | jq '.' 2>/dev/null) || review_json='{"stance":"UNKNOWN","reasoning":"'"$(echo "$reviewer_response" | head -c 500)"'"}'

        consensus=$(consensus_check_agreement "$exec_json" "$review_json")

        if [[ "$consensus" == "CONSENSUS" ]]; then
            echo "[CONSENSUS] 共识达成 (round ${round})" >&2
            break
        fi

        round=$((round + 1))
    done

    # 构建结果
    local issue_location
    issue_location=$(echo "$issue" | jq -r '.issue.location // "unknown"' 2>/dev/null)

    jq -n \
        --arg status "$consensus" \
        --argjson rounds "$((round > CONSENSUS_MAX_ROUNDS ? CONSENSUS_MAX_ROUNDS : round))" \
        --arg location "$issue_location" \
        --arg executor_final "$last_exec_text" \
        --arg reviewer_final "$last_review_text" \
        '{
            "status": $status,
            "rounds": $rounds,
            "location": $location,
            "executor_final_position": $executor_final,
            "reviewer_final_position": $reviewer_final
        }'

    [[ "$consensus" == "CONSENSUS" ]] && return 0 || return 1
}

# -----------------------------------------------------------------------------
# consensus_run — 对所有 UNVERIFIABLE issues 执行共识循环
#
# 参数:
#   $1 - resolution_result JSON (evidence_resolution 输出)
#   $2 - user_request
# 输出:
#   共识循环完整结果 JSON
# 返回:
#   0 全部达成共识, 1 仍有分歧需要人工
# -----------------------------------------------------------------------------
consensus_run() {
    local resolution_result="$1"
    local user_request="$2"

    local unverifiable_issues
    unverifiable_issues=$(consensus_extract_unverifiable "$resolution_result")

    local issue_count
    issue_count=$(echo "$unverifiable_issues" | jq 'length' 2>/dev/null) || issue_count=0

    if [[ $issue_count -eq 0 ]]; then
        echo '{"status":"NO_UNVERIFIABLE","message":"no issues require consensus loop"}'
        return 0
    fi

    echo "[CONSENSUS] ${issue_count} UNVERIFIABLE issue(s) entering consensus loop" >&2

    local results="[]"
    local consensus_count=0
    local divergent_count=0

    for ((i = 0; i < issue_count; i++)); do
        local issue
        issue=$(echo "$unverifiable_issues" | jq ".[$i]")

        local loop_result
        local loop_code=0
        loop_result=$(consensus_run_loop "$issue" "$user_request") || loop_code=$?

        results=$(echo "$results" | jq --argjson r "$loop_result" '. + [$r]')

        if [[ $loop_code -eq 0 ]]; then
            consensus_count=$((consensus_count + 1))
        else
            divergent_count=$((divergent_count + 1))
        fi
    done

    local overall_status="ALL_CONSENSUS"
    [[ $divergent_count -gt 0 ]] && overall_status="PARTIAL_CONSENSUS"
    [[ $consensus_count -eq 0 ]] && overall_status="NO_CONSENSUS"

    jq -n \
        --arg status "$overall_status" \
        --argjson total "$issue_count" \
        --argjson consensus "$consensus_count" \
        --argjson divergent "$divergent_count" \
        --argjson max_rounds "$CONSENSUS_MAX_ROUNDS" \
        --argjson results "$results" \
        '{
            "status": $status,
            "total_issues": $total,
            "consensus_reached": $consensus,
            "still_divergent": $divergent,
            "max_rounds_per_issue": $max_rounds,
            "results": $results
        }'

    [[ $divergent_count -eq 0 ]] && return 0 || return 1
}
