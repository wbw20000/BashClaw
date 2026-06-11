#!/usr/bin/env bash
###############################################################################
# check_environment.sh — BashClaw V1 环境检查脚本
#
# 检查运行 BashClaw 所需的所有依赖和配置。
# 兼容 WSL 和 Git Bash 环境。
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色定义（兼容无色终端）
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
fi

PASS_ICON="[OK]"
FAIL_ICON="[FAIL]"
WARN_ICON="[WARN]"
SKIP_ICON="[SKIP]"

total_checks=0
passed_checks=0
warned_checks=0
failed_checks=0
failed_items=()

check_pass() {
  total_checks=$((total_checks + 1))
  passed_checks=$((passed_checks + 1))
  echo -e "  ${GREEN}${PASS_ICON}${NC} $1"
}

check_fail() {
  total_checks=$((total_checks + 1))
  failed_checks=$((failed_checks + 1))
  failed_items+=("$1")
  echo -e "  ${RED}${FAIL_ICON}${NC} $1"
  if [[ -n "${2:-}" ]]; then
    echo -e "        ${CYAN}修复方法:${NC} $2"
  fi
}

check_warn() {
  total_checks=$((total_checks + 1))
  warned_checks=$((warned_checks + 1))
  echo -e "  ${YELLOW}${WARN_ICON}${NC} $1"
  if [[ -n "${2:-}" ]]; then
    echo -e "        ${CYAN}建议:${NC} $2"
  fi
}

###############################################################################
# 检测运行环境
###############################################################################
detect_environment() {
  echo -e "${BLUE}--- 运行环境检测 ---${NC}"

  # 检测 OS / 环境类型
  if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    check_pass "运行环境: WSL (Windows Subsystem for Linux)"
    ENV_TYPE="wsl"
  elif [[ "${OSTYPE:-}" == "msys" || "${OSTYPE:-}" == "mingw"* ]]; then
    check_pass "运行环境: Git Bash (MSYS2/MinGW)"
    ENV_TYPE="gitbash"
  elif [[ "${OSTYPE:-}" == "linux-gnu"* ]]; then
    check_pass "运行环境: Linux"
    ENV_TYPE="linux"
  elif [[ "${OSTYPE:-}" == "darwin"* ]]; then
    check_pass "运行环境: macOS"
    ENV_TYPE="macos"
  else
    check_warn "运行环境: 未知 (OSTYPE=${OSTYPE:-unset})" \
      "推荐使用 WSL 或 Git Bash"
    ENV_TYPE="unknown"
  fi

  echo ""
}

###############################################################################
# 1. Bash 版本
###############################################################################
check_bash() {
  echo -e "${BLUE}--- Bash 版本 ---${NC}"

  local bash_version="${BASH_VERSINFO[0]:-0}"
  local bash_full="${BASH_VERSION:-unknown}"

  if [[ ${bash_version} -ge 4 ]]; then
    check_pass "Bash ${bash_full} (>= 4.0 required)"
  else
    check_fail "Bash ${bash_full} 版本过低 (需要 4.0+)" \
      "WSL: sudo apt install bash | Git Bash: 更新 Git for Windows"
  fi

  echo ""
}

###############################################################################
# 2. jq
###############################################################################
check_jq() {
  echo -e "${BLUE}--- jq (JSON 处理器) ---${NC}"

  if command -v jq &>/dev/null; then
    local jq_ver
    jq_ver="$(jq --version 2>&1 || echo 'unknown')"
    check_pass "jq 已安装: ${jq_ver}"
  else
    if [[ "${ENV_TYPE}" == "wsl" || "${ENV_TYPE}" == "linux" ]]; then
      check_fail "jq 未安装" "sudo apt install jq"
    elif [[ "${ENV_TYPE}" == "gitbash" ]]; then
      check_fail "jq 未安装" \
        "下载: https://github.com/jqlang/jq/releases 并放入 PATH"
    elif [[ "${ENV_TYPE}" == "macos" ]]; then
      check_fail "jq 未安装" "brew install jq"
    else
      check_fail "jq 未安装" "请从 https://github.com/jqlang/jq/releases 下载安装"
    fi
  fi

  echo ""
}

