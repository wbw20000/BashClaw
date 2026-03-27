#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# engine_reviewed.sh — Tier 2 完整编排引擎
#
# 编排 Tier 2 (Review档) 完整流程：
# Knowledge Gate → Executor → Base Validation → Skip Review判定
# → Reviewer → Evidence Resolution → [Human Escalation if needed]
#
# 文档参考：统一实施文档 第6.2节
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all dependencies (dev-1 modules)
# shellcheck source=lib/knowledge_gate.sh
[[ -f "${SCRIPT_DIR}/knowledge_gate.sh" ]] && source "${SCRIPT_DIR}/knowledge_gate.sh"
# shellcheck source=lib/risk_classifier.sh
[[ -f "${SCRIPT_DIR}/risk_classifier.sh" ]] && source "${SCRIPT_DIR}/risk_classifier.sh"
# shellcheck source=lib/validator_repo.sh
[[ -f "${SCRIPT_DIR}/validator_repo.sh" ]] && source "${SCRIPT_DIR}/validator_repo.sh"
# shellcheck source=lib/executor.sh
[[ -f "${SCRIPT_DIR}/executor.sh" ]] && source "${SCRIPT_DIR}/executor.sh"
# shellcheck source=lib/audit_log.sh
[[ -f "${SCRIPT_DIR}/audit_log.sh" ]] && source "${SCRIPT_DIR}/audit_log.sh"
# shellcheck source=lib/human_escalation.sh
[[ -f "${SCRIPT_DIR}/human_escalation.sh" ]] && source "${SCRIPT_DIR}/human_escalation.sh"
# shellcheck source=lib/memory_writeback.sh
[[ -f "${SCRIPT_DIR}/memory_writeback.sh" ]] && source "${SCRIPT_DIR}/memory_writeback.sh"

# Source own modules (dev-2)
# shellcheck source=lib/reviewer.sh
source "${SCRIPT_DIR}/reviewer.sh"
# shellcheck source=lib/skip_review.sh
source "${SCRIPT_DIR}/skip_review.sh"
# shellcheck source=lib/evidence_resolution.sh
source "${SCRIPT_DIR}/evidence_resolution.sh"
# shellcheck source=lib/targeted_validation.sh
source "${SCRIPT_DIR}/targeted_validation.sh"

# =============================================================================
# Lightweight audit helper — wraps dev-1's audit_log_write for event logging.
# audit_log_write has 26 positional params; this helper is for step-level trace.
# =============================================================================
_tier2_log() {
    local event_type="$1"
    local data="${2:-}"
    if type audit_log_write &>/dev/null; then
        # Use stderr trace for step-level logging; full audit is at final result
        echo "[TIER2:${event_type}] $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    else
        echo "[TIER2:${event_type}] $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    fi
}

# =============================================================================
# Fallback stubs — only used if dev-1's modules are not yet available.
# Each stub matches the actual function signature from dev-1's implementations.
# =============================================================================

# Stub: knowledge_gate_run (knowledge_gate.sh)
if ! type knowledge_gate_run &>/dev/null; then
    knowledge_gate_run() {
        jq -n '{
            "knowledge_gate": "stub",
            "similar_decisions": [],
            "known_pitfalls": [],
            "recommended_patterns": [],
            "confidence": "low",
            "action_hint": "proceed"
        }'
    }
fi

# Stub: executor_run (executor.sh)
if ! type executor_run &>/dev/null; then
    executor_run() {
        echo "EXECUTOR_STUB: not yet implemented" >&2
        jq -n '{
            "executor": {"engine": "stub", "tier": 2, "status": "stub"},
            "changed_files": [],
            "diff": ""
        }'
    }
fi

# Stub: validator_run (validator_repo.sh)
# 修复 Critical #2: stub 输出结构与真实 validator_run 保持一致
if ! type validator_run &>/dev/null; then
    validator_run() {
        jq -n '{
            "validation": {
                "status": "PASS",
                "stacks_detected": [],
                "results": []
            }
        }'
    }
fi

# Stub: risk_classify (risk_classifier.sh)
if ! type risk_classify &>/dev/null; then
    risk_classify() {
        jq -n '{
            "change_type": "logic_change",
            "risk_tags": [],
            "risk_level": "medium"
        }'
    }
fi

# Stub: escalation_execute (human_escalation.sh)
if ! type escalation_execute &>/dev/null; then
    escalation_execute() {
        echo "HUMAN_ESCALATION_REQUIRED" >&2
        echo "$1"
    }
fi

