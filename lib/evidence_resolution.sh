#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# evidence_resolution.sh — 证据驱动裁决协议 (Evidence-Driven Resolution Protocol)
#
# 本文档最关键的模块。不依赖第三模型仲裁，而是用证据裁决 reviewer issues。
# 裁决结果：CONFIRMED / REFUTED / UNVERIFIABLE / REQUIREMENT_CONFLICT
# 文档参考：统一实施文档 第11节
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies (stub-safe)
# shellcheck source=lib/targeted_validation.sh
[[ -f "${SCRIPT_DIR}/targeted_validation.sh" ]] && source "${SCRIPT_DIR}/targeted_validation.sh"
# shellcheck source=lib/knowledge_gate.sh
[[ -f "${SCRIPT_DIR}/knowledge_gate.sh" ]] && source "${SCRIPT_DIR}/knowledge_gate.sh"
# shellcheck source=lib/audit_log.sh
[[ -f "${SCRIPT_DIR}/audit_log.sh" ]] && source "${SCRIPT_DIR}/audit_log.sh"

# 裁决结果枚举（guarded against re-source）
[[ -z "${VERDICT_CONFIRMED:-}" ]] && readonly VERDICT_CONFIRMED="CONFIRMED"
[[ -z "${VERDICT_REFUTED:-}" ]] && readonly VERDICT_REFUTED="REFUTED"
[[ -z "${VERDICT_UNVERIFIABLE:-}" ]] && readonly VERDICT_UNVERIFIABLE="UNVERIFIABLE"
[[ -z "${VERDICT_REQUIREMENT_CONFLICT:-}" ]] && readonly VERDICT_REQUIREMENT_CONFLICT="REQUIREMENT_CONFLICT"

# 证据化方式枚举
[[ -z "${EVIDENCE_TARGETED_TEST:-}" ]] && readonly EVIDENCE_TARGETED_TEST="targeted_test"
[[ -z "${EVIDENCE_STATIC_RULE:-}" ]] && readonly EVIDENCE_STATIC_RULE="static_rule"
[[ -z "${EVIDENCE_REPRO_STEP:-}" ]] && readonly EVIDENCE_REPRO_STEP="repro_step"
[[ -z "${EVIDENCE_HISTORICAL_MATCH:-}" ]] && readonly EVIDENCE_HISTORICAL_MATCH="historical_decision_match"
[[ -z "${EVIDENCE_RISK_POLICY:-}" ]] && readonly EVIDENCE_RISK_POLICY="risk_policy_match"