###############################################################################
# 3. gh CLI
###############################################################################
check_gh() {
  echo -e "${BLUE}--- GitHub CLI (gh) ---${NC}"

  if command -v gh &>/dev/null; then
    local gh_ver
    gh_ver="$(gh --version 2>&1 | head -1 || echo 'unknown')"
    check_pass "gh 已安装: ${gh_ver}"

    # 检查认证状态
    if gh auth status &>/dev/null; then
      local account
      account="$(gh auth status 2>&1 | grep 'Logged in' | head -1 || echo '')"
      check_pass "gh 已认证: ${account}"
    else
      check_fail "gh 未认证" "运行: gh auth login"
    fi
  else
    if [[ "${ENV_TYPE}" == "wsl" || "${ENV_TYPE}" == "linux" ]]; then
      check_fail "gh CLI 未安装" \
        "参考: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
    elif [[ "${ENV_TYPE}" == "gitbash" ]]; then
      check_fail "gh CLI 未安装" \
        "下载: https://cli.github.com/ 或 winget install GitHub.cli"
    elif [[ "${ENV_TYPE}" == "macos" ]]; then
      check_fail "gh CLI 未安装" "brew install gh"
    else
      check_fail "gh CLI 未安装" "参考: https://cli.github.com/"
    fi
  fi

  echo ""
}

###############################################################################
# 4. API Keys
###############################################################################
check_api_keys() {
  echo -e "${BLUE}--- API Keys ---${NC}"

  # 最优先：claude CLI（订阅模式，无需 API key）
  if command -v claude &>/dev/null; then
    local claude_ver
    claude_ver=$(claude --version 2>/dev/null | head -1) || claude_ver="unknown"
    check_pass "Claude CLI 可用 (${claude_ver}) — 订阅模式，无需 API key"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    local key_preview="${ANTHROPIC_API_KEY:0:10}..."
    check_pass "ANTHROPIC_API_KEY 已设置 (${key_preview})"
  else
    check_warn "Claude CLI 和 ANTHROPIC_API_KEY 均不可用" \
      "已安装 Claude Code 则无需 API key；否则 export ANTHROPIC_API_KEY='sk-ant-...'"
  fi

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    local key_preview="${OPENAI_API_KEY:0:10}..."
    check_pass "OPENAI_API_KEY 已设置 (${key_preview})"
  else
    check_warn "OPENAI_API_KEY 未设置（codex reviewer 不可用，将回退到 opus4.6）" \
      "export OPENAI_API_KEY='sk-...' (添加到 ~/.bashrc 持久化)"
  fi

  echo ""
}

###############################################################################
# 5. shellcheck
###############################################################################
check_shellcheck() {
  echo -e "${BLUE}--- ShellCheck (Bash 静态分析) ---${NC}"

  if command -v shellcheck &>/dev/null; then
    local sc_ver
    sc_ver="$(shellcheck --version 2>&1 | grep 'version:' | head -1 || echo 'unknown')"
    check_pass "shellcheck 已安装: ${sc_ver}"
  else
    if [[ "${ENV_TYPE}" == "wsl" || "${ENV_TYPE}" == "linux" ]]; then
      check_warn "shellcheck 未安装（可选，用于 Bash 静态分析）" \
        "sudo apt install shellcheck"
    elif [[ "${ENV_TYPE}" == "gitbash" ]]; then
      check_warn "shellcheck 未安装（可选，用于 Bash 静态分析）" \
        "scoop install shellcheck 或从 https://github.com/koalaman/shellcheck/releases 下载"
    elif [[ "${ENV_TYPE}" == "macos" ]]; then
      check_warn "shellcheck 未安装（可选，用于 Bash 静态分析）" \
        "brew install shellcheck"
    else
      check_warn "shellcheck 未安装（可选，用于 Bash 静态分析）" \
        "参考: https://github.com/koalaman/shellcheck#installing"
    fi
  fi

  echo ""
}