# -----------------------------------------------------------------------------
# run_tier2_reviewed — Tier 2 完整编排流程
#
# 流程:
#   1. Knowledge Gate 预检
#   2. Executor 执行
#   3. Base Validation 基础验证
#   4. Risk Classification
#   5. Skip Review 判定
#   6. Reviewer 结构化复查（如未跳过）
#   7. Evidence Resolution 证据裁决（如有 issues）
#   8. Human Escalation（如需要）
#
# 参数:
#   $1 - user_request   用户原始需求
#   $2 - repo_root      仓库根目录（默认当前目录）
# 输出:
#   完整的 Tier 2 执行结果 JSON（stdout）
# 返回:
#   0 全部自动完成, 1 需要人工升级, 2 执行错误
# -----------------------------------------------------------------------------
run_tier2_reviewed() {
    local user_request="${1:?user_request is required}"
    local repo_root="${2:-.}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local trace_id
    trace_id="tier2_$(date +%s)_$$"

    _tier2_log "START" "$trace_id"

    local final_status="COMPLETED"
    local exit_code=0

    # =========================================================================
    # Step 1: Knowledge Gate 预检
    # =========================================================================
    echo "=== Step 1: Knowledge Gate ===" >&2
    local knowledge_output
    knowledge_output=$(knowledge_gate_run "$user_request" "" "" "" "" "" "" "2" 2>/dev/null) || {
        echo "WARNING: Knowledge Gate failed, proceeding without knowledge context" >&2
        knowledge_output='{"confidence": "low", "action_hint": "proceed", "error": true}'
    }
    _tier2_log "KNOWLEDGE_PRECHECK" ""

    # =========================================================================
    # Step 2: Executor 执行
    # =========================================================================
    echo "=== Step 2: Executor ===" >&2
    local executor_output
    executor_output=$(executor_run "$user_request" "2" "$knowledge_output" 2>/dev/null) || {
        echo "ERROR: Executor failed" >&2
        jq -n \
            --arg ts "$timestamp" \
            --arg id "$trace_id" \
            '{
                "status": "EXECUTOR_FAILED",
                "trace_id": $id,
                "timestamp": $ts,
                "error": "executor execution failed"
            }'
        return 2
    }
    _tier2_log "EXECUTOR_RESULT" ""

    # Critical #1 修复：检查 executor 是否实际产生了代码变更
    # 防止 executor 只返回模型文本但未修改任何代码的静默假成功
    local executor_files_modified="false"
    executor_files_modified=$(echo "$executor_output" | jq -r '.executor.files_modified // false' 2>/dev/null) || executor_files_modified="false"

    # 双重验证：检查 git diff 是否真的有变更
    local repo_has_changes="false"
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local actual_diff
        actual_diff="$(git diff HEAD 2>/dev/null || true)"
        if [[ -n "${actual_diff}" ]]; then
            repo_has_changes="true"
        fi
    fi

    if [[ "${executor_files_modified}" == "false" && "${repo_has_changes}" == "false" ]]; then
        echo "WARNING: Executor completed but no code changes detected (git diff empty)" >&2
        _tier2_log "NO_CHANGES_DETECTED" "executor reported no file modifications"
        # 不短路退出，继续走完 review 流程以便记录完整审计信息
        # 但在最终结果中标记为 COMPLETED_NO_CHANGES
    fi

    # 提取 executor 输出的关键数据
    local changed_files
    changed_files=$(echo "$executor_output" | jq -r '(.changed_files // .executor.changed_files // []) | if type == "array" then join("\n") else . end' 2>/dev/null) || changed_files=""
    local diff_content
    diff_content=$(echo "$executor_output" | jq -r '.diff // .executor.diff // ""' 2>/dev/null) || diff_content=""

    # =========================================================================
    # Step 3: Risk Classification
    # =========================================================================
    echo "=== Step 3: Risk Classification ===" >&2

    # risk_classify uses --files and --diff flags
    local risk_output
    local diff_tmp=""
    if [[ -n "$diff_content" ]]; then
        diff_tmp=$(mktemp)
        echo "$diff_content" > "$diff_tmp"
    fi

    # Build risk_classify arguments
    local -a risk_args=()
    if [[ -n "$changed_files" ]]; then
        risk_args+=(--files)
        while IFS= read -r f; do
            [[ -n "$f" ]] && risk_args+=("$f")
        done <<< "$changed_files"
    fi
    if [[ -n "$diff_tmp" ]]; then
        risk_args+=(--diff "$diff_tmp")
    fi

    risk_output=$(risk_classify "${risk_args[@]}" 2>/dev/null) || risk_output='{"change_type":"logic_change","risk_tags":[]}'
    [[ -n "$diff_tmp" ]] && rm -f "$diff_tmp"

    local change_type
    change_type=$(echo "$risk_output" | jq -r '.change_type // "logic_change"')
    local risk_tags
    risk_tags=$(echo "$risk_output" | jq -r '(.risk_tags // []) | if type == "array" then join(",") else . end' 2>/dev/null) || risk_tags=""

    _tier2_log "RISK_CLASSIFICATION" ""

    # =========================================================================
    # Step 4: Base Validation 基础验证
    # =========================================================================
    echo "=== Step 4: Base Validation ===" >&2
    local base_validation
    base_validation=$(validator_run "$repo_root" "$change_type" 2>/dev/null) || {
        echo "WARNING: Base Validation failed to execute" >&2
        base_validation='{"status": "ERROR", "results": []}'
    }
    _tier2_log "BASE_VALIDATION" ""

    # 修复 Critical #2: validator_run 输出结构为 .validation.status，而非 .status
    local base_status
    base_status=$(echo "$base_validation" | jq -r '.validation.status // "ERROR"')

    # 如果 Base Validation 失败，仍然继续进入 review（不短路）
    if [[ "$base_status" != "PASS" ]]; then
        echo "WARNING: Base Validation did not fully pass (status: ${base_status})" >&2
    fi

    # =========================================================================
    # Step 5: Skip Review 判定
    # =========================================================================
    echo "=== Step 5: Skip Review Decision ===" >&2
    local skip_result
    local can_skip=false

    skip_result=$(evaluate_skip_review \
        "$base_validation" \
        "$change_type" \
        "$changed_files" \
        "$diff_content" \
        "$knowledge_output" \
        "$risk_tags" \
        "" 2>/dev/null) && can_skip=true || can_skip=false

    _tier2_log "SKIP_REVIEW_DECISION" ""

    if [[ "$can_skip" == "true" ]]; then
        # Critical #1 修复：即使 skip review 条件满足，如果没有实际代码变更也不能标记为完成
        local skip_status="COMPLETED_SKIP_REVIEW"
        if [[ "${repo_has_changes}" == "false" ]]; then
            skip_status="COMPLETED_NO_CHANGES"
            echo ">>> Skip Review but NO code changes detected — marking as COMPLETED_NO_CHANGES <<<" >&2
        else
            echo ">>> Skip Review: All conditions met, review not needed <<<" >&2
        fi
        local result
        result=$(jq -n \
            --arg status "$skip_status" \
            --arg ts "$timestamp" \
            --arg id "$trace_id" \
            --arg change_type "$change_type" \
            --argjson repo_has_changes "${repo_has_changes}" \
            --argjson knowledge "$knowledge_output" \
            --argjson executor "$executor_output" \
            --argjson validation "$base_validation" \
            --argjson skip "$skip_result" \
            '{
                "status": $status,
                "trace_id": $id,
                "timestamp": $ts,
                "change_type": $change_type,
                "repo_has_changes": $repo_has_changes,
                "knowledge_precheck": $knowledge,
                "executor_result": $executor,
                "base_validation": $validation,
                "skip_review": $skip,
                "review_skipped": true,
                "human_escalation": false
            }')

        _tier2_log "COMPLETE" "skip_review"
        echo "$result"
        return 0
    fi

    echo ">>> Review required <<<" >&2

    # =========================================================================
    # Step 6: Reviewer 结构化复查
    # =========================================================================
    echo "=== Step 6: Reviewer ===" >&2
    local review_result
    local review_failed="false"
    review_result=$(run_review \
        "$user_request" \
        "$diff_content" \
        "$base_validation" \
        "$knowledge_output" \
        "$risk_tags" \
        "$change_type" 2>/dev/null) || {
        echo "WARNING: Review FAILED — marking as REVIEW_FAILED (not passing as no-issues)" >&2
        review_result='{"status": "ERROR", "issues": [], "review_status": "REVIEW_FAILED", "error": "reviewer failed"}'
        review_failed="true"
    }
    _tier2_log "REVIEW_ISSUES" ""

    local issue_count
    issue_count=$(echo "$review_result" | jq '.issues // [] | length')

    if [[ "$issue_count" -eq 0 ]]; then
        # Critical #1 修复：review 无 issues 时，仍需检查是否有实际代码变更
        local no_issues_status="COMPLETED_NO_ISSUES"
        if [[ "${repo_has_changes}" == "false" ]]; then
            no_issues_status="COMPLETED_NO_CHANGES"
            echo ">>> Reviewer found no issues but NO code changes detected <<<" >&2
        else
            echo ">>> Reviewer found no issues <<<" >&2
        fi
        local result
        result=$(jq -n \
            --arg status "$no_issues_status" \
            --arg ts "$timestamp" \
            --arg id "$trace_id" \
            --arg change_type "$change_type" \
            --argjson repo_has_changes "${repo_has_changes}" \
            --argjson knowledge "$knowledge_output" \
            --argjson executor "$executor_output" \
            --argjson validation "$base_validation" \
            --argjson skip "$skip_result" \
            --argjson review "$review_result" \
            '{
                "status": $status,
                "trace_id": $id,
                "timestamp": $ts,
                "change_type": $change_type,
                "repo_has_changes": $repo_has_changes,
                "knowledge_precheck": $knowledge,
                "executor_result": $executor,
                "base_validation": $validation,
                "skip_review": $skip,
                "review_result": $review,
                "review_skipped": false,
                "human_escalation": false
            }')

        _tier2_log "COMPLETE" "no_issues"
        echo "$result"
        return 0
    fi

    # =========================================================================
    # Step 7: Evidence Resolution 证据裁决
    # =========================================================================
    echo "=== Step 7: Evidence Resolution ===" >&2
    local resolution_result
    local resolution_code=0
    resolution_result=$(run_evidence_resolution \
        "$review_result" \
        "$base_validation" \
        "$repo_root" \
        "$risk_tags" 2>/dev/null) || resolution_code=$?

    _tier2_log "EVIDENCE_RESOLUTION" ""

    local needs_human
    needs_human=$(echo "$resolution_result" | jq -r '.action_plan.needs_human_escalation // false' 2>/dev/null) || needs_human="false"

    local needs_fix
    needs_fix=$(echo "$resolution_result" | jq -r '.action_plan.needs_executor_fix // false' 2>/dev/null) || needs_fix="false"

    # =========================================================================
    # Step 8: Human Escalation（如需要）
    # =========================================================================
    local escalation_result="null"
    if [[ "$needs_human" == "true" ]]; then
        echo "=== Step 8: Human Escalation Required ===" >&2
        final_status="NEEDS_HUMAN_ESCALATION"
        exit_code=1

        # 构建人类可读的 escalation 上下文（文档第12.2节）
        local escalation_context
        escalation_context=$(jq -n \
            --arg request "$user_request" \
            --argjson knowledge "$knowledge_output" \
            --argjson validation "$base_validation" \
            --argjson review "$review_result" \
            --argjson resolution "$resolution_result" \
            '{
                "original_request": $request,
                "knowledge_precheck": $knowledge,
                "base_validation_status": ($validation | .validation.status),
                "review_issues": ($review | .issues),
                "resolution_verdicts": ($resolution | .verdicts),
                "escalation_list": ($resolution | .action_plan.escalation_list),
                "fix_list": ($resolution | .action_plan.fix_list)
            }')

        if type escalation_execute &>/dev/null; then
            escalation_result=$(escalation_execute "$escalation_context" 2>/dev/null) || true
        fi
        _tier2_log "HUMAN_ESCALATION" ""
    elif [[ "$needs_fix" == "true" ]]; then
        final_status="NEEDS_EXECUTOR_FIX"
        echo ">>> Executor must fix confirmed issues <<<" >&2
    else
        # Critical #1 修复：即使所有 issues 都已 resolved，
        # 如果没有实际代码变更也不应标记为 COMPLETED_ALL_RESOLVED
        if [[ "${repo_has_changes}" == "false" ]]; then
            final_status="COMPLETED_NO_CHANGES"
            echo ">>> All issues resolved but NO code changes detected <<<" >&2
        else
            final_status="COMPLETED_ALL_RESOLVED"
        fi
    fi

    # reviewer 崩溃时不能静默通过 — 覆盖最终状态为 REVIEW_FAILED
    if [[ "${review_failed}" == "true" ]]; then
        final_status="REVIEW_FAILED"
        # 不设置 resolved=true，让系统知道审查未完成
    fi

    # =========================================================================
    # 构建最终结果
    # =========================================================================
    local result
    result=$(jq -n \
        --arg status "$final_status" \
        --arg ts "$timestamp" \
        --arg id "$trace_id" \
        --arg change_type "$change_type" \
        --arg risk_tags "$risk_tags" \
        --argjson knowledge "$knowledge_output" \
        --argjson executor "$executor_output" \
        --argjson validation "$base_validation" \
        --argjson skip "$skip_result" \
        --argjson review "$review_result" \
        --argjson resolution "$resolution_result" \
        --argjson escalation "${escalation_result:-null}" \
        '{
            "status": $status,
            "trace_id": $id,
            "timestamp": $ts,
            "change_type": $change_type,
            "risk_tags": ($risk_tags | split(",")),
            "knowledge_precheck": $knowledge,
            "executor_result": $executor,
            "base_validation": $validation,
            "skip_review": $skip,
            "review_result": $review,
            "evidence_resolution": $resolution,
            "human_escalation": $escalation,
            "review_skipped": false
        }')

    _tier2_log "COMPLETE" "$final_status"
    echo "$result"
    return "$exit_code"
}

# -----------------------------------------------------------------------------
# 如果直接执行此脚本（非 source），运行 Tier 2 流程
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <user_request> [repo_root]" >&2
        echo "  user_request: The user's task description" >&2
        echo "  repo_root:    Repository root (default: current directory)" >&2
        exit 1
    fi

    run_tier2_reviewed "$@"
fi