# -----------------------------------------------------------------------------
# phase1_collect_issues — Phase 1: 收集 Reviewer 结构化 issues
#
# 参数:
#   $1 - review_result JSON（reviewer.sh 的 run_review 输出）
# 输出:
#   提取的 issues 数组 JSON（stdout）
# 返回:
#   0 有 issues, 1 无 issues
# -----------------------------------------------------------------------------
phase1_collect_issues() {
    local review_result="$1"

    local issues
    issues=$(echo "$review_result" | jq '.issues // []')

    local count
    count=$(echo "$issues" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "$issues"
        return 1
    fi

    echo "$issues"
    return 0
}

# -----------------------------------------------------------------------------
# attempt_targeted_test — 尝试用 targeted test 验证 issue
#
# 证据化方式 1: 根据 issue 的 verification_plan 生成并执行针对性测试
#
# 参数:
#   $1 - issue JSON
#   $2 - repo_root 仓库根目录
# 输出:
#   证据结果 JSON（stdout）
# -----------------------------------------------------------------------------
attempt_targeted_test() {
    local issue="$1"
    local repo_root="${2:-.}"

    local verification_plan
    verification_plan=$(echo "$issue" | jq -r '.verification_plan // empty')

    if [[ -z "$verification_plan" ]]; then
        echo '{"method": "targeted_test", "status": "NOT_APPLICABLE", "reason": "no verification_plan provided"}'
        return 1
    fi

    # 调用 targeted_validation.sh 的函数
    if type run_targeted_validation &>/dev/null; then
        local result
        result=$(run_targeted_validation "$issue" "$repo_root" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi

    echo '{"method": "targeted_test", "status": "NOT_AVAILABLE", "reason": "targeted_validation not available"}'
    return 1
}

# -----------------------------------------------------------------------------
# attempt_static_rule — 尝试用静态分析/linter/type checker 验证 issue
#
# 证据化方式 2: 使用已有的 lint/typecheck 结果
#
# 参数:
#   $1 - issue JSON
#   $2 - base_validation JSON
# 输出:
#   证据结果 JSON（stdout）
# -----------------------------------------------------------------------------
attempt_static_rule() {
    local issue="$1"
    local base_validation="$2"

    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue_type // empty')
    local location
    location=$(echo "$issue" | jq -r '.location // empty')

    # 从 base_validation 中查找相关的 lint/typecheck 结果
    local file_path
    file_path=$(echo "$location" | cut -d: -f1)

    local relevant_findings
    # 修复 Critical #2: validator_run 输出结构为 .validation.results，而非 .results
    relevant_findings=$(echo "$base_validation" | jq --arg file "$file_path" '
        [.validation.results[]? | select(
            (.type == "lint" or .type == "typecheck") and
            (.details[]? | .file == $file)
        )]' 2>/dev/null) || relevant_findings="[]"

    local finding_count
    finding_count=$(echo "$relevant_findings" | jq 'length')

    if [[ "$finding_count" -gt 0 ]]; then
        jq -n \
            --arg method "$EVIDENCE_STATIC_RULE" \
            --argjson findings "$relevant_findings" \
            '{
                "method": $method,
                "status": "FOUND",
                "findings": $findings,
                "supports_issue": true
            }'
        return 0
    fi

    # 检查是否可以为该 issue 运行特定的静态检查
    if [[ "$issue_type" == "security_risk" ]] || [[ "$issue_type" == "runtime_bug" ]]; then
        # 这些类型的 issue 如果 lint 没有发现，不意味着不存在
        jq -n --arg method "$EVIDENCE_STATIC_RULE" '{
            "method": $method,
            "status": "INCONCLUSIVE",
            "reason": "no static findings for this file, but absence of lint findings does not refute the issue"
        }'
        return 1
    fi

    jq -n --arg method "$EVIDENCE_STATIC_RULE" '{
        "method": $method,
        "status": "NO_FINDINGS",
        "reason": "no relevant static analysis findings"
    }'
    return 1
}

# -----------------------------------------------------------------------------
# attempt_repro_step — 尝试用 repro step 验证 issue
#
# 证据化方式 3: 构造复现步骤
#
# 参数:
#   $1 - issue JSON
#   $2 - repo_root
# 输出:
#   证据结果 JSON（stdout）
# -----------------------------------------------------------------------------
attempt_repro_step() {
    local issue="$1"
    local repo_root="${2:-.}"

    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue_type // empty')

    # repro step 主要适用于 runtime_bug 和 logic_bug
    if [[ "$issue_type" != "runtime_bug" ]] && [[ "$issue_type" != "logic_bug" ]]; then
        jq -n --arg method "$EVIDENCE_REPRO_STEP" '{
            "method": $method,
            "status": "NOT_APPLICABLE",
            "reason": "repro steps are primarily for runtime/logic bugs"
        }'
        return 1
    fi

    local verification_plan
    verification_plan=$(echo "$issue" | jq -r '.verification_plan // empty')

    # 如果有 targeted_validation，委托给它执行 repro
    if type execute_repro_step &>/dev/null; then
        local result
        result=$(execute_repro_step "$issue" "$repo_root" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi

    jq -n --arg method "$EVIDENCE_REPRO_STEP" '{
        "method": $method,
        "status": "NOT_AVAILABLE",
        "reason": "repro execution not available"
    }'
    return 1
}

