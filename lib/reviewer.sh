#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# reviewer.sh — Structured Reviewer: 第二模型复查器
#
# 将潜在问题转成可被裁决的结构化主张。
# 匿名化要求：绝不暴露模型名称，使用中性标签。
# 文档参考：统一实施文档 第10节
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies (stub-safe: functions check availability)
# shellcheck source=lib/api_client.sh
[[ -f "${SCRIPT_DIR}/api_client.sh" ]] && source "${SCRIPT_DIR}/api_client.sh"
# shellcheck source=lib/knowledge_gate.sh
[[ -f "${SCRIPT_DIR}/knowledge_gate.sh" ]] && source "${SCRIPT_DIR}/knowledge_gate.sh"
# shellcheck source=lib/risk_classifier.sh
[[ -f "${SCRIPT_DIR}/risk_classifier.sh" ]] && source "${SCRIPT_DIR}/risk_classifier.sh"
# shellcheck source=lib/validator_repo.sh
[[ -f "${SCRIPT_DIR}/validator_repo.sh" ]] && source "${SCRIPT_DIR}/validator_repo.sh"
# shellcheck source=lib/audit_log.sh
[[ -f "${SCRIPT_DIR}/audit_log.sh" ]] && source "${SCRIPT_DIR}/audit_log.sh"

# issue_type 枚举值（guarded against re-source）
[[ -z "${ISSUE_TYPES:-}" ]] && readonly ISSUE_TYPES="runtime_bug logic_bug missing_test security_risk regression_risk requirement_conflict design_concern"

# severity 枚举值
[[ -z "${SEVERITY_LEVELS:-}" ]] && readonly SEVERITY_LEVELS="minor major critical"

# 匿名化替换映射 — 禁止出现任何模型名称（guarded against re-source）
if [[ -z "${ANONYMIZE_PATTERNS+set}" ]]; then
readonly ANONYMIZE_PATTERNS=(
    "Opus"
    "opus"
    "Codex"
    "codex"
    "Claude"
    "claude"
    "GPT"
    "gpt"
    "Gemini"
    "gemini"
    "OpenAI"
    "openai"
    "Anthropic"
    "anthropic"
)
fi

# -----------------------------------------------------------------------------
# anonymize_content — 将内容中的模型名称替换为中性标签
#
# 参数:
#   $1 - 待匿名化的文本内容
# 输出:
#   匿名化后的文本（stdout）
# -----------------------------------------------------------------------------
anonymize_content() {
    local content="$1"

    for pattern in "${ANONYMIZE_PATTERNS[@]}"; do
        content="${content//${pattern}/[Model]}"
    done

    # 替换常见的模型引用模式
    content="${content//Model A output/Patch A}"
    content="${content//model output/Patch A}"
    content="${content//executor output/Patch A}"
    content="${content//validation result/Validation Output}"
    content="${content//knowledge result/Knowledge Notes}"

    echo "$content"
}

