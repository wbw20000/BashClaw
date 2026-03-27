#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# api_client.sh — BashClaw V1 通用 AI 模型 API 客户端
#
# 封装 Anthropic / OpenAI API 的 curl 调用，提供：
#   - api_call_anthropic()  — 调用 Anthropic Messages API
#   - api_call_openai()     — 调用 OpenAI Chat Completions API
#   - api_call_auto()       — 根据可用 key 自动选择 API
#   - 重试逻辑（3次，指数退避）
#   - Token 计数（从响应中提取 usage）
#   - 超时处理（120秒）
#   - 审计日志记录每次 API 调用的 token 消耗
# =============================================================================

API_CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认配置
API_TIMEOUT="${API_TIMEOUT:-120}"          # curl 超时秒数
API_MAX_RETRIES="${API_MAX_RETRIES:-3}"    # 最大重试次数
API_RETRY_BASE="${API_RETRY_BASE:-2}"      # 指数退避基数（秒）
API_LOG_DIR="${API_LOG_DIR:-.bashclaw/api_logs}"

# 上次 API 调用的 token 使用量（调用后可读取）
API_LAST_INPUT_TOKENS=0
API_LAST_OUTPUT_TOKENS=0
API_LAST_TOTAL_TOKENS=0
API_LAST_MODEL=""
API_LAST_PROVIDER=""