# -----------------------------------------------------------------------------
# attempt_historical_match — 尝试用知识库历史裁决验证 issue
#
# 证据化方式 4: 查询知识库中的历史裁决
# 注意：边界三 — 知识库命中不是自动裁决
#
# 参数:
#   $1 - issue JSON
# 输出:
#   证据结果 JSON（stdout）
# -----------------------------------------------------------------------------
attempt_historical_match() {
    local issue="$1"

    local risk_statement
    risk_statement=$(echo "$issue" | jq -r '.risk_statement // empty')
    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue_type // empty')
    local location
    location=$(echo "$issue" | jq -r '.location // empty')

    # 修复 Medium #9: 将死代码 knowledge_search 替换为实际存在的函数
    # 优先使用 MCP 语义检索（mcp_search_knowledge），MCP 不可用时回退到 knowledge_gate_run
    local search_query="${risk_statement} ${issue_type}"
    local search_succeeded=false

    # 策略1: 尝试 MCP 语义检索（来自 lib/mcp_client.sh）
    if type mcp_available &>/dev/null && mcp_available 2>/dev/null; then
        if type mcp_search_knowledge &>/dev/null; then
            local mcp_raw=""
            mcp_raw=$(mcp_search_knowledge "${search_query}" 3 2>/dev/null) || true

            if [[ -n "${mcp_raw}" && "${mcp_raw}" != "[]" && "${mcp_raw}" != "null" ]]; then
                # 解析 MCP 结果：提取匹配条目
                local match_count=0
                match_count=$(echo "${mcp_raw}" | jq '
                    if type == "array" then length
                    elif type == "object" and has("results") then (.results | length)
                    else 0
                    end' 2>/dev/null) || match_count=0

                if [[ "${match_count}" -gt 0 ]]; then
                    local matches
                    matches=$(echo "${mcp_raw}" | jq -c '
                        if type == "array" then .
                        elif type == "object" and has("results") then .results
                        else []
                        end' 2>/dev/null) || matches="[]"

                    jq -n \
                        --arg method "$EVIDENCE_HISTORICAL_MATCH" \
                        --argjson matches "${matches}" \
                        --arg confidence "medium" \
                        '{
                            "method": $method,
                            "status": "FOUND",
                            "confidence": $confidence,
                            "matches": $matches,
                            "source": "mcp",
                            "note": "Historical match provides supporting evidence but is NOT an automatic verdict (Boundary Rule 3)"
                        }'
                    return 0
                fi
            fi
        fi
    fi

    # 策略2: 回退到 knowledge_gate 本地搜索（来自 lib/knowledge_gate.sh）
    if type knowledge_gate_search_local &>/dev/null; then
        local local_hits=""
        local_hits=$(knowledge_gate_search_local "${search_query}" 2>/dev/null) || true

        if [[ -n "${local_hits}" && "${local_hits}" != "[]" ]]; then
            local hit_count=0
            hit_count=$(echo "${local_hits}" | jq 'length' 2>/dev/null) || hit_count=0

            if [[ "${hit_count}" -gt 0 ]]; then
                jq -n \
                    --arg method "$EVIDENCE_HISTORICAL_MATCH" \
                    --argjson matches "${local_hits}" \
                    --arg confidence "low" \
                    '{
                        "method": $method,
                        "status": "FOUND",
                        "confidence": $confidence,
                        "matches": $matches,
                        "source": "local",
                        "note": "Historical match provides supporting evidence but is NOT an automatic verdict (Boundary Rule 3)"
                    }'
                return 0
            fi
        fi
    fi

    jq -n --arg method "$EVIDENCE_HISTORICAL_MATCH" '{
        "method": $method,
        "status": "NO_MATCH",
        "reason": "no relevant historical decisions found"
    }'
    return 1
}

