#!/usr/bin/env bash
# Discord Bot API channel for BashClaw

DISCORD_API="https://discord.com/api/v10"
DISCORD_MAX_MESSAGE_LENGTH=2000
DISCORD_POLL_INTERVAL="${DISCORD_POLL_INTERVAL:-5}"

# ---- API Helpers ----

_discord_token() {
  local token="${BASHCLAW_DISCORD_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token="$(config_channel_get "discord" "botToken" "")"
  fi
  if [[ -z "$token" ]]; then
    log_error "Discord bot token not configured (set BASHCLAW_DISCORD_TOKEN or channels.discord.botToken)"
    return 1
  fi
  printf '%s' "$token"
}

_discord_api() {
  local method="$1"
  local path="$2"
  shift 2

  local token
  token="$(_discord_token)" || return 1

  local url="${DISCORD_API}${path}"
  local response
  case "$method" in
    GET)
      response="$(curl -sS --max-time 30 \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        "$@" "$url" 2>/dev/null)"
      ;;
    POST)
      # Write POST data to temp file to avoid Git Bash encoding issues with -d
      local _post_tmpfile
      _post_tmpfile="$(mktemp "${TMPDIR:-/tmp}/bashclaw_post.XXXXXX")"
      # Extract -d argument from "$@" and write to file
      local _post_args=()
      local _post_data=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -d) _post_data="$2"; shift 2 ;;
          *)  _post_args+=("$1"); shift ;;
        esac
      done
      if [[ -n "$_post_data" ]]; then
        printf '%s' "$_post_data" > "$_post_tmpfile"
        response="$(curl -sS --max-time 30 \
          -X POST \
          -H "Authorization: Bot ${token}" \
          -H "Content-Type: application/json" \
          -d @"$_post_tmpfile" \
          "${_post_args[@]}" "$url" 2>/dev/null)"
      else
        response="$(curl -sS --max-time 30 \
          -X POST \
          -H "Authorization: Bot ${token}" \
          -H "Content-Type: application/json" \
          "${_post_args[@]}" "$url" 2>/dev/null)"
      fi
      rm -f "$_post_tmpfile"
      ;;
    *)
      log_error "Discord API: unsupported method $method"
      return 1
      ;;
  esac

  if [[ $? -ne 0 || -z "$response" ]]; then
    log_error "Discord API request failed: $method $path"
    return 1
  fi

  # Check for Discord error response
  local error_code
  error_code="$(printf '%s' "$response" | jq -r '.code // empty' 2>/dev/null)"
  if [[ -n "$error_code" ]]; then
    local error_msg
    error_msg="$(printf '%s' "$response" | jq -r '.message // "unknown error"')"
    log_error "Discord API error ($method $path): [$error_code] $error_msg"

    # Handle rate limiting
    local retry_after
    retry_after="$(printf '%s' "$response" | jq -r '.retry_after // empty' 2>/dev/null)"
    if [[ -n "$retry_after" ]]; then
      log_warn "Discord rate limited, waiting ${retry_after}s"
      sleep "$retry_after"
    fi

    printf '%s' "$response"
    return 1
  fi

  printf '%s' "$response"
}

# ---- Public Functions ----