###############################################################################
# 6. 项目文件完整性
###############################################################################
check_project_files() {
  echo -e "${BLUE}--- 项目文件完整性 ---${NC}"

  local required_files=(
    "bashclaw.json"
    "bashclaw.sh"
    "lib/engine.sh"
    "lib/risk_classifier.sh"
    "lib/knowledge_gate.sh"
    "lib/executor.sh"
    "lib/validator_repo.sh"
    "lib/audit_log.sh"
    "lib/routing.sh"
    "lib/reviewer.sh"
    "lib/evidence_resolution.sh"
    "lib/human_escalation.sh"
    "lib/memory_writeback.sh"
    "lib/issue_trace.sh"
    "lib/skip_review.sh"
    "lib/targeted_validation.sh"
    "evaluation/eval_common.sh"
    "evaluation/ablation/run_ablation.sh"
    "evaluation/learning/temporal_replay.sh"
    "evaluation/hardset/run_hardset.sh"
    "evaluation/acceptance_check.sh"
    "evaluation/data/task_sequence.json"
    "evaluation/data/hard_set.json"
  )

  local all_present=true
  for f in "${required_files[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
      check_fail "缺少文件: ${f}"
      all_present=false
    fi
  done

  if [[ "${all_present}" == "true" ]]; then
    check_pass "所有必需文件齐全 (${#required_files[@]} 个文件)"
  fi

  echo ""
}

###############################################################################
# 7. WSL 特定检查
###############################################################################
check_wsl_specifics() {
  if [[ "${ENV_TYPE}" != "wsl" ]]; then
    return 0
  fi

  echo -e "${BLUE}--- WSL 特定检查 ---${NC}"

  # 检查 Windows 路径互操作
  if command -v wslpath &>/dev/null; then
    check_pass "wslpath 可用（Windows/Linux 路径互转）"
  else
    check_warn "wslpath 不可用" \
      "确保使用最新版 WSL"
  fi

  # 检查文件系统性能提示
  local cwd
  cwd="$(pwd)"
  if [[ "${cwd}" == /mnt/* ]]; then
    check_warn "当前在 Windows 文件系统 (${cwd})" \
      "WSL 下建议在 Linux 文件系统 (~/) 工作以获得更好性能"
  else
    check_pass "在 Linux 文件系统工作 (性能最优)"
  fi

  echo ""
}

###############################################################################
# 总结报告
###############################################################################
print_summary() {
  echo ""
  echo "============================================================"
  echo -e "  ${BLUE}BashClaw V1 — 环境检查报告${NC}"
  echo "  时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "============================================================"
  echo ""
  echo -e "  总检查项:  ${total_checks}"
  echo -e "  ${GREEN}通过:${NC}      ${passed_checks}"
  echo -e "  ${YELLOW}警告:${NC}      ${warned_checks}"
  echo -e "  ${RED}失败:${NC}      ${failed_checks}"
  echo ""

  if [[ ${failed_checks} -eq 0 && ${warned_checks} -eq 0 ]]; then
    echo -e "  ${GREEN}环境状态: 完全就绪${NC}"
    echo "  可以运行: bash run_real_evaluation.sh"
  elif [[ ${failed_checks} -eq 0 ]]; then
    echo -e "  ${YELLOW}环境状态: 基本就绪（有警告项）${NC}"
    echo "  可以运行: bash run_real_evaluation.sh (部分功能可能受限)"
  else
    echo -e "  ${RED}环境状态: 未就绪${NC}"
    echo ""
    echo "  需要修复以下问题:"
    for item in "${failed_items[@]}"; do
      echo -e "    ${RED}-${NC} ${item}"
    done
    echo ""
    echo "  修复后重新运行: bash check_environment.sh"
  fi

  echo ""
  echo "============================================================"

  # 返回码：有失败返回 1
  [[ ${failed_checks} -eq 0 ]]
}

###############################################################################
# Main
###############################################################################
main() {
  echo ""
  echo "============================================================"
  echo "  BashClaw V1 — 环境检查"
  echo "============================================================"
  echo ""

  detect_environment
  check_bash
  check_jq
  check_gh
  check_api_keys
  check_shellcheck
  check_project_files
  check_wsl_specifics
  print_summary
}

main "$@"