# -----------------------------------------------------------------------------
# attempt_risk_policy — 尝试用内部风险策略匹配验证 issue
#
# 证据化方式 5: 检查是否命中已定义的风险策略规则
#
# 参数:
#   $1 - issue JSON
#   $2 - risk_tags（逗号分隔）
# 输出:
#   证据结果 JSON（stdout）
# -----------------------------------------------------------------------------
attempt_risk_policy() {
    local issue="$1"
    local risk_tags="${2:-}"

    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue_type // empty')
    local location
    location=$(echo "$issue" | jq -r '.location // empty')
    local file_path
    file_path=$(echo "$location" | cut -d: -f1)

    # 内置风险策略规则
    local matched_policies="[]"

    # 策略1: security_risk + auth 路径 → 强烈支持 issue
    if [[ "$issue_type" == "security_risk" ]]; then
        if echo "$file_path" | grep -qiE 'auth|permission|token|secret|session'; then
            matched_policies=$(echo "$matched_policies" | jq '. + [{"policy": "SECURITY_IN_AUTH_PATH", "action": "supports_issue", "description": "security issues in auth-related paths require mandatory review"}]')
        fi
    fi

    # 策略2: schema/migration 变更中的 regression_risk → 强烈支持
    if [[ "$issue_type" == "regression_risk" ]]; then
        if echo "$file_path" | grep -qiE 'migration|schema|model'; then
            matched_policies=$(echo "$matched_policies" | jq '. + [{"policy": "REGRESSION_IN_SCHEMA", "action": "supports_issue", "description": "regression risks in schema/migration paths are high priority"}]')
        fi
    fi

    # 策略3: requirement_conflict 任何路径 → 必须升级人工
    if [[ "$issue_type" == "requirement_conflict" ]]; then
        matched_policies=$(echo "$matched_policies" | jq '. + [{"policy": "REQUIREMENT_CONFLICT_ESCALATION", "action": "escalate_human", "description": "requirement conflicts must be escalated to human"}]')
    fi

    # 检查自定义风险标签匹配
    if [[ -n "$risk_tags" ]]; then
        IFS=',' read -ra tags <<< "$risk_tags"
        for tag in "${tags[@]}"; do
            tag=$(echo "$tag" | tr -d ' ')
            if [[ "$tag" == "high_risk" ]] || [[ "$tag" == "critical" ]]; then
                matched_policies=$(echo "$matched_policies" | jq --arg tag "$tag" '. + [{"policy": "HIGH_RISK_TAG", "action": "supports_issue", "description": ("risk tag " + $tag + " indicates elevated concern")}]')
            fi
        done
    fi

    local policy_count
    policy_count=$(echo "$matched_policies" | jq 'length')

    if [[ "$policy_count" -gt 0 ]]; then
        jq -n \
            --arg method "$EVIDENCE_RISK_POLICY" \
            --argjson policies "$matched_policies" \
            '{
                "method": $method,
                "status": "MATCHED",
                "policies": $policies
            }'
        return 0
    fi

    jq -n --arg method "$EVIDENCE_RISK_POLICY" '{
        "method": $method,
        "status": "NO_MATCH",
        "reason": "no risk policies matched"
    }'
    return 1
}

# -----------------------------------------------------------------------------
# phase2_gather_evidence — Phase 2: 对每个 issue 尝试5种证据化方式
#
# 参数:
#   $1 - issue JSON
#   $2 - base_validation JSON
#   $3 - repo_root
#   $4 - risk_tags
# 输出:
#   该 issue 的所有证据结果 JSON（stdout）
# -----------------------------------------------------------------------------
phase2_gather_evidence() {
    local issue="$1"
    local base_validation="$2"
    local repo_root="${3:-.}"
    local risk_tags="${4:-}"

    local evidence_results="[]"

    # 方式1: Targeted Test
    local tt_result
    tt_result=$(attempt_targeted_test "$issue" "$repo_root" 2>/dev/null) || tt_result='{"method":"targeted_test","status":"FAILED"}'
    evidence_results=$(echo "$evidence_results" | jq --argjson r "$tt_result" '. + [$r]')

    # 方式2: Static Rule / Linter / Type Checker
    local sr_result
    sr_result=$(attempt_static_rule "$issue" "$base_validation" 2>/dev/null) || sr_result='{"method":"static_rule","status":"FAILED"}'
    evidence_results=$(echo "$evidence_results" | jq --argjson r "$sr_result" '. + [$r]')

    # 方式3: Repro Step
    local rs_result
    rs_result=$(attempt_repro_step "$issue" "$repo_root" 2>/dev/null) || rs_result='{"method":"repro_step","status":"FAILED"}'
    evidence_results=$(echo "$evidence_results" | jq --argjson r "$rs_result" '. + [$r]')

    # 方式4: Historical Decision Match
    local hm_result
    hm_result=$(attempt_historical_match "$issue" 2>/dev/null) || hm_result='{"method":"historical_decision_match","status":"FAILED"}'
    evidence_results=$(echo "$evidence_results" | jq --argjson r "$hm_result" '. + [$r]')

    # 方式5: Risk Policy Match
    local rp_result
    rp_result=$(attempt_risk_policy "$issue" "$risk_tags" 2>/dev/null) || rp_result='{"method":"risk_policy_match","status":"FAILED"}'
    evidence_results=$(echo "$evidence_results" | jq --argjson r "$rp_result" '. + [$r]')

    echo "$evidence_results"
}