channel_discord_send() {
  local channel_id="$1"
  local text="$2"

  if [[ -z "$channel_id" || -z "$text" ]]; then
    log_error "channel_discord_send: channel_id and text are required"
    return 1
  fi

  require_command jq "channel_discord_send requires jq"

  # Split long messages at the Discord limit
  local parts=()
  local remaining="$text"
  while (( ${#remaining} > DISCORD_MAX_MESSAGE_LENGTH )); do
    local chunk="${remaining:0:$DISCORD_MAX_MESSAGE_LENGTH}"
    local split_pos=-1
    # Find last newline in chunk using bash string ops (portable)
    local _before="${chunk%$'\n'*}"
    if [[ "$_before" != "$chunk" ]]; then
      split_pos="${#_before}"
    fi
    if (( split_pos < 0 )); then
      split_pos=$DISCORD_MAX_MESSAGE_LENGTH
    fi
    parts+=("${remaining:0:$split_pos}")
    remaining="${remaining:$split_pos}"
    remaining="${remaining#$'\n'}"
  done
  if [[ -n "$remaining" ]]; then
    parts+=("$remaining")
  fi

  local last_msg_id=""
  local part
  for part in "${parts[@]}"; do
    local data
    data="$(jq -nc --arg content "$part" '{content: $content}')"

    local response
    response="$(_discord_api POST "/channels/${channel_id}/messages" -d "$data")" || return 1
    last_msg_id="$(printf '%s' "$response" | jq -r '.id // ""')"
  done

  printf '%s' "$last_msg_id"
}

channel_discord_reply() {
  local channel_id="$1"
  local message_id="$2"
  local text="$3"

  if [[ -z "$channel_id" || -z "$message_id" || -z "$text" ]]; then
    log_error "channel_discord_reply: channel_id, message_id, and text required"
    return 1
  fi

  require_command jq "channel_discord_reply requires jq"

  local data
  data="$(jq -nc --arg content "$text" --arg mid "$message_id" \
    '{content: $content, message_reference: {message_id: $mid}}')"

  local response
  response="$(_discord_api POST "/channels/${channel_id}/messages" -d "$data")" || return 1
  printf '%s' "$response" | jq -r '.id // ""'
}

channel_discord_get_me() {
  _discord_api GET "/users/@me"
}

channel_discord_get_gateway() {
  _discord_api GET "/gateway/bot"
}

# ---- HTTP Poll Listener ----

# Tracks last seen message ID per channel (file-based for bash 3.2 compat)
_DISCORD_LAST_MSG_DIR=""

_discord_last_msg_init() {
  if [[ -z "$_DISCORD_LAST_MSG_DIR" ]]; then
    _DISCORD_LAST_MSG_DIR="$(tmpdir "bashclaw_discord")"
  fi
}

_discord_last_msg_get() {
  _discord_last_msg_init
  local ch_id="$1"
  local f="$_DISCORD_LAST_MSG_DIR/$ch_id"
  if [[ -f "$f" ]]; then cat "$f"; else echo ""; fi
}

_discord_last_msg_set() {
  _discord_last_msg_init
  local ch_id="$1" msg_id="$2"
  printf '%s' "$msg_id" > "$_DISCORD_LAST_MSG_DIR/$ch_id"
}

channel_discord_start() {
  log_info "Discord HTTP poll listener starting..."

  local me
  me="$(channel_discord_get_me)" || {
    log_error "Failed to verify Discord bot identity"
    return 1
  }
  local bot_id bot_username
  bot_id="$(printf '%s' "$me" | jq -r '.id // ""')"
  bot_username="$(printf '%s' "$me" | jq -r '.username // "unknown"')"
  log_info "Discord bot: ${bot_username} (${bot_id})"

  # Read configured channel IDs to monitor
  local channels_json
  channels_json="$(config_get_raw '.channels.discord.monitorChannels // []')"
  local num_channels
  num_channels="$(printf '%s' "$channels_json" | jq 'length')"

  if (( num_channels == 0 )); then
    log_warn "No Discord channels configured to monitor (set channels.discord.monitorChannels)"
    return 1
  fi

  log_info "Monitoring $num_channels Discord channels"

  while true; do
    local c=0
    while (( c < num_channels )); do
      local chan_id
      chan_id="$(printf '%s' "$channels_json" | jq -r ".[$c]")"

      local after
      after="$(_discord_last_msg_get "$chan_id")"
      local query_params=""
      if [[ -n "$after" ]]; then
        query_params="?after=${after}&limit=50"
      else
        query_params="?limit=1"
      fi

      local messages
      messages="$(_discord_api GET "/channels/${chan_id}/messages${query_params}" 2>/dev/null)"
      local api_exit=$?
      if [[ $api_exit -ne 0 || -z "$messages" ]]; then
        log_debug "Discord poll failed: channel=$chan_id exit=$api_exit empty=$([[ -z "$messages" ]] && echo yes || echo no)"
        c=$((c + 1))
        continue
      fi

      local msg_count
      msg_count="$(printf '%s' "$messages" | jq 'if type == "array" then length else 0 end')"

      if (( msg_count == 0 )); then
        c=$((c + 1))
        continue
      fi

      # Process messages in chronological order (API returns newest first)
      local m=$((msg_count - 1))
      while (( m >= 0 )); do
        local msg
        msg="$(printf '%s' "$messages" | jq -c ".[$m]")"
        local msg_id author_id author_bot content
        msg_id="$(printf '%s' "$msg" | jq -r '.id // ""')"
        author_id="$(printf '%s' "$msg" | jq -r '.author.id // ""')"
        author_bot="$(printf '%s' "$msg" | jq -r '.author.bot // false')"
        content="$(printf '%s' "$msg" | jq -r '.content // ""')"

        # Update last seen message
        _discord_last_msg_set "$chan_id" "$msg_id"

        # Skip bot messages (including our own)
        if [[ "$author_bot" == "true" || "$author_id" == "$bot_id" ]]; then
          m=$((m - 1))
          continue
        fi

        if [[ -z "$content" ]]; then
          m=$((m - 1))
          continue
        fi

        log_info "Discord message: channel=$chan_id author=$author_id"
        log_debug "Discord text: ${content:0:100}"

        # Check if this channel is a DM-like channel (no mention required)
        local is_group="true"
        local dm_channels
        dm_channels="$(config_get_raw '.channels.discord.dmChannels // []' 2>/dev/null)"
        if printf '%s' "$dm_channels" | jq -e --arg cid "$chan_id" 'any(. == $cid)' >/dev/null 2>&1; then
          is_group="false"
        fi

        local reply
        reply="$(routing_dispatch "discord" "$author_id" "$content" "$is_group")"
        if [[ -n "$reply" ]]; then
          channel_discord_reply "$chan_id" "$msg_id" "$reply" || true
        fi

        m=$((m - 1))
      done

      c=$((c + 1))
    done

    sleep "$DISCORD_POLL_INTERVAL"
  done
}

# Register channel send function for tool_message
_channel_send_discord() {
  local target="$1"
  local message="$2"
  local msg_id
  msg_id="$(channel_discord_send "$target" "$message")" || {
    jq -nc --arg ch "discord" --arg err "send failed" \
      '{"sent": false, "channel": $ch, "error": $err}'
    return 1
  }
  jq -nc --arg ch "discord" --arg mid "$msg_id" --arg tgt "$target" \
    '{"sent": true, "channel": $ch, "messageId": $mid, "target": $tgt}'
}
