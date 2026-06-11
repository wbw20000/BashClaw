#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# skip_review.sh — Skip Review 判定
#
# 9个条件必须同时满足才能跳过 review。
# logic_change/config_change/schema_change/infra_change/mixed_change
# 不允许用"变更小"作为唯一理由跳过。
# 文档参考：统一实施文档 第17节
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies (stub-safe)
# shellcheck source=lib/risk_classifier.sh
[[ -f "${SCRIPT_DIR}/risk_classifier.sh" ]] && source "${SCRIPT_DIR}/risk_classifier.sh"
# shellcheck source=lib/audit_log.sh
[[ -f "${SCRIPT_DIR}/audit_log.sh" ]] && source "${SCRIPT_DIR}/audit_log.sh"

# 低风险 changeType 枚举（guarded against re-source）
[[ -z "${LOW_RISK_CHANGE_TYPES:-}" ]] && readonly LOW_RISK_CHANGE_TYPES="docs_only comment_only test_only"

# 不允许仅凭"变更小"就跳过的 changeType
[[ -z "${NO_SKIP_BY_SIZE_ONLY:-}" ]] && readonly NO_SKIP_BY_SIZE_ONLY="logic_change config_change schema_change infra_change mixed_change"

# 高风险路径关键词
[[ -z "${HIGH_RISK_PATH_KEYWORDS:-}" ]] && readonly HIGH_RISK_PATH_KEYWORDS="auth permission oauth token secret payment billing deploy migration schema prod acl"

# 高风险 diff 内容模式
[[ -z "${HIGH_RISK_DIFF_PATTERNS:-}" ]] && readonly HIGH_RISK_DIFF_PATTERNS="token session jwt role permission tenant secret credential env migration schema index deploy helm docker prod subprocess remote.*call shell.*exec"

# Skip review 阈值
[[ -z "${MAX_FILES_FOR_SKIP:-}" ]] && readonly MAX_FILES_FOR_SKIP=2
[[ -z "${MAX_DIFF_LINES_FOR_SKIP:-}" ]] && readonly MAX_DIFF_LINES_FOR_SKIP=80