# -----------------------------------------------------------------------------
# phase3_render_verdict — Phase 3: 基于收集的证据执行裁决
#
# 三条重要边界：
#   边界一：pytest 全绿 ≠ reviewer 自动错。只有针对性反证才能 REFUTED
#   边界二：自动生成测试不是绝对真理，测试可能写错
#   边界三：知识库命中不是自动裁决
#
# 参数:
#   $1 - issue JSON
#   $2 - evidence_results JSON 数组
# 输出:
#   裁决结果 JSON（stdout）
# -----------------------------------------------------------------------------
phase3_render_verdict() {
    local issue="$1"
    local evidence_results="$2"

    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue_type // empty')

    # 边界规则：requirement_conflict 直接升级人工
    if [[ "$issue_type" == "requirement_conflict" ]]; then
        jq -n \
            --arg verdict "$VERDICT_REQUIREMENT_CONFLICT" \
            --argjson issue "$issue" \
            --argjson evidence "$evidence_results" \
            '{
                "verdict": $verdict,
                "issue": $issue,
                "evidence": $evidence,
                "reasoning": "requirement_conflict issues are always escalated to human (by protocol rule)",
                "action": "escalate_human"
            }'
        return 0
    fi

    # 分析证据
    local has_confirming_evidence=false
    local has_targeted_refutation=false
    local has_supporting_historical=false
    local has_risk_policy_match=false
    local all_inconclusive=true

    # 检查 targeted test 结果
    local tt_status
    tt_status=$(echo "$evidence_results" | jq -r '[.[] | select(.method == "targeted_test")][0].status // "FAILED"')
    case "$tt_status" in
        "FAIL"|"FOUND"|"CONFIRMED")
            has_confirming_evidence=true
            all_inconclusive=false
            ;;
        "PASS"|"REFUTED")
            # 边界一：只有针对性反证（targeted test 专门测试该 issue 并通过）才能 REFUTED
            # 边界二：自动生成测试也可能错，所以 REFUTED 需要谨慎
            has_targeted_refutation=true
            all_inconclusive=false
            ;;
        "INCONCLUSIVE"|"NOT_APPLICABLE"|"NOT_AVAILABLE"|"FAILED")
            # 不构成任何方向的证据
            ;;
    esac

    # 检查静态分析结果
    local sr_status
    sr_status=$(echo "$evidence_results" | jq -r '[.[] | select(.method == "static_rule")][0].status // "FAILED"')
    if [[ "$sr_status" == "FOUND" ]]; then
        local supports
        supports=$(echo "$evidence_results" | jq -r '[.[] | select(.method == "static_rule")][0].supports_issue // false')
        if [[ "$supports" == "true" ]]; then
            has_confirming_evidence=true
            all_inconclusive=false
        fi
    fi

    # 检查 repro step 结果
    local rs_status
    rs_status=$(echo "$evidence_results" | jq -r '[.[] | select(.method == "repro_step")][0].status // "FAILED"')
    if [[ "$rs_status" == "REPRODUCED" ]] || [[ "$rs_status" == "FOUND" ]]; then
        has_confirming_evidence=true
        all_inconclusive=false
    fi

    # 检查历史匹配（边界三：不是自动裁决，只是支持证据）
    local hm_status
    hm_status=$(echo "$evidence_results" | jq -r '[.[] | select(.method == "historical_decision_match")][0].status // "FAILED"')
    if [[ "$hm_status" == "FOUND" ]]; then
        has_supporting_historical=true
        # 注意：不设置 all_inconclusive=false，因为历史匹配不能独立裁决
    fi

    # 检查风险策略匹配
    local rp_status
    rp_status=$(echo "$evidence_results" | jq -r '[.[] | select(.method == "risk_policy_match")][0].status // "FAILED"')
    if [[ "$rp_status" == "MATCHED" ]]; then
        has_risk_policy_match=true
        # 策略匹配是支持信号但不独立裁决
        local escalate_action
        escalate_action=$(echo "$evidence_results" | jq -r '[.[] | select(.method == "risk_policy_match")][0].policies[]?.action // empty' | grep -c "escalate_human" 2>/dev/null) || escalate_action=0
        if [[ "$escalate_action" -gt 0 ]]; then
            # 风险策略要求升级人工
            jq -n \
                --arg verdict "$VERDICT_UNVERIFIABLE" \
                --argjson issue "$issue" \
                --argjson evidence "$evidence_results" \
                '{
                    "verdict": $verdict,
                    "issue": $issue,
                    "evidence": $evidence,
                    "reasoning": "risk policy mandates human escalation for this issue type in this path",
                    "action": "escalate_human"
                }'
            return 0
        fi
    fi

    # 裁决逻辑
    local verdict
    local reasoning
    local action

    if [[ "$has_confirming_evidence" == "true" ]]; then
        # 有硬证据支持 issue → CONFIRMED
        verdict="$VERDICT_CONFIRMED"
        reasoning="issue confirmed by evidence (targeted test failure, static finding, or repro)"
        action="executor_must_fix"

        # 如果还有历史匹配作为额外支持，增强置信度
        if [[ "$has_supporting_historical" == "true" ]]; then
            reasoning="${reasoning}; additionally supported by historical decision match"
        fi

    elif [[ "$has_targeted_refutation" == "true" ]]; then
        # 有针对性反证 → REFUTED（但需注意边界二：测试可能写错）
        verdict="$VERDICT_REFUTED"
        reasoning="issue refuted by targeted test (test specifically designed for this issue passed)"
        action="record_and_skip"

        # 如果风险策略或历史匹配支持该 issue，降低 REFUTED 信心
        if [[ "$has_supporting_historical" == "true" ]] || [[ "$has_risk_policy_match" == "true" ]]; then
            verdict="$VERDICT_UNVERIFIABLE"
            reasoning="targeted test passed but historical/policy evidence conflicts — cannot confidently refute (Boundary Rule 2: auto-generated tests may be wrong)"
            action="escalate_human"
        fi

    elif [[ "$all_inconclusive" == "true" ]] || {
        [[ "$has_targeted_refutation" == "false" ]] && [[ "$has_confirming_evidence" == "false" ]];
    }; then
        # 无法构造有效验证 → UNVERIFIABLE
        verdict="$VERDICT_UNVERIFIABLE"
        reasoning="no conclusive evidence found to confirm or refute this issue"
        action="escalate_human"

        # 如果有历史匹配或策略匹配，附带说明
        if [[ "$has_supporting_historical" == "true" ]]; then
            reasoning="${reasoning}; note: historical knowledge suggests this issue type is real (Boundary Rule 3: not auto-verdict)"
        fi
        if [[ "$has_risk_policy_match" == "true" ]]; then
            reasoning="${reasoning}; note: risk policy flagged this area"
        fi
    fi

    jq -n \
        --arg verdict "$verdict" \
        --arg reasoning "$reasoning" \
        --arg action "$action" \
        --argjson issue "$issue" \
        --argjson evidence "$evidence_results" \
        '{
            "verdict": $verdict,
            "issue": $issue,
            "evidence": $evidence,
            "reasoning": $reasoning,
            "action": $action
        }'
}

