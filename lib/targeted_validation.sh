#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# targeted_validation.sh — 针对性验证执行器
#
# 根据 reviewer 的 verification_plan 生成并执行 targeted test。
# 输出针对性验证结果：通过/失败/不可执行。
# 文档参考：统一实施文档 第11节 Phase 2
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies (stub-safe)
# shellcheck source=lib/audit_log.sh
[[ -f "${SCRIPT_DIR}/audit_log.sh" ]] && source "${SCRIPT_DIR}/audit_log.sh"

# 验证结果枚举（guarded against re-source）
[[ -z "${TV_PASS:-}" ]] && readonly TV_PASS="PASS"
[[ -z "${TV_FAIL:-}" ]] && readonly TV_FAIL="FAIL"
[[ -z "${TV_ERROR:-}" ]] && readonly TV_ERROR="ERROR"
[[ -z "${TV_NOT_EXECUTABLE:-}" ]] && readonly TV_NOT_EXECUTABLE="NOT_EXECUTABLE"
[[ -z "${TV_TIMEOUT:-}" ]] && readonly TV_TIMEOUT="TIMEOUT"

# 默认超时时间（秒）
[[ -z "${DEFAULT_VALIDATION_TIMEOUT:-}" ]] && readonly DEFAULT_VALIDATION_TIMEOUT=60

# -----------------------------------------------------------------------------
# detect_test_framework — 检测项目使用的测试框架
#
# 参数:
#   $1 - repo_root
# 输出:
#   检测到的测试框架信息 JSON（stdout）
# -----------------------------------------------------------------------------
detect_test_framework() {
    local repo_root="$1"

    local frameworks="[]"

    # Python: pytest
    if [[ -f "${repo_root}/pytest.ini" ]] || \
       [[ -f "${repo_root}/pyproject.toml" ]] || \
       [[ -f "${repo_root}/setup.cfg" ]]; then
        if command -v pytest &>/dev/null; then
            frameworks=$(echo "$frameworks" | jq '. + [{"name": "pytest", "command": "pytest", "language": "python"}]')
        fi
    fi

    # JavaScript/TypeScript: jest/mocha/vitest
    if [[ -f "${repo_root}/package.json" ]]; then
        local test_script
        test_script=$(jq -r '.scripts.test // empty' "${repo_root}/package.json" 2>/dev/null) || true
        if [[ -n "$test_script" ]]; then
            local runner="npm"
            if [[ -f "${repo_root}/pnpm-lock.yaml" ]]; then
                runner="pnpm"
            elif [[ -f "${repo_root}/yarn.lock" ]]; then
                runner="yarn"
            fi
            frameworks=$(echo "$frameworks" | jq --arg runner "$runner" '. + [{"name": "npm_test", "command": ($runner + " test"), "language": "javascript"}]')
        fi
    fi

    # Shell: bats
    if command -v bats &>/dev/null; then
        frameworks=$(echo "$frameworks" | jq '. + [{"name": "bats", "command": "bats", "language": "shell"}]')
    fi

    # Go: go test
    if [[ -f "${repo_root}/go.mod" ]] && command -v go &>/dev/null; then
        frameworks=$(echo "$frameworks" | jq '. + [{"name": "go_test", "command": "go test", "language": "go"}]')
    fi

    # Rust: cargo test
    if [[ -f "${repo_root}/Cargo.toml" ]] && command -v cargo &>/dev/null; then
        frameworks=$(echo "$frameworks" | jq '. + [{"name": "cargo_test", "command": "cargo test", "language": "rust"}]')
    fi

    echo "$frameworks"
}