# -----------------------------------------------------------------------------
# validate_issue_type — 验证 issue_type 是否为合法枚举值
#
# 参数:
#   $1 - issue_type 值
# 返回:
#   0 合法, 1 非法
# -----------------------------------------------------------------------------
validate_issue_type() {
    local issue_type="$1"
    local valid_type

    for valid_type in $ISSUE_TYPES; do
        if [[ "$issue_type" == "$valid_type" ]]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# validate_severity — 验证 severity 是否为合法枚举值
#
# 参数:
#   $1 - severity 值
# 返回:
#   0 合法, 1 非法
# -----------------------------------------------------------------------------
validate_severity() {
    local severity="$1"
    local valid_level

    for valid_level in $SEVERITY_LEVELS; do
        if [[ "$severity" == "$valid_level" ]]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# validate_issue — 验证单个 issue 是否包含所有必须字段且字段值合法
#
# 必须字段：location, issue_type, risk_statement, why_it_matters,
#            verification_plan, severity
#
# 参数:
#   $1 - issue JSON 字符串
# 返回:
#   0 合法, 1 缺少字段或字段值非法
# 输出:
#   错误信息（stderr）
# -----------------------------------------------------------------------------
validate_issue() {
    local issue_json="$1"
    local errors=()

    # 检查必须字段存在性
    local required_fields=("location" "issue_type" "risk_statement" "why_it_matters" "verification_plan" "severity")
    for field in "${required_fields[@]}"; do
        local value
        value=$(echo "$issue_json" | jq -r ".${field} // empty" 2>/dev/null)
        if [[ -z "$value" ]]; then
            errors+=("missing required field: ${field}")
        fi
    done

    # 验证 issue_type 枚举
    local issue_type
    issue_type=$(echo "$issue_json" | jq -r '.issue_type // empty' 2>/dev/null)
    if [[ -n "$issue_type" ]] && ! validate_issue_type "$issue_type"; then
        errors+=("invalid issue_type: ${issue_type}")
    fi

    # 验证 severity 枚举
    local severity
    severity=$(echo "$issue_json" | jq -r '.severity // empty' 2>/dev/null)
    if [[ -n "$severity" ]] && ! validate_severity "$severity"; then
        errors+=("invalid severity: ${severity}")
    fi

    # 检查 location 格式（应包含 file:line）
    local location
    location=$(echo "$issue_json" | jq -r '.location // empty' 2>/dev/null)
    if [[ -n "$location" ]] && ! echo "$location" | grep -qE '.+:[0-9]+'; then
        errors+=("location should be in format 'file:line', got: ${location}")
    fi

    # 拒绝空洞意见 — risk_statement 不能是模糊表述
    local risk_statement
    risk_statement=$(echo "$issue_json" | jq -r '.risk_statement // empty' 2>/dev/null)
    if [[ -n "$risk_statement" ]]; then
        local vague_patterns=("感觉有问题" "建议优化一下" "可能不太好" "看起来不对" "seems off" "might be wrong" "could be better" "looks weird")
        for vague in "${vague_patterns[@]}"; do
            if [[ "$risk_statement" == *"$vague"* ]]; then
                errors+=("risk_statement is too vague (contains '${vague}'): must be specific and actionable")
            fi
        done
    fi

    # 拒绝空洞 verification_plan
    local verification_plan
    verification_plan=$(echo "$issue_json" | jq -r '.verification_plan // empty' 2>/dev/null)
    if [[ -n "$verification_plan" ]] && [[ ${#verification_plan} -lt 10 ]]; then
        errors+=("verification_plan is too short: must contain executable verification steps")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            echo "ISSUE_VALIDATION_ERROR: $err" >&2
        done
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# build_review_context — 构建匿名化的 review 上下文
#
# 将所有输入组装为匿名化的 review 上下文 JSON。
#
# 参数:
#   $1 - user_request       用户原始需求
#   $2 - patch_diff         匿名 patch/diff
#   $3 - base_validation    Base Validation 输出 JSON
#   $4 - knowledge_summary  Knowledge Gate 摘要
#   $5 - risk_tags          风险标签（逗号分隔）
#   $6 - change_type        changeType 枚举值
# 输出:
#   匿名化的 review 上下文 JSON（stdout）
# -----------------------------------------------------------------------------
build_review_context() {
    local user_request="$1"
    local patch_diff="$2"
    local base_validation="$3"
    local knowledge_summary="$4"
    local risk_tags="$5"
    local change_type="$6"

    # 匿名化所有输入
    local anon_request
    anon_request=$(anonymize_content "$user_request")
    local anon_diff
    anon_diff=$(anonymize_content "$patch_diff")
    local anon_validation
    anon_validation=$(anonymize_content "$base_validation")
    local anon_knowledge
    anon_knowledge=$(anonymize_content "$knowledge_summary")

    # 构建 review 上下文 JSON，使用中性标签
    jq -n \
        --arg request "$anon_request" \
        --arg patch "$anon_diff" \
        --arg validation "$anon_validation" \
        --arg knowledge "$anon_knowledge" \
        --arg risk_tags "$risk_tags" \
        --arg change_type "$change_type" \
        '{
            "review_context": {
                "user_request": $request,
                "patch_a": $patch,
                "validation_output": $validation,
                "knowledge_notes": $knowledge,
                "risk_tags": ($risk_tags | split(",")),
                "change_type": $change_type
            }
        }'
}

# -----------------------------------------------------------------------------
# format_review_prompt — 生成发送给 Reviewer 模型的结构化 prompt
#
# 参数:
#   $1 - review_context JSON（build_review_context 的输出）
# 输出:
#   格式化的 prompt 文本（stdout）
# -----------------------------------------------------------------------------
format_review_prompt() {
    local review_context="$1"

    cat <<'PROMPT_HEADER'
You are a code reviewer. You have been given:
- A user request (Review Context)
- A code patch (Patch A)
- Validation results (Validation Output)
- Historical knowledge notes (Knowledge Notes)
- Risk tags and change type

Your job is to identify potential issues. For EACH issue, you MUST output ALL of the following fields in JSON format:

{
  "location": "file_path:line_number",
  "issue_type": "one of: runtime_bug, logic_bug, missing_test, security_risk, regression_risk, requirement_conflict, design_concern",
  "severity": "one of: minor, major, critical",
  "risk_statement": "specific, concrete description of what could go wrong",
  "why_it_matters": "concrete impact if this issue is real",
  "verification_plan": "step-by-step plan to verify or refute this issue"
}

Rules:
- Do NOT output vague opinions like "feels wrong" or "could be better"
- Every issue MUST have a concrete verification_plan with executable steps
- Location MUST reference specific file:line
- Do NOT reference any model names — use only: Patch A, Validation Output, Knowledge Notes, Review Context
- If you find no issues, output: {"issues": []}
- Wrap all issues in: {"issues": [...]}

PROMPT_HEADER

    echo ""
    echo "=== REVIEW INPUT ==="
    echo "$review_context" | jq '.'
}

# -----------------------------------------------------------------------------
# parse_review_output — 解析 Reviewer 模型的输出为结构化 issues
#
# 参数:
#   $1 - Reviewer 模型的原始输出
# 输出:
#   验证通过的结构化 issues JSON（stdout）
# 返回:
#   0 成功, 1 解析失败或所有 issues 均不合法
# -----------------------------------------------------------------------------
parse_review_output() {
    local raw_output="$1"

    # 尝试从输出中提取 JSON
    local json_output
    # Try to use raw output as JSON directly first
    if echo "$raw_output" | jq -e '.' >/dev/null 2>&1; then
        json_output="$raw_output"
    else
        # Try to extract JSON object from surrounding text
        json_output=$(echo "$raw_output" | python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    try:
        json.loads(m.group())
        print(m.group())
    except: pass
" 2>/dev/null) || true
    fi

    if [[ -z "$json_output" ]]; then
        echo "REVIEW_PARSE_ERROR: could not extract JSON from reviewer output" >&2
        echo '{"issues": [], "parse_error": true}'
        return 1
    fi

    # 验证 JSON 结构
    if ! echo "$json_output" | jq -e '.issues' > /dev/null 2>&1; then
        echo "REVIEW_PARSE_ERROR: JSON does not contain 'issues' array" >&2
        echo '{"issues": [], "parse_error": true}'
        return 1
    fi

    # 匿名化输出
    json_output=$(anonymize_content "$json_output")

    # 逐个验证 issue
    local issue_count
    issue_count=$(echo "$json_output" | jq '.issues | length')
    local valid_issues="[]"
    local rejected_count=0

    for ((i = 0; i < issue_count; i++)); do
        local issue
        issue=$(echo "$json_output" | jq ".issues[$i]")

        if validate_issue "$issue" 2>/dev/null; then
            valid_issues=$(echo "$valid_issues" | jq --argjson new_issue "$issue" '. + [$new_issue]')
        else
            ((rejected_count++)) || true
            echo "REVIEW_WARNING: issue #$((i + 1)) rejected due to validation errors" >&2
        fi
    done

    local result
    result=$(jq -n \
        --argjson issues "$valid_issues" \
        --argjson total "$issue_count" \
        --argjson rejected "$rejected_count" \
        '{
            "issues": $issues,
            "total_from_reviewer": $total,
            "rejected_count": $rejected,
            "valid_count": ($total - $rejected)
        }')

    echo "$result"

    if [[ $(echo "$result" | jq '.valid_count') -eq 0 ]] && [[ "$issue_count" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# run_review — 执行完整的 review 流程
#
# 编排完整的 Reviewer 流程：构建上下文 → 生成 prompt → 调用模型 → 解析输出
#
# 参数:
#   $1 - user_request       用户原始需求
#   $2 - patch_diff         patch/diff 内容
#   $3 - base_validation    Base Validation 输出 JSON
#   $4 - knowledge_summary  Knowledge Gate 摘要
#   $5 - risk_tags          风险标签（逗号分隔）
#   $6 - change_type        changeType 枚举值
#   $7 - reviewer_model     (可选) reviewer 使用的模型命令，默认使用环境变量
# 输出:
#   结构化 review 结果 JSON（stdout）
# 返回:
#   0 成功, 1 失败
# -----------------------------------------------------------------------------
run_review() {
    local user_request="${1:?user_request is required}"
    local patch_diff="${2:?patch_diff is required}"
    local base_validation="${3:?base_validation is required}"
    local knowledge_summary="${4:-}"
    local risk_tags="${5:-}"
    local change_type="${6:-logic_change}"
    local reviewer_model="${7:-${BASHCLAW_REVIEWER_CMD:-}}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Step 1: 构建匿名化 review 上下文
    local review_context
    review_context=$(build_review_context \
        "$user_request" \
        "$patch_diff" \
        "$base_validation" \
        "$knowledge_summary" \
        "$risk_tags" \
        "$change_type")

    # Step 2: 生成 prompt
    local prompt
    prompt=$(format_review_prompt "$review_context")

    # Step 3: 调用 reviewer 模型
    # 优先级：配置的命令 > 真实 API > mock 输出
    local raw_review_output
    if [[ -n "$reviewer_model" ]]; then
        # 修复 Critical #3: 移除 eval 防止 shell 注入 RCE
        # 将命令字符串拆分为数组后直接执行，不经过 eval
        local -a reviewer_cmd_arr=()
        read -ra reviewer_cmd_arr <<< "$reviewer_model"
        raw_review_output=$(echo "$prompt" | "${reviewer_cmd_arr[@]}" 2>/dev/null) || {
            echo "REVIEW_ERROR: reviewer model invocation failed" >&2
            jq -n --arg ts "$timestamp" '{
                "status": "ERROR",
                "timestamp": $ts,
                "error": "reviewer model invocation failed",
                "issues": []
            }'
            return 1
        }
    elif type api_has_any_key &>/dev/null && api_has_any_key; then
        # =====================================================================
        # 真实 API 调用模式
        # Reviewer 使用与 Executor 不同的模型：
        #   - 若 Executor 用 Opus（Anthropic），Reviewer 优先用 Codex（OpenAI）
        #   - 若 Executor 用 Codex（OpenAI），Reviewer 优先用 Opus（Anthropic）
        #   - 若只有一个 key，两者可共用同一模型
        # =====================================================================
        echo "[REVIEWER] 使用真实 API 模式" >&2

        # 构建匿名化的 system prompt（不暴露模型身份）
        local review_system_prompt
        review_system_prompt=$(cat <<'REVIEW_SYS'
You are an independent code reviewer. You will receive a review context containing:
- A user request
- A code patch (Patch A)
- Validation results
- Historical knowledge notes

For EACH issue you find, you MUST output ALL 6 required fields in JSON:
{
  "issues": [
    {
      "location": "file_path:line_number",
      "issue_type": "one of: runtime_bug, logic_bug, missing_test, security_risk, regression_risk, requirement_conflict, design_concern",
      "severity": "one of: minor, major, critical",
      "risk_statement": "specific, concrete description",
      "why_it_matters": "concrete impact",
      "verification_plan": "step-by-step verification with executable steps"
    }
  ]
}

Rules:
- Output ONLY valid JSON, no markdown fences, no explanation text
- Do NOT reference any AI model names
- Every risk_statement must be specific and actionable
- Every verification_plan must have at least 10 characters of executable steps
- Location must be in format file:line_number
- If no issues found, output: {"issues": []}
REVIEW_SYS
)

        local api_call_success="false"

        # 统一使用 api_call_auto（优先级：claude CLI > OpenAI > Anthropic）
        # Reviewer 偏好 codex 角色，api_call_auto 会先尝试 claude CLI
        raw_review_output=$(api_call_auto "codex" "${review_system_prompt}" "${prompt}" 4096 2>/dev/null) && api_call_success="true"

        if [[ "${api_call_success}" != "true" ]]; then
            echo "REVIEW_ERROR: API 调用失败，降级检查 mock 输出" >&2
            if [[ -n "${BASHCLAW_REVIEW_MOCK_OUTPUT:-}" ]]; then
                raw_review_output="$BASHCLAW_REVIEW_MOCK_OUTPUT"
            else
                jq -n --arg ts "$timestamp" '{
                    "status": "ERROR",
                    "timestamp": $ts,
                    "error": "API call failed and no mock output available",
                    "issues": []
                }'
                return 1
            fi
        else
            echo "[REVIEWER:API] provider=${API_LAST_PROVIDER:-unknown} model=${API_LAST_MODEL:-unknown} tokens=${API_LAST_TOTAL_TOKENS:-0}" >&2
        fi
    elif [[ -n "${BASHCLAW_REVIEW_MOCK_OUTPUT:-}" ]]; then
        # 测试模式：使用 mock 输出
        raw_review_output="$BASHCLAW_REVIEW_MOCK_OUTPUT"
    else
        echo "REVIEW_ERROR: no reviewer model configured (set BASHCLAW_REVIEWER_CMD, API keys, or BASHCLAW_REVIEW_MOCK_OUTPUT)" >&2
        jq -n --arg ts "$timestamp" '{
            "status": "ERROR",
            "timestamp": $ts,
            "error": "no reviewer model configured",
            "issues": []
        }'
        return 1
    fi

    # Step 4: 解析并验证输出
    local parsed_output
    parsed_output=$(parse_review_output "$raw_review_output") || {
        echo "REVIEW_WARNING: review output parsing had issues, returning partial results" >&2
    }

    # Step 5: 构建最终结果
    local result
    result=$(echo "$parsed_output" | jq \
        --arg ts "$timestamp" \
        --arg change_type "$change_type" \
        --arg risk_tags "$risk_tags" \
        '. + {
            "status": "COMPLETED",
            "timestamp": $ts,
            "change_type": $change_type,
            "risk_tags": ($risk_tags | split(","))
        }')

    # Step 6: 审计日志（trace-level，完整审计在 engine 层处理）
    echo "[REVIEWER:COMPLETED] issues=$(echo "$result" | jq '.valid_count // 0') $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

    echo "$result"
    return 0
}

# -----------------------------------------------------------------------------
# get_issues_by_severity — 按严重程度过滤 issues
#
# 参数:
#   $1 - review_result JSON（run_review 的输出）
#   $2 - severity 过滤值（minor/major/critical）
# 输出:
#   过滤后的 issues JSON 数组（stdout）
# -----------------------------------------------------------------------------
get_issues_by_severity() {
    local review_result="$1"
    local severity="$2"

    echo "$review_result" | jq --arg sev "$severity" '[.issues[] | select(.severity == $sev)]'
}

# -----------------------------------------------------------------------------
# get_issues_by_type — 按 issue_type 过滤 issues
#
# 参数:
#   $1 - review_result JSON（run_review 的输出）
#   $2 - issue_type 过滤值
# 输出:
#   过滤后的 issues JSON 数组（stdout）
# -----------------------------------------------------------------------------
get_issues_by_type() {
    local review_result="$1"
    local issue_type="$2"

    echo "$review_result" | jq --arg t "$issue_type" '[.issues[] | select(.issue_type == $t)]'
}

# -----------------------------------------------------------------------------
# has_critical_issues — 检查是否存在 critical 级别的 issues
#
# 参数:
#   $1 - review_result JSON
# 返回:
#   0 存在 critical issues, 1 不存在
# -----------------------------------------------------------------------------
has_critical_issues() {
    local review_result="$1"
    local count
    count=$(echo "$review_result" | jq '[.issues[] | select(.severity == "critical")] | length')
    [[ "$count" -gt 0 ]]
}

# -----------------------------------------------------------------------------
# has_requirement_conflicts — 检查是否存在需求冲突 issues
#
# 参数:
#   $1 - review_result JSON
# 返回:
#   0 存在, 1 不存在
# -----------------------------------------------------------------------------
has_requirement_conflicts() {
    local review_result="$1"
    local count
    count=$(echo "$review_result" | jq '[.issues[] | select(.issue_type == "requirement_conflict")] | length')
    [[ "$count" -gt 0 ]]
}