# -----------------------------------------------------------------------------
# phase4_drive_actions — Phase 4: 驱动后续动作
#
# 汇总所有 issue 的裁决结果，生成后续动作计划。
#
# 参数:
#   $1 - verdicts JSON 数组（phase3 输出的集合）
# 输出:
#   动作计划 JSON（stdout）
# -----------------------------------------------------------------------------
phase4_drive_actions() {
    local verdicts="$1"

    local confirmed_count
    confirmed_count=$(echo "$verdicts" | jq '[.[] | select(.verdict == "CONFIRMED")] | length')
    local refuted_count
    refuted_count=$(echo "$verdicts" | jq '[.[] | select(.verdict == "REFUTED")] | length')
    local unverifiable_count
    unverifiable_count=$(echo "$verdicts" | jq '[.[] | select(.verdict == "UNVERIFIABLE")] | length')
    local req_conflict_count
    req_conflict_count=$(echo "$verdicts" | jq '[.[] | select(.verdict == "REQUIREMENT_CONFLICT")] | length')

    local needs_human_escalation=false
    local needs_executor_fix=false

    if [[ "$confirmed_count" -gt 0 ]]; then
        needs_executor_fix=true
    fi
    if [[ "$unverifiable_count" -gt 0 ]] || [[ "$req_conflict_count" -gt 0 ]]; then
        needs_human_escalation=true
    fi

    # 提取 CONFIRMED issues 作为 executor 修复清单
    local fix_list
    fix_list=$(echo "$verdicts" | jq '[.[] | select(.verdict == "CONFIRMED") | {
        location: .issue.location,
        issue_type: .issue.issue_type,
        severity: .issue.severity,
        risk_statement: .issue.risk_statement,
        evidence_summary: (.evidence | map(.method + ":" + .status) | join(", "))
    }]')

    # 提取需要人工处理的 issues
    local escalation_list
    escalation_list=$(echo "$verdicts" | jq '[.[] | select(.verdict == "UNVERIFIABLE" or .verdict == "REQUIREMENT_CONFLICT") | {
        location: .issue.location,
        issue_type: .issue.issue_type,
        severity: .issue.severity,
        risk_statement: .issue.risk_statement,
        verdict: .verdict,
        reasoning: .reasoning
    }]')

    # 提取 REFUTED issues 作为记录
    local refuted_list
    refuted_list=$(echo "$verdicts" | jq '[.[] | select(.verdict == "REFUTED") | {
        location: .issue.location,
        issue_type: .issue.issue_type,
        risk_statement: .issue.risk_statement,
        reasoning: .reasoning
    }]')

    jq -n \
        --argjson confirmed "$confirmed_count" \
        --argjson refuted "$refuted_count" \
        --argjson unverifiable "$unverifiable_count" \
        --argjson req_conflict "$req_conflict_count" \
        --argjson needs_fix "$needs_executor_fix" \
        --argjson needs_human "$needs_human_escalation" \
        --argjson fix_list "$fix_list" \
        --argjson escalation_list "$escalation_list" \
        --argjson refuted_list "$refuted_list" \
        '{
            "summary": {
                "confirmed": $confirmed,
                "refuted": $refuted,
                "unverifiable": $unverifiable,
                "requirement_conflict": $req_conflict,
                "total": ($confirmed + $refuted + $unverifiable + $req_conflict)
            },
            "needs_executor_fix": $needs_fix,
            "needs_human_escalation": $needs_human,
            "fix_list": $fix_list,
            "escalation_list": $escalation_list,
            "refuted_list": $refuted_list
        }'
}

