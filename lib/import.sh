#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# import.sh — BashClaw conversation importers
#
# Two importers for Phase 1:
#   - import_claude_code: Claude Code JSONL format
#   - import_chatgpt: ChatGPT export JSON format
#
# Both normalize into the conversations + messages tables via store.sh.
###############################################################################

[[ -n "${_IMPORT_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_IMPORT_SH_LOADED=1

BASHCLAW_ROOT="${BASHCLAW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ -f "${BASHCLAW_ROOT}/lib/store.sh" ]]; then
  source "${BASHCLAW_ROOT}/lib/store.sh"
fi

###############################################################################
# import_claude_code — Import Claude Code JSONL session
#
# Format: one JSON object per line with {type, text}
#   {"type":"human","text":"Fix the auth bug"}
#   {"type":"assistant","text":"I'll fix it"}
#
# Args: file_path [title]
###############################################################################
import_claude_code() {
  local file_path="$1"
  local title="${2:-$(basename "${file_path}" .jsonl)}"

  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: File not found: ${file_path}" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq required for import" >&2
    return 1
  fi

  local conv_id
  conv_id=$(store_conversation_insert "claude_code" "${title}" "")

  local seq=0
  local error_count=0
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local msg_type msg_text role
    msg_type=$(echo "${line}" | jq -r '.type // ""' 2>/dev/null) || {
      error_count=$((error_count + 1))
      continue
    }
    msg_text=$(echo "${line}" | jq -r '.text // ""' 2>/dev/null) || {
      error_count=$((error_count + 1))
      continue
    }

    case "${msg_type}" in
      human|user) role="user" ;;
      assistant) role="assistant" ;;
      system) role="system" ;;
      tool*) role="tool" ;;
      *) role="user" ;;
    esac

    store_message_insert "${conv_id}" "${role}" "${msg_text}" "${seq}" >/dev/null
    seq=$((seq + 1))
  done < "${file_path}"

  if [[ ${error_count} -gt 0 ]]; then
    echo "WARNING: ${error_count} line(s) failed to parse in ${file_path}" >&2
  fi
  echo "${conv_id}"
}

###############################################################################
# import_chatgpt — Import ChatGPT export JSON
#
# Format: { title, mapping: { id: { message: { author: {role}, content: {parts:[]} } } } }
#
# Args: file_path
###############################################################################
import_chatgpt() {
  local file_path="$1"

  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: File not found: ${file_path}" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq required for import" >&2
    return 1
  fi

  local title
  title=$(jq -r '.title // "Untitled"' "${file_path}")

  local conv_id
  conv_id=$(store_conversation_insert "chatgpt" "${title}" "")

  # Extract messages from mapping, filter nulls, sort by order if possible
  local seq=0
  local error_count=0
  local skip_count=0
  while IFS= read -r msg_json; do
    [[ -z "${msg_json}" || "${msg_json}" == "null" ]] && continue
    local role content
    role=$(echo "${msg_json}" | jq -r '.message.author.role // ""' 2>/dev/null) || {
      error_count=$((error_count + 1))
      continue
    }
    content=$(echo "${msg_json}" | jq -r '.message.content.parts[0] // ""' 2>/dev/null) || {
      error_count=$((error_count + 1))
      continue
    }

    if [[ -z "${role}" || -z "${content}" ]]; then
      skip_count=$((skip_count + 1))
      continue
    fi

    store_message_insert "${conv_id}" "${role}" "${content}" "${seq}" >/dev/null
    seq=$((seq + 1))
  done < <(jq -c '.mapping | to_entries[] | .value | select(.message != null)' "${file_path}" 2>/dev/null)

  if [[ ${error_count} -gt 0 || ${skip_count} -gt 0 ]]; then
    echo "WARNING: imported ${seq} messages, ${error_count} parse error(s), ${skip_count} skipped (empty role/content)" >&2
  fi
  echo "${conv_id}"
}

###############################################################################
# import_dispatch — Route import subcommands
#
# Args: source_type file_path [extra_args...]
###############################################################################
import_dispatch() {
  local source_type="${1:-}"
  local file_path="${2:-}"

  if [[ -z "${source_type}" || -z "${file_path}" ]]; then
    echo "Usage: bashclaw import <source> <file>" >&2
    echo "Sources: claude-code, chatgpt" >&2
    return 1
  fi

  shift 2

  case "${source_type}" in
    claude-code|claude_code)
      import_claude_code "${file_path}" "$@"
      ;;
    chatgpt)
      import_chatgpt "${file_path}" "$@"
      ;;
    *)
      echo "ERROR: Unknown import source: ${source_type}" >&2
      echo "Supported: claude-code, chatgpt" >&2
      return 1
      ;;
  esac
}