# -----------------------------------------------------------------------------
# check_base_validation_pass — 条件(a): Base Validation 全通过
#
# 参数:
#   $1 - base_validation JSON
# 返回:
#   0 全通过, 1 存在失败
# -----------------------------------------------------------------------------
check_base_validation_pass() {
    local base_validation="$1"

    # 修复 Critical #2: validator_run 输出结构为 .validation.status，而非 .status
    local status
    status=$(echo "$base_validation" | jq -r '.validation.status // empty' 2>/dev/null)

    if [[ "$status" == "PASS" ]]; then
        return 0
    fi

    # 也检查是否所有子项都通过（路径修正为 .validation.results[]）
    local has_failures
    has_failures=$(echo "$base_validation" | jq '[.validation.results[]? | select(.status != "PASS")] | length' 2>/dev/null) || has_failures="1"

    if [[ "$has_failures" == "0" ]]; then
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# check_low_risk_change_type — 条件(b): changeType 为低风险倾向
#
# 参数:
#   $1 - changeType
# 返回:
#   0 低风险, 1 非低风险
# -----------------------------------------------------------------------------
check_low_risk_change_type() {
    local change_type="$1"
    local valid_type

    for valid_type in $LOW_RISK_CHANGE_TYPES; do
        if [[ "$change_type" == "$valid_type" ]]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# check_no_high_risk_paths — 条件(c): 未命中高风险路径或 diff 模式
#
# 参数:
#   $1 - changed_files（换行符分隔的文件路径列表）
#   $2 - diff_content（diff 内容文本）
# 返回:
#   0 未命中, 1 命中高风险
# -----------------------------------------------------------------------------
check_no_high_risk_paths() {
    local changed_files="$1"
    local diff_content="$2"

    # 检查文件路径是否包含高风险关键词
    local keyword
    for keyword in $HIGH_RISK_PATH_KEYWORDS; do
        if echo "$changed_files" | grep -qi "$keyword"; then
            return 1
        fi
    done

    # 检查 diff 内容是否包含高风险模式
    local pattern
    for pattern in $HIGH_RISK_DIFF_PATTERNS; do
        if echo "$diff_content" | grep -qiE "$pattern"; then
            return 1
        fi
    done

    return 0
}

# -----------------------------------------------------------------------------
# check_small_change — 条件(d): 修改规模小（文件数≤2，diff行数≤80）
#
# 参数:
#   $1 - changed_files（换行符分隔）
#   $2 - diff_content
# 返回:
#   0 规模小, 1 规模不够小
# -----------------------------------------------------------------------------
check_small_change() {
    local changed_files="$1"
    local diff_content="$2"

    # 计算变更文件数
    local file_count
    file_count=$(echo "$changed_files" | grep -c '.' 2>/dev/null) || file_count=0

    if [[ "$file_count" -gt "$MAX_FILES_FOR_SKIP" ]]; then
        return 1
    fi

    # 计算 diff 行数
    local diff_lines
    diff_lines=$(echo "$diff_content" | wc -l | tr -d ' ')

    if [[ "$diff_lines" -gt "$MAX_DIFF_LINES_FOR_SKIP" ]]; then
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# check_no_new_dependencies — 条件(e): 未新增依赖
#
# 参数:
#   $1 - diff_content
# 返回:
#   0 无新增依赖, 1 有新增依赖
# -----------------------------------------------------------------------------
check_no_new_dependencies() {
    local diff_content="$1"

    # 检查常见的依赖变更模式
    local dep_patterns=(
        '^\+.*"dependencies"'
        '^\+.*"devDependencies"'
        '^\+.*require\('
        '^\+.*import '
        '^\+.*pip install'
        '^\+.*install_requires'
        '^\+.*\[dependencies\]'
        '^\+.*go get '
        '^\+.*cargo add '
    )

    # 检查依赖文件变更
    local dep_files=(
        "package.json"
        "requirements.txt"
        "Pipfile"
        "pyproject.toml"
        "go.mod"
        "Cargo.toml"
        "Gemfile"
        "composer.json"
    )

    for pattern in "${dep_patterns[@]}"; do
        if echo "$diff_content" | grep -qE "$pattern"; then
            return 1
        fi
    done

    return 0
}

# -----------------------------------------------------------------------------
# check_no_sensitive_domains — 条件(f): 未涉及 auth/schema/deploy/migration
#
# 参数:
#   $1 - changed_files
#   $2 - diff_content
# 返回:
#   0 未涉及, 1 涉及
# -----------------------------------------------------------------------------
check_no_sensitive_domains() {
    local changed_files="$1"
    local diff_content="$2"

    local sensitive_keywords="auth schema deploy migration"

    local keyword
    for keyword in $sensitive_keywords; do
        if echo "$changed_files" | grep -qi "$keyword"; then
            return 1
        fi
        if echo "$diff_content" | grep -qi "$keyword"; then
            return 1
        fi
    done

    return 0
}

# -----------------------------------------------------------------------------
# check_knowledge_gate_confidence — 条件(g): Knowledge Gate 命中高相似已验证经验
#
# 可选加分项：如果知识库有高置信度匹配，增强 skip 信心
#
# 参数:
#   $1 - knowledge_gate_output JSON
# 返回:
#   0 高置信度匹配, 1 无匹配或低置信度
# -----------------------------------------------------------------------------
check_knowledge_gate_confidence() {
    local kg_output="$1"

    if [[ -z "$kg_output" ]] || [[ "$kg_output" == "null" ]]; then
        return 1
    fi

    local confidence
    confidence=$(echo "$kg_output" | jq -r '.confidence // empty' 2>/dev/null)

    if [[ "$confidence" == "high" ]]; then
        local action_hint
        action_hint=$(echo "$kg_output" | jq -r '.action_hint // empty' 2>/dev/null)
        if [[ "$action_hint" == "proceed" ]]; then
            return 0
        fi
    fi

    return 1
}

# -----------------------------------------------------------------------------
# check_low_rework_rate — 条件(h): 历史同类问题返工率低
#
# 参数:
#   $1 - change_type
#   $2 - risk_tags（逗号分隔）
# 返回:
#   0 返工率低, 1 返工率高或无数据
# -----------------------------------------------------------------------------
check_low_rework_rate() {
    local change_type="$1"
    local risk_tags="$2"

    # 如果有 audit_log 系统中的历史数据，查询返工率
    if type get_rework_rate &>/dev/null; then
        local rate
        rate=$(get_rework_rate "$change_type" "$risk_tags")
        # 返工率低于 10% 视为低
        if (( $(echo "$rate < 0.10" | bc -l 2>/dev/null || echo "0") )); then
            return 0
        fi
        return 1
    fi

    # 无历史数据时，保守返回：低风险类型默认低返工率
    if check_low_risk_change_type "$change_type"; then
        return 0
    fi

    # 非低风险类型且无数据，保守不跳过
    return 1
}

# -----------------------------------------------------------------------------
# check_no_requirement_conflicts — 条件(i): 无开放性需求解释冲突
#
# 参数:
#   $1 - task_context JSON（可包含需求冲突标记）
# 返回:
#   0 无冲突, 1 有冲突
# -----------------------------------------------------------------------------
check_no_requirement_conflicts() {
    local task_context="$1"

    if [[ -z "$task_context" ]] || [[ "$task_context" == "null" ]]; then
        return 0
    fi

    local has_conflicts
    has_conflicts=$(echo "$task_context" | jq -r '.requirement_conflicts // false' 2>/dev/null)

    if [[ "$has_conflicts" == "true" ]]; then
        return 1
    fi

    # 检查是否有未解决的需求歧义
    local open_ambiguities
    open_ambiguities=$(echo "$task_context" | jq '.open_ambiguities // [] | length' 2>/dev/null)

    if [[ "${open_ambiguities:-0}" -gt 0 ]]; then
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# evaluate_skip_review — 评估是否可以跳过 review
#
# 9个条件必须同时满足。返回结构化的判定结果。
#
# 参数:
#   $1 - base_validation    Base Validation 输出 JSON
#   $2 - change_type        changeType 枚举值
#   $3 - changed_files      变更文件列表（换行符分隔）
#   $4 - diff_content       diff 文本内容
#   $5 - knowledge_gate_out Knowledge Gate 输出 JSON（可选）
#   $6 - risk_tags          风险标签（逗号分隔，可选）
#   $7 - task_context       任务上下文 JSON（可选）
# 输出:
#   判定结果 JSON（stdout）
# 返回:
#   0 可跳过, 1 不可跳过
# -----------------------------------------------------------------------------
evaluate_skip_review() {
    local base_validation="${1:?base_validation is required}"
    local change_type="${2:?change_type is required}"
    local changed_files="${3:?changed_files is required}"
    local diff_content="${4:?diff_content is required}"
    local knowledge_gate_out="${5:-}"
    local risk_tags="${6:-}"
    local task_context="${7:-}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # 逐个检查9个条件，记录每个条件的结果
    local conditions=()
    local all_pass=true
    local skip_reason=""

    # 条件(a): Base Validation 全通过
    if check_base_validation_pass "$base_validation"; then
        conditions+=('{"condition": "base_validation_pass", "met": true}')
    else
        conditions+=('{"condition": "base_validation_pass", "met": false, "reason": "base validation has failures"}')
        all_pass=false
        skip_reason="base_validation_failed"
    fi

    # 条件(b): changeType 为低风险倾向
    if check_low_risk_change_type "$change_type"; then
        conditions+=('{"condition": "low_risk_change_type", "met": true}')
    else
        conditions+=('{"condition": "low_risk_change_type", "met": false, "reason": "changeType '"$change_type"' is not low-risk"}')
        all_pass=false
        skip_reason="change_type_not_low_risk"
    fi

    # 条件(c): 未命中高风险路径或 diff 模式
    if check_no_high_risk_paths "$changed_files" "$diff_content"; then
        conditions+=('{"condition": "no_high_risk_paths", "met": true}')
    else
        conditions+=('{"condition": "no_high_risk_paths", "met": false, "reason": "high-risk path or diff pattern detected"}')
        all_pass=false
        skip_reason="high_risk_detected"
    fi

    # 条件(d): 修改规模小
    if check_small_change "$changed_files" "$diff_content"; then
        conditions+=('{"condition": "small_change", "met": true}')
    else
        conditions+=('{"condition": "small_change", "met": false, "reason": "change exceeds size limits (files>'"$MAX_FILES_FOR_SKIP"' or lines>'"$MAX_DIFF_LINES_FOR_SKIP"')"}')
        all_pass=false
        skip_reason="change_too_large"
    fi

    # 条件(e): 未新增依赖
    if check_no_new_dependencies "$diff_content"; then
        conditions+=('{"condition": "no_new_dependencies", "met": true}')
    else
        conditions+=('{"condition": "no_new_dependencies", "met": false, "reason": "new dependency additions detected in diff"}')
        all_pass=false
        skip_reason="new_dependencies"
    fi

    # 条件(f): 未涉及 auth/schema/deploy/migration
    if check_no_sensitive_domains "$changed_files" "$diff_content"; then
        conditions+=('{"condition": "no_sensitive_domains", "met": true}')
    else
        conditions+=('{"condition": "no_sensitive_domains", "met": false, "reason": "sensitive domain (auth/schema/deploy/migration) detected"}')
        all_pass=false
        skip_reason="sensitive_domain"
    fi

    # 条件(g): Knowledge Gate 高置信度匹配（可选加分项）
    if check_knowledge_gate_confidence "$knowledge_gate_out"; then
        conditions+=('{"condition": "knowledge_gate_confidence", "met": true}')
    else
        conditions+=('{"condition": "knowledge_gate_confidence", "met": false, "reason": "no high-confidence knowledge match (optional)"}')
        # 注意：这是可选加分项，不单独阻止 skip
    fi

    # 条件(h): 历史同类问题返工率低
    if check_low_rework_rate "$change_type" "$risk_tags"; then
        conditions+=('{"condition": "low_rework_rate", "met": true}')
    else
        conditions+=('{"condition": "low_rework_rate", "met": false, "reason": "historical rework rate is not low for this change type"}')
        all_pass=false
        skip_reason="high_rework_rate"
    fi

    # 条件(i): 无开放性需求解释冲突
    if check_no_requirement_conflicts "$task_context"; then
        conditions+=('{"condition": "no_requirement_conflicts", "met": true}')
    else
        conditions+=('{"condition": "no_requirement_conflicts", "met": false, "reason": "open requirement interpretation conflicts exist"}')
        all_pass=false
        skip_reason="requirement_conflicts"
    fi

    # 重要规则：logic_change/config_change/schema_change/infra_change/mixed_change
    # 不允许用"变更小"作为唯一理由跳过
    local is_non_trivial_type=false
    local nt_type
    for nt_type in $NO_SKIP_BY_SIZE_ONLY; do
        if [[ "$change_type" == "$nt_type" ]]; then
            is_non_trivial_type=true
            break
        fi
    done

    if [[ "$is_non_trivial_type" == "true" ]]; then
        # 对于非低风险 changeType，即使所有条件都满足，
        # 也需要确认不是仅凭"变更小"就跳过
        # 必须有其他积极信号（如知识库高置信度匹配）
        local has_positive_signal=false
        if check_knowledge_gate_confidence "$knowledge_gate_out" 2>/dev/null; then
            has_positive_signal=true
        fi
        if check_low_rework_rate "$change_type" "$risk_tags" 2>/dev/null; then
            has_positive_signal=true
        fi

        if [[ "$has_positive_signal" == "false" ]]; then
            all_pass=false
            skip_reason="non_trivial_change_type_requires_positive_signal"
            conditions+=('{"condition": "non_trivial_type_guard", "met": false, "reason": "'"$change_type"' cannot skip review without positive signals beyond small size"}')
        fi
    fi

    # 构建结果 JSON
    local conditions_json="["
    local first=true
    for cond in "${conditions[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            conditions_json+=","
        fi
        conditions_json+="$cond"
    done
    conditions_json+="]"

    local decision
    if [[ "$all_pass" == "true" ]]; then
        decision="SKIP_REVIEW"
    else
        decision="REQUIRE_REVIEW"
    fi

    local result
    result=$(jq -n \
        --arg decision "$decision" \
        --arg reason "$skip_reason" \
        --arg ts "$timestamp" \
        --arg change_type "$change_type" \
        --argjson conditions "$conditions_json" \
        '{
            "decision": $decision,
            "primary_reason": $reason,
            "timestamp": $ts,
            "change_type": $change_type,
            "conditions": $conditions
        }')

    # 审计日志（trace-level）
    echo "[SKIP_REVIEW:${decision}] $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

    echo "$result"

    if [[ "$all_pass" == "true" ]]; then
        return 0
    else
        return 1
    fi
}