# -----------------------------------------------------------------------------
# run_evidence_resolution — 执行完整的证据驱动裁决流程
#
# 编排四个 Phase：收集 → 证据化 → 裁决 → 驱动动作
#
# 参数:
#   $1 - review_result      Reviewer 输出 JSON
#   $2 - base_validation    Base Validation 输出 JSON
#   $3 - repo_root          仓库根目录
#   $4 - risk_tags          风险标签（逗号分隔）
# 输出:
#   完整裁决结果 JSON（stdout）
# 返回:
#   0 全部裁决完成, 1 需要人工升级, 2 无 issues
# -----------------------------------------------------------------------------
run_evidence_resolution() {
    local review_result="${1:?review_result is required}"
    local base_validation="${2:?base_validation is required}"
    local repo_root="${3:-.}"
    local risk_tags="${4:-}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Phase 1: 收集 issues
    local issues
    issues=$(phase1_collect_issues "$review_result") || {
        jq -n --arg ts "$timestamp" '{
            "status": "NO_ISSUES",
            "timestamp": $ts,
            "message": "reviewer found no issues, resolution not needed"
        }'
        return 2
    }

    local issue_count
    issue_count=$(echo "$issues" | jq 'length')

    # Phase 2 + Phase 3: 对每个 issue 收集证据并裁决
    local verdicts="[]"
    for ((i = 0; i < issue_count; i++)); do
        local issue
        issue=$(echo "$issues" | jq ".[$i]")

        # Phase 2: 收集证据
        local evidence
        evidence=$(phase2_gather_evidence "$issue" "$base_validation" "$repo_root" "$risk_tags")

        # Phase 3: 执行裁决
        local verdict
        verdict=$(phase3_render_verdict "$issue" "$evidence")

        verdicts=$(echo "$verdicts" | jq --argjson v "$verdict" '. + [$v]')
    done

    # Phase 4: 驱动后续动作
    local action_plan
    action_plan=$(phase4_drive_actions "$verdicts")

    # 构建完整结果
    local result
    result=$(jq -n \
        --arg ts "$timestamp" \
        --argjson verdicts "$verdicts" \
        --argjson action_plan "$action_plan" \
        '{
            "status": "COMPLETED",
            "timestamp": $ts,
            "verdicts": $verdicts,
            "action_plan": $action_plan
        }')

    # 审计日志（trace-level）
    echo "[EVIDENCE_RESOLUTION:COMPLETED] $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

    echo "$result"

    # 根据结果返回不同代码
    local needs_human
    needs_human=$(echo "$action_plan" | jq -r '.needs_human_escalation')
    if [[ "$needs_human" == "true" ]]; then
        return 1
    fi
    return 0
}