# -----------------------------------------------------------------------------
# _generate_basic_test — 内置基本测试生成器（无需外部模型）
#
# 根据 issue 类型生成最基本的可运行测试脚本（shell）。
# 测试虽然简单，但能执行并给出 PASS/FAIL 结果。
#
# 参数:
#   $1 - issue_type（missing_test / security_risk / logic_bug / 其他）
#   $2 - location（文件路径:行号）
#   $3 - verification_plan（reviewer 提供的验证计划）
#   $4 - risk_statement（风险描述）
#   $5 - repo_root
# 输出:
#   生成的测试脚本内容（stdout）
# 返回:
#   0 - 成功生成
#   1 - 无法生成
# -----------------------------------------------------------------------------
_generate_basic_test() {
    local issue_type="$1"
    local location="$2"
    local verification_plan="$3"
    local risk_statement="$4"
    local repo_root="$5"

    # 从 location 中提取文件路径和行号
    local target_file=""
    local target_line=""
    if [[ "$location" == *":"* ]]; then
        target_file="${location%%:*}"
        target_line="${location##*:}"
    else
        target_file="$location"
    fi

    # 确定目标文件的绝对路径
    local abs_target=""
    if [[ -n "$target_file" ]]; then
        if [[ "$target_file" == /* ]]; then
            abs_target="$target_file"
        else
            abs_target="${repo_root}/${target_file}"
        fi
    fi

    # 生成测试脚本 header
    local test_content=""
    test_content+="#!/usr/bin/env bash"$'\n'
    test_content+="# Auto-generated targeted test by BashClaw"$'\n'
    test_content+="# Issue type: ${issue_type}"$'\n'
    test_content+="# Location: ${location}"$'\n'
    test_content+="# Risk: ${risk_statement}"$'\n'
    test_content+="# Verification plan: ${verification_plan}"$'\n'
    test_content+="set -euo pipefail"$'\n'
    test_content+=""$'\n'
    test_content+="REPO_ROOT=\"${repo_root}\""$'\n'
    test_content+="TARGET_FILE=\"${abs_target}\""$'\n'
    test_content+="TARGET_LINE=\"${target_line}\""$'\n'
    test_content+="ERRORS=0"$'\n'
    test_content+=""$'\n'
    test_content+='fail() { echo "FAIL: $1" >&2; ERRORS=$((ERRORS + 1)); }'$'\n'
    test_content+='pass() { echo "PASS: $1"; }'$'\n'
    test_content+=""$'\n'

    case "$issue_type" in
        missing_test)
            test_content+=$(_gen_missing_test_body "$abs_target" "$target_line" "$verification_plan")
            ;;
        security_risk)
            test_content+=$(_gen_security_risk_body "$abs_target" "$target_line" "$verification_plan")
            ;;
        logic_bug)
            test_content+=$(_gen_logic_bug_body "$abs_target" "$target_line" "$verification_plan")
            ;;
        *)
            test_content+=$(_gen_generic_body "$abs_target" "$target_line" "$verification_plan")
            ;;
    esac

    # 生成测试脚本 footer
    test_content+=""$'\n'
    test_content+='if [[ "$ERRORS" -gt 0 ]]; then'$'\n'
    test_content+='    echo "Targeted test completed with $ERRORS error(s)" >&2'$'\n'
    test_content+='    exit 1'$'\n'
    test_content+='fi'$'\n'
    test_content+='echo "All targeted checks passed"'$'\n'
    test_content+='exit 0'$'\n'

    echo "$test_content"
    return 0
}

# --- 各 issue type 的测试 body 生成 ---

_gen_missing_test_body() {
    local abs_target="$1"
    local target_line="$2"
    local verification_plan="$3"
    local body=""

    body+="# === Missing Test Checks ==="$'\n'
    body+=""$'\n'

    # 检查 1: 目标文件是否存在
    body+='# Check: target file exists'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    pass "Target file exists: $TARGET_FILE"'$'\n'
    body+='else'$'\n'
    body+='    fail "Target file not found: $TARGET_FILE"'$'\n'
    body+='fi'$'\n'
    body+=""$'\n'

    # 检查 2: 目标行号是否存在
    body+='# Check: target line is reachable'$'\n'
    body+='if [[ -n "$TARGET_LINE" && -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    LINE_COUNT=$(wc -l < "$TARGET_FILE")'$'\n'
    body+='    if [[ "$TARGET_LINE" -le "$LINE_COUNT" ]]; then'$'\n'
    body+='        pass "Target line $TARGET_LINE is within file (${LINE_COUNT} lines)"'$'\n'
    body+='    else'$'\n'
    body+='        fail "Target line $TARGET_LINE exceeds file length (${LINE_COUNT} lines)"'$'\n'
    body+='    fi'$'\n'
    body+='fi'$'\n'
    body+=""$'\n'

    # 检查 3: 如果是 shell 脚本，做语法检查
    body+='# Check: if shell script, syntax validation'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    case "$TARGET_FILE" in'$'\n'
    body+='        *.sh|*.bash)'$'\n'
    body+='            if bash -n "$TARGET_FILE" 2>/dev/null; then'$'\n'
    body+='                pass "Shell syntax check passed for $TARGET_FILE"'$'\n'
    body+='            else'$'\n'
    body+='                fail "Shell syntax error in $TARGET_FILE"'$'\n'
    body+='            fi'$'\n'
    body+='            ;;'$'\n'
    body+='        *.py)'$'\n'
    body+='            if command -v python3 &>/dev/null; then'$'\n'
    body+='                if python3 -c "import ast; ast.parse(open(\"$TARGET_FILE\").read())" 2>/dev/null; then'$'\n'
    body+='                    pass "Python syntax check passed for $TARGET_FILE"'$'\n'
    body+='                else'$'\n'
    body+='                    fail "Python syntax error in $TARGET_FILE"'$'\n'
    body+='                fi'$'\n'
    body+='            fi'$'\n'
    body+='            ;;'$'\n'
    body+='    esac'$'\n'
    body+='fi'$'\n'

    echo "$body"
}

_gen_security_risk_body() {
    local abs_target="$1"
    local target_line="$2"
    local verification_plan="$3"
    local body=""

    body+="# === Security Risk Checks ==="$'\n'
    body+=""$'\n'

    # 检查 1: 目标文件存在
    body+='# Check: target file exists'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    pass "Target file exists: $TARGET_FILE"'$'\n'
    body+='else'$'\n'
    body+='    fail "Target file not found: $TARGET_FILE"'$'\n'
    body+='fi'$'\n'
    body+=""$'\n'

    # 检查 2: 常见安全反模式检测
    body+='# Check: common security anti-patterns'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    SECURITY_ISSUES=0'$'\n'
    body+=""$'\n'
    body+='    # Check for eval usage'$'\n'
    body+='    if grep -n "eval " "$TARGET_FILE" >/dev/null 2>&1; then'$'\n'
    body+='        echo "WARNING: eval usage found in $TARGET_FILE" >&2'$'\n'
    body+='        SECURITY_ISSUES=$((SECURITY_ISSUES + 1))'$'\n'
    body+='    fi'$'\n'
    body+=""$'\n'
    body+='    # Check for unquoted variable expansions in shell scripts'$'\n'
    body+='    case "$TARGET_FILE" in'$'\n'
    body+='        *.sh|*.bash)'$'\n'
    body+='            if grep -nP "\$\{?\w+\}?\s" "$TARGET_FILE" 2>/dev/null | grep -v "\"" >/dev/null 2>&1; then'$'\n'
    body+='                echo "WARNING: possible unquoted variable expansion in $TARGET_FILE" >&2'$'\n'
    body+='            fi'$'\n'
    body+='            ;;'$'\n'
    body+='    esac'$'\n'
    body+=""$'\n'
    body+='    # Check for hardcoded secrets patterns'$'\n'
    body+='    if grep -niE "(password|secret|api_key|token)\s*=" "$TARGET_FILE" >/dev/null 2>&1; then'$'\n'
    body+='        echo "WARNING: possible hardcoded secret in $TARGET_FILE" >&2'$'\n'
    body+='        SECURITY_ISSUES=$((SECURITY_ISSUES + 1))'$'\n'
    body+='    fi'$'\n'
    body+=""$'\n'
    body+='    if [[ "$SECURITY_ISSUES" -gt 0 ]]; then'$'\n'
    body+='        fail "Found $SECURITY_ISSUES security concern(s) in $TARGET_FILE"'$'\n'
    body+='    else'$'\n'
    body+='        pass "No obvious security anti-patterns detected in $TARGET_FILE"'$'\n'
    body+='    fi'$'\n'
    body+='fi'$'\n'
    body+=""$'\n'

    # 检查 3: 文件权限
    body+='# Check: file permissions (should not be world-writable)'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    if [[ -w "$TARGET_FILE" ]] && stat --format="%a" "$TARGET_FILE" 2>/dev/null | grep -q "..7\|.7."; then'$'\n'
    body+='        fail "File has overly permissive permissions: $TARGET_FILE"'$'\n'
    body+='    else'$'\n'
    body+='        pass "File permissions OK: $TARGET_FILE"'$'\n'
    body+='    fi'$'\n'
    body+='fi'$'\n'

    echo "$body"
}

_gen_logic_bug_body() {
    local abs_target="$1"
    local target_line="$2"
    local verification_plan="$3"
    local body=""

    body+="# === Logic Bug Checks ==="$'\n'
    body+=""$'\n'

    # 检查 1: 目标文件存在
    body+='# Check: target file exists'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    pass "Target file exists: $TARGET_FILE"'$'\n'
    body+='else'$'\n'
    body+='    fail "Target file not found: $TARGET_FILE"'$'\n'
    body+='fi'$'\n'
    body+=""$'\n'

    # 检查 2: 目标行号可达 + 上下文提取
    body+='# Check: target line context'$'\n'
    body+='if [[ -n "$TARGET_LINE" && -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    LINE_COUNT=$(wc -l < "$TARGET_FILE")'$'\n'
    body+='    if [[ "$TARGET_LINE" -le "$LINE_COUNT" ]]; then'$'\n'
    body+='        pass "Target line $TARGET_LINE is reachable"'$'\n'
    body+='        # Extract context around the target line'$'\n'
    body+='        START=$((TARGET_LINE > 5 ? TARGET_LINE - 5 : 1))'$'\n'
    body+='        END=$((TARGET_LINE + 5))'$'\n'
    body+='        echo "--- Context around line $TARGET_LINE ---"'$'\n'
    body+='        sed -n "${START},${END}p" "$TARGET_FILE" 2>/dev/null || true'$'\n'
    body+='        echo "--- End context ---"'$'\n'
    body+='    else'$'\n'
    body+='        fail "Target line $TARGET_LINE exceeds file length (${LINE_COUNT} lines)"'$'\n'
    body+='    fi'$'\n'
    body+='fi'$'\n'
    body+=""$'\n'

    # 检查 3: 如果是 shell 脚本，检查常见 logic bug 模式
    body+='# Check: common logic bug patterns in shell scripts'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    case "$TARGET_FILE" in'$'\n'
    body+='        *.sh|*.bash)'$'\n'
    body+='            # Check for = vs == in bash tests'$'\n'
    body+='            if grep -n "\[\[.*[^!=]=[^=]" "$TARGET_FILE" >/dev/null 2>&1; then'$'\n'
    body+='                echo "INFO: single = in [[ ]] found (may be intentional)" >&2'$'\n'
    body+='            fi'$'\n'
    body+='            # Syntax check'$'\n'
    body+='            if bash -n "$TARGET_FILE" 2>/dev/null; then'$'\n'
    body+='                pass "Shell syntax check passed"'$'\n'
    body+='            else'$'\n'
    body+='                fail "Shell syntax error in $TARGET_FILE"'$'\n'
    body+='            fi'$'\n'
    body+='            ;;'$'\n'
    body+='    esac'$'\n'
    body+='fi'$'\n'

    echo "$body"
}

_gen_generic_body() {
    local abs_target="$1"
    local target_line="$2"
    local verification_plan="$3"
    local body=""

    body+="# === Generic Checks ==="$'\n'
    body+=""$'\n'

    # 检查 1: 目标文件存在
    body+='# Check: target file exists'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    pass "Target file exists: $TARGET_FILE"'$'\n'
    body+='else'$'\n'
    body+='    fail "Target file not found: $TARGET_FILE"'$'\n'
    body+='fi'$'\n'
    body+=""$'\n'

    # 检查 2: 文件非空
    body+='# Check: file is not empty'$'\n'
    body+='if [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" && -s "$TARGET_FILE" ]]; then'$'\n'
    body+='    pass "Target file is non-empty"'$'\n'
    body+='elif [[ -n "$TARGET_FILE" && -f "$TARGET_FILE" ]]; then'$'\n'
    body+='    fail "Target file is empty: $TARGET_FILE"'$'\n'
    body+='fi'$'\n'

    echo "$body"
}

# -----------------------------------------------------------------------------
# generate_targeted_test — 根据 issue 的 verification_plan 生成测试代码
#
# 参数:
#   $1 - issue JSON
#   $2 - test_framework JSON（detect_test_framework 输出中的一项）
#   $3 - repo_root
# 输出:
#   生成的测试信息 JSON（stdout），包含 test_file_path 和 test_content
# -----------------------------------------------------------------------------
generate_targeted_test() {
    local issue="$1"
    local test_framework="$2"
    local repo_root="$3"

    local verification_plan
    verification_plan=$(echo "$issue" | jq -r '.verification_plan // empty')
    local location
    location=$(echo "$issue" | jq -r '.location // empty')
    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue_type // empty')
    local risk_statement
    risk_statement=$(echo "$issue" | jq -r '.risk_statement // empty')

    local framework_name
    framework_name=$(echo "$test_framework" | jq -r '.name // empty')
    local language
    language=$(echo "$test_framework" | jq -r '.language // empty')

    # 生成测试文件路径
    local test_dir="${repo_root}/.bashclaw_targeted_tests"
    mkdir -p "$test_dir"

    local timestamp_slug
    timestamp_slug=$(date +"%Y%m%d_%H%M%S")
    local test_file

    case "$language" in
        python)
            test_file="${test_dir}/test_targeted_${timestamp_slug}.py"
            ;;
        javascript)
            test_file="${test_dir}/test_targeted_${timestamp_slug}.test.js"
            ;;
        shell)
            test_file="${test_dir}/test_targeted_${timestamp_slug}.bats"
            ;;
        go)
            test_file="${test_dir}/targeted_${timestamp_slug}_test.go"
            ;;
        *)
            test_file="${test_dir}/test_targeted_${timestamp_slug}.sh"
            ;;
    esac

    # 如果有外部模型可用于生成测试代码
    if [[ -n "${BASHCLAW_TEST_GEN_CMD:-}" ]]; then
        local gen_prompt
        gen_prompt="Generate a ${language} test that verifies the following issue:
Location: ${location}
Issue type: ${issue_type}
Risk: ${risk_statement}
Verification plan: ${verification_plan}

Output ONLY the test code, no explanation."

        # 修复 Critical #3: 移除 eval 防止 shell 注入 RCE
        local -a test_gen_cmd_arr=()
        read -ra test_gen_cmd_arr <<< "$BASHCLAW_TEST_GEN_CMD"
        local test_content
        test_content=$(echo "$gen_prompt" | "${test_gen_cmd_arr[@]}" 2>/dev/null) || true

        if [[ -n "$test_content" ]]; then
            echo "$test_content" > "$test_file"
            jq -n \
                --arg file "$test_file" \
                --arg framework "$framework_name" \
                --arg language "$language" \
                --arg source "model_generated" \
                '{
                    "test_file": $file,
                    "framework": $framework,
                    "language": $language,
                    "source": $source,
                    "generated": true
                }'
            return 0
        fi
    fi

    # 如果有 mock 测试内容（用于测试此模块）
    if [[ -n "${BASHCLAW_MOCK_TEST_CONTENT:-}" ]]; then
        echo "$BASHCLAW_MOCK_TEST_CONTENT" > "$test_file"
        jq -n \
            --arg file "$test_file" \
            --arg framework "$framework_name" \
            --arg language "$language" \
            --arg source "mock" \
            '{
                "test_file": $file,
                "framework": $framework,
                "language": $language,
                "source": $source,
                "generated": true
            }'
        return 0
    fi

    # Fallback: 使用内置基本测试生成器
    local basic_content
    basic_content=$(_generate_basic_test "$issue_type" "$location" "$verification_plan" "$risk_statement" "$repo_root") || true

    if [[ -n "$basic_content" ]]; then
        # 内置生成器总是输出 shell 脚本
        local basic_test_file="${test_dir}/test_targeted_${timestamp_slug}.sh"
        echo "$basic_content" > "$basic_test_file"
        jq -n \
            --arg file "$basic_test_file" \
            --arg framework "bash" \
            --arg language "shell" \
            --arg source "builtin_basic" \
            '{
                "test_file": $file,
                "framework": $framework,
                "language": $language,
                "source": $source,
                "generated": true
            }'
        return 0
    fi

    # 无法生成测试
    jq -n '{
        "generated": false,
        "reason": "no test generation capability available (set BASHCLAW_TEST_GEN_CMD)"
    }'
    return 1
}

# -----------------------------------------------------------------------------
# execute_test — 执行生成的 targeted test
#
# 参数:
#   $1 - test_info JSON（generate_targeted_test 的输出）
#   $2 - repo_root
#   $3 - timeout_seconds（可选，默认60）
# 输出:
#   执行结果 JSON（stdout）
# -----------------------------------------------------------------------------
execute_test() {
    local test_info="$1"
    local repo_root="$2"
    local timeout_seconds="${3:-$DEFAULT_VALIDATION_TIMEOUT}"

    local test_file
    test_file=$(echo "$test_info" | jq -r '.test_file // empty')
    local framework
    framework=$(echo "$test_info" | jq -r '.framework // empty')

    if [[ -z "$test_file" ]] || [[ ! -f "$test_file" ]]; then
        jq -n --arg status "$TV_NOT_EXECUTABLE" '{
            "status": $status,
            "reason": "test file not found or not generated"
        }'
        return 1
    fi

    # 修复 High #4: 使用数组传参避免 shell 注入，不再通过 bash -c 拼接命令
    local -a test_cmd_arr=()
    case "$framework" in
        pytest)
            test_cmd_arr=(pytest "$test_file" -v --tb=short)
            ;;
        npm_test)
            # 对于 JS，直接用 node 运行或通过框架
            test_cmd_arr=(node "$test_file")
            ;;
        bats)
            test_cmd_arr=(bats "$test_file")
            ;;
        go_test)
            test_cmd_arr=(go test -run . "$test_file" -v)
            ;;
        cargo_test)
            test_cmd_arr=(cargo test)
            ;;
        *)
            # 尝试作为 shell 脚本执行
            test_cmd_arr=(bash "$test_file")
            ;;
    esac

    # 执行测试（带超时）— 使用数组直接执行，避免 bash -c 注入风险
    local output
    local exit_code

    if command -v timeout &>/dev/null; then
        output=$(cd "$repo_root" && timeout "${timeout_seconds}s" "${test_cmd_arr[@]}" 2>&1) || exit_code=$?
    else
        output=$(cd "$repo_root" && "${test_cmd_arr[@]}" 2>&1) || exit_code=$?
    fi
    exit_code=${exit_code:-0}

    local status
    local reason=""

    case "$exit_code" in
        0)
            status="$TV_PASS"
            ;;
        1|2)
            status="$TV_FAIL"
            reason="test failed with exit code $exit_code"
            ;;
        124)
            status="$TV_TIMEOUT"
            reason="test timed out after ${timeout_seconds}s"
            ;;
        *)
            status="$TV_ERROR"
            reason="test execution error with exit code $exit_code"
            ;;
    esac

    jq -n \
        --arg status "$status" \
        --arg reason "$reason" \
        --arg output "$output" \
        --arg test_file "$test_file" \
        --argjson exit_code "$exit_code" \
        '{
            "status": $status,
            "exit_code": $exit_code,
            "reason": $reason,
            "output": $output,
            "test_file": $test_file
        }'

    if [[ "$status" == "$TV_PASS" ]]; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# run_targeted_validation — 完整的针对性验证流程
#
# 检测框架 → 生成测试 → 执行测试 → 返回结果
#
# 参数:
#   $1 - issue JSON
#   $2 - repo_root
# 输出:
#   完整验证结果 JSON（stdout）
# -----------------------------------------------------------------------------
run_targeted_validation() {
    local issue="${1:?issue is required}"
    local repo_root="${2:-.}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Step 1: 检测测试框架
    local frameworks
    frameworks=$(detect_test_framework "$repo_root")

    local framework_count
    framework_count=$(echo "$frameworks" | jq 'length')

    local target_framework
    if [[ "$framework_count" -eq 0 ]]; then
        # 没有检测到专用测试框架时，使用 bash 作为 fallback。
        # generate_targeted_test 内部会按优先级尝试：
        #   1. BASHCLAW_TEST_GEN_CMD（外部模型）
        #   2. BASHCLAW_MOCK_TEST_CONTENT（mock）
        #   3. _generate_basic_test（内置生成器）
        target_framework='{"name":"bash","command":"bash","language":"shell"}'
    else
        # 选择最合适的框架（取第一个可用的）
        target_framework=$(echo "$frameworks" | jq '.[0]')
    fi

    # Step 2: 生成 targeted test
    local test_info
    test_info=$(generate_targeted_test "$issue" "$target_framework" "$repo_root") || {
        jq -n \
            --arg method "targeted_test" \
            --arg status "$TV_NOT_EXECUTABLE" \
            --arg ts "$timestamp" \
            '{
                "method": $method,
                "status": $status,
                "timestamp": $ts,
                "reason": "failed to generate targeted test"
            }'
        return 1
    }

    local was_generated
    was_generated=$(echo "$test_info" | jq -r '.generated // false')
    if [[ "$was_generated" != "true" ]]; then
        jq -n \
            --arg method "targeted_test" \
            --arg status "$TV_NOT_EXECUTABLE" \
            --arg ts "$timestamp" \
            '{
                "method": $method,
                "status": $status,
                "timestamp": $ts,
                "reason": "test generation not available"
            }'
        return 1
    fi

    # Step 3: 执行测试
    local exec_result
    exec_result=$(execute_test "$test_info" "$repo_root")

    local test_status
    test_status=$(echo "$exec_result" | jq -r '.status // "ERROR"')

    # Step 4: 构建最终结果
    local result
    result=$(jq -n \
        --arg method "targeted_test" \
        --arg status "$test_status" \
        --arg ts "$timestamp" \
        --argjson test_info "$test_info" \
        --argjson exec_result "$exec_result" \
        '{
            "method": $method,
            "status": $status,
            "timestamp": $ts,
            "test_info": $test_info,
            "execution": $exec_result
        }')

    # 审计日志（trace-level）
    echo "[TARGETED_VALIDATION:${test_status}] $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

    # 清理临时测试文件
    local test_file
    test_file=$(echo "$test_info" | jq -r '.test_file // empty')
    if [[ -n "$test_file" ]] && [[ -f "$test_file" ]]; then
        rm -f "$test_file" 2>/dev/null || true
    fi

    echo "$result"

    if [[ "$test_status" == "$TV_PASS" ]]; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# execute_repro_step — 执行复现步骤验证
#
# 用于 evidence_resolution.sh 的 attempt_repro_step
#
# 参数:
#   $1 - issue JSON
#   $2 - repo_root
# 输出:
#   复现结果 JSON（stdout）
# -----------------------------------------------------------------------------
execute_repro_step() {
    local issue="$1"
    local repo_root="${2:-.}"

    local verification_plan
    verification_plan=$(echo "$issue" | jq -r '.verification_plan // empty')
    local issue_type
    issue_type=$(echo "$issue" | jq -r '.issue_type // empty')

    if [[ -z "$verification_plan" ]]; then
        jq -n --arg method "repro_step" '{
            "method": $method,
            "status": "NOT_EXECUTABLE",
            "reason": "no verification plan available for repro"
        }'
        return 1
    fi

    # 尝试从 verification_plan 中提取可执行命令
    # 如果有模型辅助，可以让模型将 verification_plan 转成可执行脚本
    if [[ -n "${BASHCLAW_REPRO_GEN_CMD:-}" ]]; then
        local repro_script
        # 修复 Critical #3: 移除 eval 防止 shell 注入 RCE
        local -a repro_gen_cmd_arr=()
        read -ra repro_gen_cmd_arr <<< "$BASHCLAW_REPRO_GEN_CMD"
        repro_script=$(echo "Convert this verification plan to a shell script that returns 0 if the issue is reproduced, 1 if not: ${verification_plan}" | "${repro_gen_cmd_arr[@]}" 2>/dev/null) || true

        if [[ -n "$repro_script" ]]; then
            local repro_file="${repo_root}/.bashclaw_targeted_tests/repro_$(date +%s).sh"
            mkdir -p "$(dirname "$repro_file")"
            echo "$repro_script" > "$repro_file"
            chmod +x "$repro_file"

            local output
            local exit_code
            output=$(cd "$repo_root" && timeout 30s bash "$repro_file" 2>&1) || exit_code=$?
            exit_code=${exit_code:-0}

            rm -f "$repro_file" 2>/dev/null || true

            local status
            if [[ "$exit_code" -eq 0 ]]; then
                status="REPRODUCED"
            else
                status="NOT_REPRODUCED"
            fi

            jq -n \
                --arg method "repro_step" \
                --arg status "$status" \
                --arg output "$output" \
                --argjson exit_code "$exit_code" \
                '{
                    "method": $method,
                    "status": $status,
                    "output": $output,
                    "exit_code": $exit_code
                }'
            return 0
        fi
    fi

    jq -n --arg method "repro_step" '{
        "method": $method,
        "status": "NOT_EXECUTABLE",
        "reason": "cannot convert verification plan to executable repro steps"
    }'
    return 1
}