# -----------------------------------------------------------------------------
# _api_ensure_log_dir — 确保 API 日志目录存在
# -----------------------------------------------------------------------------
_api_ensure_log_dir() {
  mkdir -p "${API_LOG_DIR}" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# _api_log_usage — 记录 API 调用的 token 消耗到审计日志
#
# 参数:
#   $1 - provider (anthropic|openai)
#   $2 - model
#   $3 - input_tokens
#   $4 - output_tokens
#   $5 - total_tokens
#   $6 - status (success|error)
#   $7 - error_message (可选)
# -----------------------------------------------------------------------------
_api_log_usage() {
  local provider="$1"
  local model="$2"
  local input_tokens="$3"
  local output_tokens="$4"
  local total_tokens="$5"
  local status="$6"
  local error_message="${7:-}"

  _api_ensure_log_dir

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local log_file="${API_LOG_DIR}/api_usage_$(date +%Y%m%d).jsonl"

  # 追加 JSONL 格式日志
  cat >> "${log_file}" <<EOF
{"timestamp":"${timestamp}","provider":"${provider}","model":"${model}","input_tokens":${input_tokens},"output_tokens":${output_tokens},"total_tokens":${total_tokens},"status":"${status}","error":"${error_message}"}
EOF

  # 同时输出到 stderr 便于调试
  echo "[API_USAGE] ${timestamp} provider=${provider} model=${model} tokens=${total_tokens} (in=${input_tokens},out=${output_tokens}) status=${status}" >&2
}

# -----------------------------------------------------------------------------
# _api_retry_with_backoff — 带指数退避的重试包装器
#
# 参数:
#   $1 - 最大重试次数
#   $@ - 要执行的命令
# 返回:
#   命令的返回码
# 输出:
#   命令的标准输出
# -----------------------------------------------------------------------------
_api_retry_with_backoff() {
  local max_retries="$1"
  shift
  local attempt=0
  local result=""
  local exit_code=1

  while (( attempt < max_retries )); do
    attempt=$(( attempt + 1 ))

    # 执行命令，捕获输出和退出码
    result=$("$@" 2>/dev/null) && exit_code=0 || exit_code=$?

    if [[ ${exit_code} -eq 0 && -n "${result}" ]]; then
      echo "${result}"
      return 0
    fi

    if (( attempt < max_retries )); then
      local wait_seconds=$(( API_RETRY_BASE ** (attempt - 1) ))
      echo "[API_RETRY] 第 ${attempt}/${max_retries} 次失败，${wait_seconds} 秒后重试..." >&2
      sleep "${wait_seconds}"
    fi
  done

  # 所有重试都失败
  echo "${result}"
  return ${exit_code}
}

# -----------------------------------------------------------------------------
# api_call_anthropic — 调用 Anthropic Messages API
#
# 参数:
#   $1 - model (例: claude-opus-4-6-20250219)
#   $2 - system_prompt
#   $3 - user_message
#   $4 - max_tokens (默认: 4096)
# 输出:
#   模型响应的文本内容（stdout）
# 返回:
#   0 成功, 1 失败
# -----------------------------------------------------------------------------
api_call_anthropic() {
  local model="${1:-claude-opus-4-6-20250219}"
  local system_prompt="${2:-}"
  local user_message="${3:-}"
  local max_tokens="${4:-4096}"

  # 检查 API key
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "API_ERROR: ANTHROPIC_API_KEY 未设置" >&2
    return 1
  fi

  if [[ -z "${user_message}" ]]; then
    echo "API_ERROR: user_message 不能为空" >&2
    return 1
  fi

  # 构造请求 JSON — 使用 jq 安全转义
  local request_body
  if [[ -n "${system_prompt}" ]]; then
    request_body=$(jq -n \
      --arg model "${model}" \
      --arg system "${system_prompt}" \
      --arg user "${user_message}" \
      --argjson max_tokens "${max_tokens}" \
      '{
        "model": $model,
        "max_tokens": $max_tokens,
        "system": $system,
        "messages": [
          {"role": "user", "content": $user}
        ]
      }')
  else
    request_body=$(jq -n \
      --arg model "${model}" \
      --arg user "${user_message}" \
      --argjson max_tokens "${max_tokens}" \
      '{
        "model": $model,
        "max_tokens": $max_tokens,
        "messages": [
          {"role": "user", "content": $user}
        ]
      }')
  fi

  # 调用 API（带重试）
  local raw_response
  raw_response=$(_api_retry_with_backoff "${API_MAX_RETRIES}" \
    curl -s -w '\n__HTTP_CODE__%{http_code}' \
      --max-time "${API_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -d "${request_body}" \
      "https://api.anthropic.com/v1/messages") || {
    _api_log_usage "anthropic" "${model}" 0 0 0 "error" "curl_failed"
    echo "API_ERROR: Anthropic API 调用失败（所有重试均失败）" >&2
    return 1
  }

  # 分离 HTTP 状态码和响应体
  local http_code
  http_code=$(echo "${raw_response}" | grep -oP '__HTTP_CODE__\K[0-9]+$' || echo "000")
  local response_body
  response_body=$(echo "${raw_response}" | sed 's/__HTTP_CODE__[0-9]*$//')

  # 检查 HTTP 状态码
  if [[ "${http_code}" != "200" ]]; then
    local error_msg
    error_msg=$(echo "${response_body}" | jq -r '.error.message // "unknown error"' 2>/dev/null || echo "HTTP ${http_code}")
    _api_log_usage "anthropic" "${model}" 0 0 0 "error" "http_${http_code}: ${error_msg}"
    echo "API_ERROR: Anthropic API 返回 HTTP ${http_code}: ${error_msg}" >&2
    return 1
  fi

  # 提取 token 使用量
  API_LAST_INPUT_TOKENS=$(echo "${response_body}" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)
  API_LAST_OUTPUT_TOKENS=$(echo "${response_body}" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)
  API_LAST_TOTAL_TOKENS=$(( API_LAST_INPUT_TOKENS + API_LAST_OUTPUT_TOKENS ))
  API_LAST_MODEL="${model}"
  API_LAST_PROVIDER="anthropic"

  # 记录 token 使用
  _api_log_usage "anthropic" "${model}" \
    "${API_LAST_INPUT_TOKENS}" "${API_LAST_OUTPUT_TOKENS}" \
    "${API_LAST_TOTAL_TOKENS}" "success"

  # 提取文本内容
  local content
  content=$(echo "${response_body}" | jq -r '.content[0].text // empty' 2>/dev/null)

  if [[ -z "${content}" ]]; then
    echo "API_ERROR: Anthropic 响应中未找到文本内容" >&2
    return 1
  fi

  echo "${content}"
  return 0
}

# -----------------------------------------------------------------------------
# api_call_openai — 调用 OpenAI Chat Completions API
#
# 参数:
#   $1 - model (例: gpt-4, o3-mini)
#   $2 - system_prompt
#   $3 - user_message
#   $4 - max_tokens (默认: 4096)
# 输出:
#   模型响应的文本内容（stdout）
# 返回:
#   0 成功, 1 失败
# -----------------------------------------------------------------------------
api_call_openai() {
  local model="${1:-gpt-4}"
  local system_prompt="${2:-}"
  local user_message="${3:-}"
  local max_tokens="${4:-4096}"

  # 检查 API key
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "API_ERROR: OPENAI_API_KEY 未设置" >&2
    return 1
  fi

  if [[ -z "${user_message}" ]]; then
    echo "API_ERROR: user_message 不能为空" >&2
    return 1
  fi

  # 构造 messages 数组
  local messages
  if [[ -n "${system_prompt}" ]]; then
    messages=$(jq -n \
      --arg system "${system_prompt}" \
      --arg user "${user_message}" \
      '[
        {"role": "system", "content": $system},
        {"role": "user", "content": $user}
      ]')
  else
    messages=$(jq -n \
      --arg user "${user_message}" \
      '[
        {"role": "user", "content": $user}
      ]')
  fi

  # 构造请求 JSON
  local request_body
  request_body=$(jq -n \
    --arg model "${model}" \
    --argjson messages "${messages}" \
    --argjson max_tokens "${max_tokens}" \
    '{
      "model": $model,
      "messages": $messages,
      "max_tokens": $max_tokens
    }')

  # 调用 API（带重试）
  local raw_response
  raw_response=$(_api_retry_with_backoff "${API_MAX_RETRIES}" \
    curl -s -w '\n__HTTP_CODE__%{http_code}' \
      --max-time "${API_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -d "${request_body}" \
      "https://api.openai.com/v1/chat/completions") || {
    _api_log_usage "openai" "${model}" 0 0 0 "error" "curl_failed"
    echo "API_ERROR: OpenAI API 调用失败（所有重试均失败）" >&2
    return 1
  }

  # 分离 HTTP 状态码和响应体
  local http_code
  http_code=$(echo "${raw_response}" | grep -oP '__HTTP_CODE__\K[0-9]+$' || echo "000")
  local response_body
  response_body=$(echo "${raw_response}" | sed 's/__HTTP_CODE__[0-9]*$//')

  # 检查 HTTP 状态码
  if [[ "${http_code}" != "200" ]]; then
    local error_msg
    error_msg=$(echo "${response_body}" | jq -r '.error.message // "unknown error"' 2>/dev/null || echo "HTTP ${http_code}")
    _api_log_usage "openai" "${model}" 0 0 0 "error" "http_${http_code}: ${error_msg}"
    echo "API_ERROR: OpenAI API 返回 HTTP ${http_code}: ${error_msg}" >&2
    return 1
  fi

  # 提取 token 使用量
  API_LAST_INPUT_TOKENS=$(echo "${response_body}" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null || echo 0)
  API_LAST_OUTPUT_TOKENS=$(echo "${response_body}" | jq -r '.usage.completion_tokens // 0' 2>/dev/null || echo 0)
  API_LAST_TOTAL_TOKENS=$(echo "${response_body}" | jq -r '.usage.total_tokens // 0' 2>/dev/null || echo 0)
  API_LAST_MODEL="${model}"
  API_LAST_PROVIDER="openai"

  # 记录 token 使用
  _api_log_usage "openai" "${model}" \
    "${API_LAST_INPUT_TOKENS}" "${API_LAST_OUTPUT_TOKENS}" \
    "${API_LAST_TOTAL_TOKENS}" "success"

  # 提取文本内容
  local content
  content=$(echo "${response_body}" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

  if [[ -z "${content}" ]]; then
    echo "API_ERROR: OpenAI 响应中未找到文本内容" >&2
    return 1
  fi

  echo "${content}"
  return 0
}

# -----------------------------------------------------------------------------
# api_call_auto — 自动选择可用的 API 进行调用
#
# 根据 preferred_engine 和可用的 API key 自动选择：
#   - opus4.6 / anthropic → 优先使用 Anthropic API
#   - codex / openai      → 优先使用 OpenAI API
#   - 若首选不可用，自动回退到另一个可用的 API
#
# 参数:
#   $1 - preferred_engine (opus4.6|codex|anthropic|openai)
#   $2 - system_prompt
#   $3 - user_message
#   $4 - max_tokens (默认: 4096)
# 输出:
#   模型响应的文本内容（stdout）
# 返回:
#   0 成功, 1 无可用 API 或调用失败
# -----------------------------------------------------------------------------
api_call_auto() {
  local preferred="${1:-opus4.6}"
  local system_prompt="${2:-}"
  local user_message="${3:-}"
  local max_tokens="${4:-4096}"

  # 确定首选和备选 provider
  local primary_provider="anthropic"
  local primary_model="claude-opus-4-6-20250219"
  local fallback_provider="openai"
  local fallback_model="gpt-4"

  case "${preferred}" in
    codex|openai)
      primary_provider="openai"
      primary_model="gpt-4"
      fallback_provider="anthropic"
      fallback_model="claude-opus-4-6-20250219"
      ;;
    opus4.6|opus|anthropic|*)
      primary_provider="anthropic"
      primary_model="claude-opus-4-6-20250219"
      fallback_provider="openai"
      fallback_model="gpt-4"
      ;;
  esac

  # 最高优先级：CLI 订阅模式（无需 API key）
  # 根据 preferred engine 选择对应的 CLI：
  #   - codex/openai → 优先用 codex CLI
  #   - opus/anthropic → 优先用 claude CLI
  case "${preferred}" in
    codex|openai)
      # Reviewer 角色：优先 Codex CLI，回退到 Claude CLI
      if api_has_codex_cli; then
        local codex_result
        codex_result=$(api_call_codex_review "${user_message}" 2>/dev/null) && {
          echo "${codex_result}"
          return 0
        }
        echo "API_WARN: codex review 调用失败，尝试 claude -p 回退" >&2
      fi
      if api_has_claude_cli; then
        local cli_result
        cli_result=$(api_call_claude_cli "${system_prompt}" "${user_message}" "${max_tokens}") && {
          echo "${cli_result}"
          return 0
        }
      fi
      ;;
    *)
      # Executor 角色：优先 Claude CLI，回退到 Codex CLI
      if api_has_claude_cli; then
        local cli_result
        cli_result=$(api_call_claude_cli "${system_prompt}" "${user_message}" "${max_tokens}") && {
          echo "${cli_result}"
          return 0
        }
        echo "API_WARN: claude -p 调用失败，尝试 codex exec 回退" >&2
      fi
      if api_has_codex_cli; then
        local codex_result
        codex_result=$(api_call_codex_exec "${user_message}" 2>/dev/null) && {
          echo "${codex_result}"
          return 0
        }
      fi
      ;;
  esac

  # 尝试首选 REST API provider
  local has_primary_key="false"
  local has_fallback_key="false"

  if [[ "${primary_provider}" == "anthropic" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
    has_primary_key="true"
  elif [[ "${primary_provider}" == "openai" && -n "${OPENAI_API_KEY:-}" ]]; then
    has_primary_key="true"
  fi

  if [[ "${fallback_provider}" == "anthropic" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
    has_fallback_key="true"
  elif [[ "${fallback_provider}" == "openai" && -n "${OPENAI_API_KEY:-}" ]]; then
    has_fallback_key="true"
  fi

  # 无任何可用 key 且 claude CLI 也不可用
  if [[ "${has_primary_key}" == "false" && "${has_fallback_key}" == "false" ]]; then
    echo "API_ERROR: 无可用的调用方式（claude CLI 不可用，ANTHROPIC_API_KEY 和 OPENAI_API_KEY 均未设置）" >&2
    return 1
  fi

  # 尝试首选
  if [[ "${has_primary_key}" == "true" ]]; then
    local result
    if [[ "${primary_provider}" == "anthropic" ]]; then
      result=$(api_call_anthropic "${primary_model}" "${system_prompt}" "${user_message}" "${max_tokens}" 2>/dev/null) && {
        echo "${result}"
        return 0
      }
    else
      result=$(api_call_openai "${primary_model}" "${system_prompt}" "${user_message}" "${max_tokens}" 2>/dev/null) && {
        echo "${result}"
        return 0
      }
    fi
    echo "[API_AUTO] 首选 ${primary_provider} 调用失败，尝试回退到 ${fallback_provider}" >&2
  fi

  # 尝试备选
  if [[ "${has_fallback_key}" == "true" ]]; then
    local result
    if [[ "${fallback_provider}" == "anthropic" ]]; then
      result=$(api_call_anthropic "${fallback_model}" "${system_prompt}" "${user_message}" "${max_tokens}") && {
        echo "${result}"
        return 0
      }
    else
      result=$(api_call_openai "${fallback_model}" "${system_prompt}" "${user_message}" "${max_tokens}") && {
        echo "${result}"
        return 0
      }
    fi
  fi

  echo "API_ERROR: 所有 API 调用均失败" >&2
  return 1
}

# -----------------------------------------------------------------------------
# api_has_claude_cli — 检查 claude CLI（订阅模式）是否可用
#
# 返回:
#   0 可用, 1 不可用
# -----------------------------------------------------------------------------
api_has_claude_cli() {
  command -v claude &>/dev/null
}

# -----------------------------------------------------------------------------
# api_call_claude_cli — 通过 claude -p 管道模式调用（使用订阅配额）
#
# 这是最优先的调用方式，不需要 API key，使用用户的 Claude 订阅。
#
# 参数:
#   $1 - system_prompt
#   $2 - user_message
#   $3 - max_tokens (未使用，claude -p 自动控制)
# 输出:
#   模型响应文本 (stdout)
# 返回:
#   0 成功, 1 失败
# -----------------------------------------------------------------------------
api_call_claude_cli() {
  local system_prompt="${1:-}"
  local user_message="${2:-}"
  local _max_tokens="${3:-4096}"

  if ! api_has_claude_cli; then
    return 1
  fi

  _api_ensure_log_dir

  # 组合 system prompt 和 user message
  local full_prompt
  if [[ -n "${system_prompt}" ]]; then
    full_prompt="<system>${system_prompt}</system>

${user_message}"
  else
    full_prompt="${user_message}"
  fi

  local response
  local start_time
  start_time=$(date +%s)

  # 使用 claude -p（管道模式）调用，--output-format text 获取纯文本
  response=$(echo "${full_prompt}" | claude -p --output-format text 2>/dev/null) || {
    _api_log_usage "claude_cli" "claude-subscription" 0 0 0 "error" "claude -p failed"
    return 1
  }

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # claude -p 不直接返回 token 计数，估算（约4字符=1token）
  local input_est=$(( ${#full_prompt} / 4 ))
  local output_est=$(( ${#response} / 4 ))
  local total_est=$(( input_est + output_est ))

  # 更新全局 token 跟踪
  API_LAST_INPUT_TOKENS=${input_est}
  API_LAST_OUTPUT_TOKENS=${output_est}
  API_LAST_TOTAL_TOKENS=${total_est}
  API_LAST_MODEL="claude-subscription"
  API_LAST_PROVIDER="claude_cli"

  _api_log_usage "claude_cli" "claude-subscription" \
    "${input_est}" "${output_est}" "${total_est}" "success"

  echo "${response}"
  return 0
}

# -----------------------------------------------------------------------------
# api_has_codex_cli — 检查 Codex CLI（订阅模式）是否可用
# -----------------------------------------------------------------------------
api_has_codex_cli() {
  command -v codex &>/dev/null
}

# -----------------------------------------------------------------------------
# api_call_codex_exec — 通过 codex exec 执行任务（Executor 角色）
#
# 参数:
#   $1 - prompt（任务描述）
# 输出:
#   Codex 执行结果 (stdout)
# -----------------------------------------------------------------------------
api_call_codex_exec() {
  local prompt="${1:-}"

  if ! api_has_codex_cli; then
    return 1
  fi

  _api_ensure_log_dir

  local start_time
  start_time=$(date +%s)

  local response
  response=$(codex exec "${prompt}" 2>/dev/null) || {
    _api_log_usage "codex_cli" "codex-subscription" 0 0 0 "error" "codex exec failed"
    return 1
  }

  local end_time
  end_time=$(date +%s)

  local input_est=$(( ${#prompt} / 4 ))
  local output_est=$(( ${#response} / 4 ))
  local total_est=$(( input_est + output_est ))

  API_LAST_INPUT_TOKENS=${input_est}
  API_LAST_OUTPUT_TOKENS=${output_est}
  API_LAST_TOTAL_TOKENS=${total_est}
  API_LAST_MODEL="codex-subscription"
  API_LAST_PROVIDER="codex_cli"

  _api_log_usage "codex_cli" "codex-subscription" \
    "${input_est}" "${output_est}" "${total_est}" "success"

  echo "${response}"
  return 0
}

# -----------------------------------------------------------------------------
# api_call_codex_review — 通过 codex review 做代码审查（Reviewer 角色）
#
# Codex CLI 内置 review 命令，天然适合做独立 Reviewer
#
# 参数:
#   $1 - review_instructions（审查要求/上下文）
#   $2 - review_scope（可选: --uncommitted 审查未提交变更）
# 输出:
#   Codex review 结果 (stdout)
# -----------------------------------------------------------------------------
api_call_codex_review() {
  local instructions="${1:-}"
  local scope="${2:---uncommitted}"

  if ! api_has_codex_cli; then
    return 1
  fi

  _api_ensure_log_dir

  local start_time
  start_time=$(date +%s)

  local response
  if [[ -n "${instructions}" ]]; then
    response=$(codex review "${scope}" "${instructions}" 2>/dev/null) || {
      _api_log_usage "codex_cli" "codex-review" 0 0 0 "error" "codex review failed"
      return 1
    }
  else
    response=$(codex review "${scope}" 2>/dev/null) || {
      _api_log_usage "codex_cli" "codex-review" 0 0 0 "error" "codex review failed"
      return 1
    }
  fi

  local end_time
  end_time=$(date +%s)

  local input_est=$(( ${#instructions} / 4 ))
  local output_est=$(( ${#response} / 4 ))
  local total_est=$(( input_est + output_est ))

  API_LAST_INPUT_TOKENS=${input_est}
  API_LAST_OUTPUT_TOKENS=${output_est}
  API_LAST_TOTAL_TOKENS=${total_est}
  API_LAST_MODEL="codex-review"
  API_LAST_PROVIDER="codex_cli"

  _api_log_usage "codex_cli" "codex-review" \
    "${input_est}" "${output_est}" "${total_est}" "success"

  echo "${response}"
  return 0
}

# -----------------------------------------------------------------------------
# api_has_any_key — 检查是否有任何可用的 AI 调用方式
#
# 优先级：claude CLI + codex CLI > REST API keys
# 返回:
#   0 有可用方式, 1 无可用方式
# -----------------------------------------------------------------------------
api_has_any_key() {
  api_has_claude_cli || api_has_codex_cli || [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${OPENAI_API_KEY:-}" ]]
}

# -----------------------------------------------------------------------------
# api_has_anthropic_key — 检查 Anthropic API key 是否可用
# -----------------------------------------------------------------------------
api_has_anthropic_key() {
  [[ -n "${ANTHROPIC_API_KEY:-}" ]]
}

# -----------------------------------------------------------------------------
# api_has_openai_key — 检查 OpenAI API key 是否可用
# -----------------------------------------------------------------------------
api_has_openai_key() {
  [[ -n "${OPENAI_API_KEY:-}" ]]
}

# -----------------------------------------------------------------------------
# api_get_last_usage — 获取上次 API 调用的 token 使用情况（JSON 格式）
# -----------------------------------------------------------------------------
api_get_last_usage() {
  cat <<EOF
{"provider":"${API_LAST_PROVIDER}","model":"${API_LAST_MODEL}","input_tokens":${API_LAST_INPUT_TOKENS},"output_tokens":${API_LAST_OUTPUT_TOKENS},"total_tokens":${API_LAST_TOTAL_TOKENS}}
EOF
}
