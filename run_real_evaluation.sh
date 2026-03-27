#!/usr/bin/env bash
###############################################################################
# run_real_evaluation.sh — BashClaw V1 真实评测一键启动脚本
#
# 使用真实 AI 模型和真实数据集运行完整评测流程。
# 前置条件：
#   - ANTHROPIC_API_KEY 已设置
#   - OPENAI_API_KEY 已设置（用于 codex reviewer）
#   - jq 已安装
#   - bash 4+ 已安装
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_DIR="${SCRIPT_DIR}/evaluation"
REAL_CONFIG="${SCRIPT_DIR}/bashclaw.real.json"
TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
REAL_RESULTS_DIR="${EVAL_DIR}/results/real_${TIMESTAMP}"

# 颜色定义（兼容无色终端）
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

###############################################################################
# 0. 前置条件检查
###############################################################################
check_prerequisites() {
  log_info "检查前置条件..."
  local failed=0

  # 检查真实配置文件
  if [[ ! -f "${REAL_CONFIG}" ]]; then
    log_error "真实配置文件不存在: ${REAL_CONFIG}"
    failed=1
  fi

  # 检查 ANTHROPIC_API_KEY
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    log_error "ANTHROPIC_API_KEY 未设置"
    log_error "  设置方法: export ANTHROPIC_API_KEY='sk-ant-...'"
    failed=1
  else
    log_ok "ANTHROPIC_API_KEY 已设置"
  fi

  # 检查 OPENAI_API_KEY（reviewer 需要）
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    log_warn "OPENAI_API_KEY 未设置（codex reviewer 将不可用，回退到 opus4.6）"
  else
    log_ok "OPENAI_API_KEY 已设置"
  fi

  # 检查 jq
  if ! command -v jq &>/dev/null; then
    log_error "jq 未安装"
    log_error "  WSL/Linux: sudo apt install jq"
    log_error "  Git Bash:  下载 https://stedolan.github.io/jq/download/"
    failed=1
  else
    log_ok "jq 已安装: $(jq --version)"
  fi

  # 检查评测脚本存在
  for script in \
    "${EVAL_DIR}/ablation/run_ablation.sh" \
    "${EVAL_DIR}/learning/temporal_replay.sh" \
    "${EVAL_DIR}/hardset/run_hardset.sh" \
    "${EVAL_DIR}/acceptance_check.sh"; do
    if [[ ! -f "${script}" ]]; then
      log_error "评测脚本缺失: ${script}"
      failed=1
    fi
  done

  if [[ ${failed} -ne 0 ]]; then
    log_error "前置条件检查失败，请修复上述问题后重试"
    return 1
  fi

  log_ok "所有前置条件检查通过"
}

###############################################################################
# 1. 消融实验（真实模式）
###############################################################################
run_ablation() {
  log_info "========================================"
  log_info "阶段 1/4: 组件消融实验 (真实模式)"
  log_info "========================================"

  export BASHCLAW_CONFIG="${REAL_CONFIG}"
  export BASHCLAW_EVAL_MODE="real"

  local ablation_dir="${REAL_RESULTS_DIR}/ablation"
  mkdir -p "${ablation_dir}"

  if bash "${EVAL_DIR}/ablation/run_ablation.sh" 2>&1 | tee "${ablation_dir}/ablation.log"; then
    log_ok "消融实验完成"
  else
    log_warn "消融实验中有部分任务失败（继续执行后续阶段）"
  fi

  # 复制结果
  if [[ -d "${EVAL_DIR}/results/ablation" ]]; then
    cp -r "${EVAL_DIR}/results/ablation/"* "${ablation_dir}/" 2>/dev/null || true
  fi
}

###############################################################################
# 2. 闭环学习实验（真实模式）
###############################################################################
run_learning() {
  log_info "========================================"
  log_info "阶段 2/4: 闭环学习实验 (真实模式)"
  log_info "========================================"

  export BASHCLAW_CONFIG="${REAL_CONFIG}"
  export BASHCLAW_EVAL_MODE="real"

  local learning_dir="${REAL_RESULTS_DIR}/learning"
  mkdir -p "${learning_dir}"

  if bash "${EVAL_DIR}/learning/temporal_replay.sh" 2>&1 | tee "${learning_dir}/learning.log"; then
    log_ok "闭环学习实验完成"
  else
    log_warn "闭环学习实验中有部分失败（继续执行后续阶段）"
  fi

  # 复制结果
  if [[ -d "${EVAL_DIR}/results/learning" ]]; then
    cp -r "${EVAL_DIR}/results/learning/"* "${learning_dir}/" 2>/dev/null || true
  fi
}

