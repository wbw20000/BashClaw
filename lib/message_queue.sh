#!/usr/bin/env bash
# Message Queue for BashClaw - Collect Mode
# Prevents concurrent --resume on the same Claude CLI session.
# When a session is busy, incoming messages are queued and merged (collected)
# into a single follow-up request after the current run completes.
#
# Uses flock for cross-process locking (socat forks per connection).

# Queue directory under state dir
_MQ_DIR="${BASHCLAW_STATE_DIR:-.}/message_queue"

# Default debounce: wait this long after last queued message before processing
MQ_DEBOUNCE_MS="${MQ_DEBOUNCE_MS:-2000}"

_mq_ensure_dir() {
  mkdir -p "$_MQ_DIR" 2>/dev/null
}

# Safe key from session_key (replace special chars)
_mq_safe_key() {
  printf '%s' "$1" | tr '/:. ' '____'
}

_mq_lock_file() {
  printf '%s/%s.lock' "$_MQ_DIR" "$(_mq_safe_key "$1")"
}

_mq_pending_file() {
  printf '%s/%s.pending' "$_MQ_DIR" "$(_mq_safe_key "$1")"
}

# Check if a session has an active run (non-blocking flock test)
mq_is_active() {
  local session_key="$1"
  _mq_ensure_dir
  local lock_file
  lock_file="$(_mq_lock_file "$session_key")"
  # Try non-blocking lock. If we get it, session is idle (release immediately).
  # If we can't get it, session is active.
  if flock -n "$lock_file" true 2>/dev/null; then
    return 1  # idle
  fi
  return 0  # active
}

# Enqueue a message for later processing
mq_enqueue() {
  local session_key="$1"
  local message="$2"
  local sender="${3:-}"
  local timestamp
  timestamp="$(date +%s)"

  _mq_ensure_dir
  local pending_file
  pending_file="$(_mq_pending_file "$session_key")"

  # Append message as a JSON line (atomic append on Linux)
  jq -nc \
    --arg msg "$message" \
    --arg ts "$timestamp" \
    --arg sender "$sender" \
    '{message: $msg, timestamp: $ts, sender: $sender}' \
    >> "$pending_file"

  log_info "mq: message queued for $session_key ($(wc -l < "$pending_file") pending)"
}

# Check if there are pending messages
mq_has_pending() {
  local session_key="$1"
  local pending_file
  pending_file="$(_mq_pending_file "$session_key")"
  [[ -f "$pending_file" ]] && [[ -s "$pending_file" ]]
}

# Collect and merge all pending messages into one prompt
mq_collect() {
  local session_key="$1"
  local pending_file
  pending_file="$(_mq_pending_file "$session_key")"

  if [[ ! -f "$pending_file" ]] || [[ ! -s "$pending_file" ]]; then
    return 1
  fi

  local count
  count="$(wc -l < "$pending_file")"

  if [[ "$count" -eq 1 ]]; then
    jq -r '.message' "$pending_file"
  else
    # Multiple messages - merge with separator
    local merged=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local msg
      msg="$(printf '%s' "$line" | jq -r '.message // empty')"
      if [[ -n "$msg" ]]; then
        if [[ -z "$merged" ]]; then
          merged="$msg"
        else
          merged="${merged}

---
${msg}"
        fi
      fi
    done < "$pending_file"
    printf '%s' "$merged"
  fi

  # Clear pending file
  rm -f "$pending_file"
}

# Debounce: wait for user to stop sending messages
mq_debounce_wait() {
  local session_key="$1"
  local debounce_ms="${2:-$MQ_DEBOUNCE_MS}"
  local pending_file
  pending_file="$(_mq_pending_file "$session_key")"

  if [[ "$debounce_ms" -le 0 ]]; then
    return
  fi

  local debounce_s
  debounce_s="$(awk "BEGIN {printf \"%.1f\", $debounce_ms / 1000}")"

  # Wait for debounce period with no new messages
  local last_size
  last_size="$(wc -c < "$pending_file" 2>/dev/null || echo 0)"
  sleep "$debounce_s"

  local new_size
  new_size="$(wc -c < "$pending_file" 2>/dev/null || echo 0)"
  while [[ "$new_size" -gt "$last_size" ]]; do
    log_debug "mq: debounce reset - new messages arrived"
    last_size="$new_size"
    sleep "$debounce_s"
    new_size="$(wc -c < "$pending_file" 2>/dev/null || echo 0)"
  done
}

# Main queue-aware dispatch wrapper
# Uses flock to ensure only one engine_run per session at a time.
# If lock is held, message is queued. The lock holder drains pending after completion.
mq_dispatch() {
  local agent_id="$1"
  local message="$2"
  local channel="$3"
  local sender="$4"
  local delivery_plan="$5"

  local session_key="${agent_id}:${channel}:${sender}"
  _mq_ensure_dir

  local lock_file
  lock_file="$(_mq_lock_file "$session_key")"

  # Try non-blocking lock (fd 9)
  exec 9>"$lock_file"
  if ! flock -n 9; then
    # Lock held by another process → session is busy → queue the message
    exec 9>&-  # close fd
    mq_enqueue "$session_key" "$message" "$sender"

    # Send "processing" notification to user via channel
    if [[ -n "$delivery_plan" ]]; then
      local queued_notice="收到消息，正在处理上一条请求，稍后一起回复。"
      routing_deliver "$delivery_plan" "$queued_notice" >/dev/null 2>&1 || true
    fi

    printf ''
    return 0
  fi

  # Lock acquired → we are the active runner
  log_debug "mq: lock acquired for $session_key"

  local response
  response="$(engine_run "$agent_id" "$message" "$channel" "$sender")"

  # Drain any messages that arrived while we were processing
  while mq_has_pending "$session_key"; do
    log_info "mq: draining pending messages for $session_key"

    mq_debounce_wait "$session_key"

    local merged_message
    merged_message="$(mq_collect "$session_key")"
    if [[ -z "$merged_message" ]]; then
      break
    fi

    log_info "mq: processing collected message ($(printf '%s' "$merged_message" | wc -c) bytes)"

    local drain_response
    drain_response="$(engine_run "$agent_id" "$merged_message" "$channel" "$sender")"

    # Deliver drain response to user via channel
    if [[ -n "$drain_response" && -n "$delivery_plan" ]]; then
      local formatted
      formatted="$(routing_format_reply "$channel" "$drain_response")"
      routing_deliver "$delivery_plan" "$formatted" >/dev/null 2>&1 || true
    fi
  done

  # Release lock
  flock -u 9
  exec 9>&-
  log_debug "mq: lock released for $session_key"

  printf '%s' "$response"
}
