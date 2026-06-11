#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# budget.sh — BashClaw V1 预算机制
#
# 文档参考：统一实施与验证文档 第15节
#
# 功能：
#   - 加载预算配置
#   - 跟踪每日 Tier2/Tier3/HumanEscalation 使用量
#   - 跟踪单任务 UNVERIFIABLE issue 计数
#   - 超预算检查与强制升级
#   - 超预算事件写入日志和 issue trace
###############################################################################

# 防止重复 source
[[ -n "${_BUDGET_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_BUDGET_SH_LOADED=1

# 项目根目录（调用方可覆盖）
BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASHCLAW_CONFIG="${BASHCLAW_ROOT}/bashclaw.json"
BUDGET_STATE_DIR="${BASHCLAW_ROOT}/.bashclaw/budget"
AUDIT_LOG_DIR="${BASHCLAW_ROOT}/.bashclaw/audit"

# ── stub imports（其他 dev 的模块，不存在时提供空函数） ──────────────
if [[ -f "${BASHCLAW_ROOT}/lib/audit_log.sh" ]]; then
  # shellcheck source=/dev/null
  source "${BASHCLAW_ROOT}/lib/audit_log.sh"
fi


###############################################################################
# _with_lock — 通用文件锁包装函数，防止并发 read-modify-write 竞态
# 参数：$1 = lock_file 路径前缀, 后续参数为要执行的命令
# 用法：_with_lock "/path/to/resource" some_command arg1 arg2
###############################################################################
_with_lock() {
  local lock_file="$1"; shift
  # flock 不可用时直接执行（优雅降级）
  if ! command -v flock &>/dev/null; then
    "$@"
    return $?
  fi
  (
    flock -w 5 200 || { echo "LOCK_TIMEOUT" >&2; return 1; }
    "$@"
  ) 200>"${lock_file}.lock"
}

###############################################################################
# budget_init — 初始化预算状态目录
###############################################################################
budget_init() {
  mkdir -p "${BUDGET_STATE_DIR}"
  mkdir -p "${AUDIT_LOG_DIR}"
}

###############################################################################
# _budget_today — 返回今天日期字符串 YYYY-MM-DD
###############################################################################
_budget_today() {
  date +%Y-%m-%d
}

###############################################################################
# _budget_state_file — 返回当日预算状态文件路径
###############################################################################
_budget_state_file() {
  local today
  today="$(_budget_today)"
  echo "${BUDGET_STATE_DIR}/budget_${today}.json"
}

###############################################################################
# _budget_ensure_state — 确保当日状态文件存在，不存在则初始化
###############################################################################
_budget_ensure_state() {
  local state_file
  state_file="$(_budget_state_file)"
  if [[ ! -f "${state_file}" ]]; then
    cat > "${state_file}" <<'INIT'
{
  "tier2_runs": 0,
  "tier3_runs": 0,
  "human_escalations": 0
}
INIT
  fi
}

###############################################################################
# _budget_read_field — 从当日状态文件读取指定字段值
# 参数：$1 = field name (tier2_runs / tier3_runs / human_escalations)
###############################################################################
_budget_read_field() {
  local field="$1"
  local state_file
  state_file="$(_budget_state_file)"
  _budget_ensure_state
  # 简单 grep + sed 解析，避免对 jq 的硬依赖
  if command -v jq &>/dev/null; then
    jq -r ".${field} // 0" "${state_file}"
  else
    grep "\"${field}\"" "${state_file}" | sed 's/[^0-9]//g'
  fi
}

###############################################################################
# _budget_increment_inner — 递增当日状态的某字段（内部实现，需在锁内调用）
# 参数：$1 = field name
###############################################################################
_budget_increment_inner() {
  local field="$1"
  local state_file current new_val
  state_file="$(_budget_state_file)"
  _budget_ensure_state
  current="$(_budget_read_field "${field}")"
  new_val=$(( current + 1 ))
  if command -v jq &>/dev/null; then
    local tmp
    tmp=$(jq ".${field} = ${new_val}" "${state_file}")
    echo "${tmp}" > "${state_file}"
  else
    sed -i "s/\"${field}\": *[0-9]*/\"${field}\": ${new_val}/" "${state_file}"
  fi
}

###############################################################################
# _budget_increment — 递增当日状态的某字段（带文件锁保护）
# 参数：$1 = field name
###############################################################################
_budget_increment() {
  local field="$1"
  local state_file
  state_file="$(_budget_state_file)"
  # 使用文件锁保护 read-modify-write 操作，防止并发竞态
  _with_lock "${state_file}" _budget_increment_inner "${field}"
}

###############################################################################
# _budget_read_config — 从 bashclaw.json 读取预算配置值
# 参数：$1 = config key (e.g. maxTier2RunsPerDay)
###############################################################################
_budget_read_config() {
  local key="$1"
  if command -v jq &>/dev/null; then
    jq -r ".budget.${key} // empty" "${BASHCLAW_CONFIG}"
  else
    grep "\"${key}\"" "${BASHCLAW_CONFIG}" | sed 's/[^0-9]//g' | head -1
  fi
}

###############################################################################
# budget_check_tier2 — 检查 Tier2 是否超预算
# 返回：0=未超, 1=已超
# 输出：超预算时输出警告信息到 stderr
###############################################################################
budget_check_tier2() {
  local current max_val
  current="$(_budget_read_field "tier2_runs")"
  max_val="$(_budget_read_config "maxTier2RunsPerDay")"
  max_val="${max_val:-20}"

  if (( current >= max_val )); then
    echo "[BUDGET] Tier2 超预算: ${current}/${max_val}，需要显式升级才能继续" >&2
    _budget_log_overflow "tier2" "${current}" "${max_val}"
    return 1
  fi
  return 0
}

###############################################################################
# budget_check_tier3 — 检查 Tier3 是否超预算
# 返回：0=未超, 1=已超
###############################################################################
budget_check_tier3() {
  local current max_val
  current="$(_budget_read_field "tier3_runs")"
  max_val="$(_budget_read_config "maxTier3RunsPerDay")"
  max_val="${max_val:-3}"

  if (( current >= max_val )); then
    echo "[BUDGET] Tier3 超预算: ${current}/${max_val}，需要显式升级才能继续" >&2
    _budget_log_overflow "tier3" "${current}" "${max_val}"
    return 1
  fi
  return 0
}

###############################################################################
# budget_check_human_escalation — 检查 Human Escalation 是否超预算
# 返回：0=未超, 1=已超
###############################################################################
budget_check_human_escalation() {
  local current max_val
  current="$(_budget_read_field "human_escalations")"
  max_val="$(_budget_read_config "maxHumanEscalationsPerDay")"
  max_val="${max_val:-5}"

  if (( current >= max_val )); then
    echo "[BUDGET] Human Escalation 超预算: ${current}/${max_val}" >&2
    _budget_log_overflow "human_escalation" "${current}" "${max_val}"
    return 1
  fi
  return 0
}

###############################################################################
# budget_check_unverifiable — 检查单任务 UNVERIFIABLE issue 是否超阈值
# 参数：$1 = 当前 unverifiable 计数
# 返回：0=未超, 1=已超（强制人工）
###############################################################################
budget_check_unverifiable() {
  local count="${1:-0}"
  local max_val
  max_val="$(_budget_read_config "maxUnverifiableIssuesPerTask")"
  max_val="${max_val:-3}"

  if (( count >= max_val )); then
    echo "[BUDGET] 单任务 UNVERIFIABLE 超阈值: ${count}/${max_val}，强制人工裁决" >&2
    _budget_log_overflow "unverifiable_per_task" "${count}" "${max_val}"
    return 1
  fi
  return 0
}

###############################################################################
# budget_record_tier2 — 记录一次 Tier2 使用
###############################################################################
budget_record_tier2() {
  _budget_increment "tier2_runs"
  audit_log_event "BUDGET" "tier2_run_recorded" \
    "count=$(_budget_read_field "tier2_runs")"
}

###############################################################################
# budget_record_tier3 — 记录一次 Tier3 使用
###############################################################################
budget_record_tier3() {
  _budget_increment "tier3_runs"
  audit_log_event "BUDGET" "tier3_run_recorded" \
    "count=$(_budget_read_field "tier3_runs")"
}

###############################################################################
# budget_record_human_escalation — 记录一次 Human Escalation
###############################################################################
budget_record_human_escalation() {
  _budget_increment "human_escalations"
  audit_log_event "BUDGET" "human_escalation_recorded" \
    "count=$(_budget_read_field "human_escalations")"
}

###############################################################################
# _budget_log_overflow — 超预算事件写入审计日志
# 参数：$1=类型, $2=当前值, $3=上限值
###############################################################################
_budget_log_overflow() {
  local overflow_type="$1"
  local current="$2"
  local max_val="$3"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 写入审计日志文件
  local log_file="${AUDIT_LOG_DIR}/budget_overflow.log"
  echo "${timestamp} | BUDGET_OVERFLOW | type=${overflow_type} current=${current} max=${max_val}" \
    >> "${log_file}"

  # 调用 audit_log 模块（如果可用）
  audit_log_event "BUDGET_OVERFLOW" "${overflow_type}" \
    "current=${current} max=${max_val}"
}

###############################################################################
# budget_get_status — 获取当前预算使用状态的 JSON 字符串
###############################################################################
budget_get_status() {
  local t2 t3 he t2_max t3_max he_max
  _budget_ensure_state
  t2="$(_budget_read_field "tier2_runs")"
  t3="$(_budget_read_field "tier3_runs")"
  he="$(_budget_read_field "human_escalations")"
  t2_max="$(_budget_read_config "maxTier2RunsPerDay")"
  t3_max="$(_budget_read_config "maxTier3RunsPerDay")"
  he_max="$(_budget_read_config "maxHumanEscalationsPerDay")"
  t2_max="${t2_max:-20}"
  t3_max="${t3_max:-3}"
  he_max="${he_max:-5}"

  cat <<EOF
{
  "date": "$(_budget_today)",
  "tier2": { "used": ${t2}, "max": ${t2_max} },
  "tier3": { "used": ${t3}, "max": ${t3_max} },
  "human_escalations": { "used": ${he}, "max": ${he_max} }
}
EOF
}

###############################################################################
# budget_warn_if_enabled — 如果 warnOnTierOverflow=true 且接近上限，输出警告
# 参数：$1 = tier (tier2/tier3/human_escalation)
###############################################################################
budget_warn_if_enabled() {
  local tier="$1"
  local warn_enabled
  warn_enabled="$(_budget_read_config "warnOnTierOverflow")"
  if [[ "${warn_enabled}" != "true" ]]; then
    return 0
  fi

  local current max_val threshold
  case "${tier}" in
    tier2)
      current="$(_budget_read_field "tier2_runs")"
      max_val="$(_budget_read_config "maxTier2RunsPerDay")"
      max_val="${max_val:-20}"
      ;;
    tier3)
      current="$(_budget_read_field "tier3_runs")"
      max_val="$(_budget_read_config "maxTier3RunsPerDay")"
      max_val="${max_val:-3}"
      ;;
    human_escalation)
      current="$(_budget_read_field "human_escalations")"
      max_val="$(_budget_read_config "maxHumanEscalationsPerDay")"
      max_val="${max_val:-5}"
      ;;
    *)
      return 0
      ;;
  esac

  # 达到 80% 时开始警告
  threshold=$(( max_val * 80 / 100 ))
  if (( current >= threshold && current < max_val )); then
    echo "[BUDGET_WARN] ${tier} 接近上限: ${current}/${max_val}" >&2
  fi
}