###############################################################################
# 3. Hard Set 实验（真实模式）
###############################################################################
run_hardset() {
  log_info "========================================"
  log_info "阶段 3/4: Hard Set 实验 (真实模式)"
  log_info "========================================"

  export BASHCLAW_CONFIG="${REAL_CONFIG}"
  export BASHCLAW_EVAL_MODE="real"

  local hardset_dir="${REAL_RESULTS_DIR}/hardset"
  mkdir -p "${hardset_dir}"

  if bash "${EVAL_DIR}/hardset/run_hardset.sh" 2>&1 | tee "${hardset_dir}/hardset.log"; then
    log_ok "Hard Set 实验完成"
  else
    log_warn "Hard Set 实验中有部分失败（继续执行后续阶段）"
  fi

  # 复制结果
  if [[ -d "${EVAL_DIR}/results/hardset" ]]; then
    cp -r "${EVAL_DIR}/results/hardset/"* "${hardset_dir}/" 2>/dev/null || true
  fi
}

###############################################################################
# 4. 生成验收报告
###############################################################################
run_acceptance() {
  log_info "========================================"
  log_info "阶段 4/4: 生成验收报告"
  log_info "========================================"

  local report_file="${REAL_RESULTS_DIR}/acceptance_report.txt"

  if bash "${EVAL_DIR}/acceptance_check.sh" 2>&1 | tee "${report_file}"; then
    log_ok "验收报告已生成: ${report_file}"
  else
    log_warn "验收检查中有部分指标未达标"
  fi
}

###############################################################################
# 5. 对比模拟 vs 真实结果
###############################################################################
compare_results() {
  log_info "========================================"
  log_info "模拟 vs 真实结果对比"
  log_info "========================================"

  local comparison_file="${REAL_RESULTS_DIR}/sim_vs_real_comparison.txt"

  {
    echo "============================================================"
    echo "  BashClaw V1 — 模拟 vs 真实评测对比"
    echo "  生成时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "============================================================"
    echo ""

    # 消融实验对比
    echo "--- 消融实验对比 ---"
    local sim_ablation="${EVAL_DIR}/results/ablation/ablation_summary.json"
    local real_ablation="${REAL_RESULTS_DIR}/ablation/ablation_summary.json"
    if [[ -f "${sim_ablation}" && -f "${real_ablation}" ]]; then
      echo "模拟结果:"
      jq -r '.configs[] | "  \(.config): pass_rate=\(.pass_rate // "N/A")"' "${sim_ablation}" 2>/dev/null || echo "  (解析失败)"
      echo ""
      echo "真实结果:"
      jq -r '.configs[] | "  \(.config): pass_rate=\(.pass_rate // "N/A")"' "${real_ablation}" 2>/dev/null || echo "  (解析失败)"
    else
      echo "  (缺少模拟或真实结果文件，无法对比)"
    fi
    echo ""

    # 闭环学习对比
    echo "--- 闭环学习对比 ---"
    local sim_learning="${EVAL_DIR}/results/learning/learning_metrics.json"
    local real_learning="${REAL_RESULTS_DIR}/learning/learning_metrics.json"
    if [[ -f "${sim_learning}" && -f "${real_learning}" ]]; then
      echo "模拟结果:"
      jq -r 'to_entries[] | "  \(.key)=\(.value)"' "${sim_learning}" 2>/dev/null || echo "  (解析失败)"
      echo ""
      echo "真实结果:"
      jq -r 'to_entries[] | "  \(.key)=\(.value)"' "${real_learning}" 2>/dev/null || echo "  (解析失败)"
    else
      echo "  (缺少模拟或真实结果文件，无法对比)"
    fi
    echo ""

    # Hard Set 对比
    echo "--- Hard Set 对比 ---"
    local sim_hardset="${EVAL_DIR}/results/hardset/hardset_summary.json"
    local real_hardset="${REAL_RESULTS_DIR}/hardset/hardset_summary.json"
    if [[ -f "${sim_hardset}" && -f "${real_hardset}" ]]; then
      echo "模拟结果:"
      jq -r 'to_entries[] | "  \(.key)=\(.value)"' "${sim_hardset}" 2>/dev/null || echo "  (解析失败)"
      echo ""
      echo "真实结果:"
      jq -r 'to_entries[] | "  \(.key)=\(.value)"' "${real_hardset}" 2>/dev/null || echo "  (解析失败)"
    else
      echo "  (缺少模拟或真实结果文件，无法对比)"
    fi
    echo ""

    echo "============================================================"
    echo "  对比完成。详细结果在: ${REAL_RESULTS_DIR}/"
    echo "============================================================"
  } | tee "${comparison_file}"
}

###############################################################################
# Main
###############################################################################
main() {
  echo ""
  echo "============================================================"
  echo "  BashClaw V1 — 真实评测全流程"
  echo "  配置: ${REAL_CONFIG}"
  echo "  结果: ${REAL_RESULTS_DIR}"
  echo "  开始时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "============================================================"
  echo ""

  mkdir -p "${REAL_RESULTS_DIR}"

  check_prerequisites

  local start_time
  start_time="$(date +%s)"

  run_ablation
  run_learning
  run_hardset
  run_acceptance
  compare_results

  local end_time elapsed
  end_time="$(date +%s)"
  elapsed="$((end_time - start_time))"

  echo ""
  log_ok "============================================================"
  log_ok "  真实评测全流程完成"
  log_ok "  用时: ${elapsed} 秒"
  log_ok "  结果目录: ${REAL_RESULTS_DIR}"
  log_ok "============================================================"
}

main "$@"
