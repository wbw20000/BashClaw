#!/usr/bin/env bash
# Claude Code CLI engine for BashClaw
# Delegates agent execution to Claude Code CLI (claude -p --output-format json).
# BashClaw-specific tools are accessed via `bashclaw tool <name> --flag value` through
# Claude CLI's native Bash tool. Hooks are bridged via `--settings` JSON.

ENGINE_CLAUDE_TIMEOUT="${ENGINE_CLAUDE_TIMEOUT:-120}"

# Stub for end hook (not yet implemented in BashClaw)
_engine_claude_fire_end_hook() { :; }

# BashClaw tools that map to Claude CLI native tools (no bridge needed)
_ENGINE_CLAUDE_NATIVE_TOOLS="web_fetch web_search shell read_file write_file list_files file_search"
# BashClaw tools accessed via `bashclaw tool` CLI
_ENGINE_CLAUDE_BRIDGE_TOOLS="memory cron message agents_list session_status sessions_list agent_message spawn spawn_status"

# Map BashClaw native tool names to Claude CLI tool names
_ENGINE_CLAUDE_TOOL_MAP_web_fetch="WebFetch"
_ENGINE_CLAUDE_TOOL_MAP_web_search="WebSearch"
_ENGINE_CLAUDE_TOOL_MAP_shell="Bash"
_ENGINE_CLAUDE_TOOL_MAP_read_file="Read"
_ENGINE_CLAUDE_TOOL_MAP_write_file="Write"
_ENGINE_CLAUDE_TOOL_MAP_list_files="Glob"
_ENGINE_CLAUDE_TOOL_MAP_file_search="Grep"

engine_claude_available() {
  is_command_available claude
}

engine_claude_version() {
  if engine_claude_available; then
    claude --version 2>/dev/null || printf 'unknown'
  else
    printf ''
  fi
}

engine_claude_session_id() {
  local session_file="$1"
  session_meta_get "$session_file" "cc_session_id" ""
}

# Resolve BashClaw binary path for tool invocation
_engine_claude_bashclaw_bin() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s' "${script_dir}/bashclaw"
}

# Build the context block injected into the user message.
_engine_claude_build_context() {
  local agent_id="$1"
  local channel="$2"
  local bashclaw_bin="$3"
  local is_subagent="${4:-false}"

  local system_prompt
  system_prompt="$(agent_build_system_prompt "$agent_id" "$is_subagent" "$channel" "claude")"

  cat <<CTXEOF
<bashclaw-context>
${system_prompt}

To use BashClaw tools, call them via the Bash tool:
  ${bashclaw_bin} tool <tool_name> --param1 value1 --param2 value2

Examples:
  ${bashclaw_bin} tool memory --action get --key user_notes
  ${bashclaw_bin} tool memory --action set --key todo --value "finish the report"
  ${bashclaw_bin} tool cron --action list
  ${bashclaw_bin} tool agent_message --target_agent helper --message "please review"
  ${bashclaw_bin} tool spawn --task "research topic X" --label research
  ${bashclaw_bin} tool spawn_status --task_id abc123

Output is JSON. Check the exit code for errors.
</bashclaw-context>
CTXEOF
}

# Generate settings JSON with hooks config for Claude CLI.
# Bridges BashClaw's hook system to Claude Code's native hooks.
_engine_claude_build_settings() {
  local bashclaw_bin="$1"

  jq -nc \
    --arg bridge_cmd "$bashclaw_bin" \
    '{
      hooks: {
        PreCompact: [{
          hooks: [{
            type: "command",
            command: ($bridge_cmd + " hooks-bridge pre_compact"),
            timeout: 30
          }]
        }],
        PostToolUse: [{
          hooks: [{
            type: "command",
            command: ($bridge_cmd + " hooks-bridge post_tool_use"),
            timeout: 10
          }]
        }]
      }
    }'
}

# Map BashClaw tool profile to Claude CLI --allowedTools / --disallowedTools args.
# Returns lines of the form: +ToolName (allow) or -ToolName (deny)
_engine_claude_map_profile() {
  local agent_id="$1"

  local profile
  profile="$(config_agent_get_raw "$agent_id" '.tools.profile' 2>/dev/null)"
  if is_jq_empty "$profile" || [[ "$profile" == "full" ]]; then
    return
  fi

  # Get profile tool list
  local profile_tools
  profile_tools="$(tools_resolve_profile "$profile")"
  if [[ -z "$profile_tools" ]]; then
    return
  fi

  # Map native BashClaw tools to Claude CLI tool names
  local native_tool cc_name var_name
  for native_tool in $_ENGINE_CLAUDE_NATIVE_TOOLS; do
    var_name="_ENGINE_CLAUDE_TOOL_MAP_${native_tool}"
    cc_name="${!var_name}"
    if [[ -z "$cc_name" ]]; then
      continue
    fi
    # Check if native_tool is in the profile list
    local found="false"
    local pt
    for pt in $profile_tools; do
      if [[ "$pt" == "$native_tool" ]]; then
        found="true"
        break
      fi
    done
    if [[ "$found" == "true" ]]; then
      printf '+%s\n' "$cc_name"
    else
      printf -- '-%s\n' "$cc_name"
    fi
  done

  # Bash is always needed for bridge tools
  printf '+Bash\n'
}

# Core Claude Code CLI execution
engine_claude_run() {
  local agent_id="${1:-main}"
  local message="$2"
  local channel="${3:-default}"
  local sender="${4:-}"
  local is_subagent="${5:-false}"

  if ! engine_claude_available; then
    log_error "Claude CLI not found"
    printf ''
    return 1
  fi

  require_command jq "engine_claude_run requires jq"

  # Resolve session file
  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"
  session_meta_load "$sess_file" >/dev/null 2>&1

  # Session idle reset
  session_check_idle_reset "$sess_file" || true

  # Load cc_session_id for --resume (works in WSL/Linux, hangs on Windows Git Bash)
  local cc_session_id
  cc_session_id="$(engine_claude_session_id "$sess_file")"

  # Append user message to BashClaw session for history tracking
  session_append "$sess_file" "user" "$message"

  # Resolve model
  local model
  model="$(config_agent_get "$agent_id" "engineModel" "")"
  if [[ -z "$model" ]]; then
    model="${ENGINE_CLAUDE_MODEL:-}"
  fi

  local max_turns
  max_turns="$(config_agent_get "$agent_id" "maxTurns" "50")"

  # Read timeout from config (overrides env default)
  local cfg_timeout
  cfg_timeout="$(config_agent_get "$agent_id" "engineTimeout" "")"
  if [[ -n "$cfg_timeout" ]]; then
    ENGINE_CLAUDE_TIMEOUT="$cfg_timeout"
  fi

  # Build CLI arguments
  local args=()
  args+=(--output-format json)
  if [[ -n "$model" ]]; then
    args+=(--model "$model")
  fi
  args+=(--max-turns "$max_turns")

  # Resume existing Claude CLI session for full context (tool calls, results, etc.)
  if [[ -n "$cc_session_id" ]]; then
    args+=(--resume "$cc_session_id")
  fi

  # Fallback model
  local fallback_model
  fallback_model="$(config_agent_get "$agent_id" "fallbackModel" "")"
  if [[ -n "$fallback_model" ]]; then
    args+=(--fallback-model "$fallback_model")
  fi

  # Fire session_start hook for new sessions
  if [[ -z "$cc_session_id" ]] && declare -f hooks_run &>/dev/null; then
    hooks_run "session_start" "$(jq -nc --arg aid "$agent_id" --arg ch "$channel" \
      '{agent_id: $aid, channel: $ch, engine: "claude"}')" 2>/dev/null || true
  fi

  # Prevent CLAUDE.md recursion
  args+=(--setting-sources "")

  # Generate settings JSON with hooks bridge and pass via --settings
  local bashclaw_bin
  bashclaw_bin="$(_engine_claude_bashclaw_bin)"
  local settings_file
  settings_file="$(tmpfile "claude_settings")"
  _engine_claude_build_settings "$bashclaw_bin" > "$settings_file"
  args+=(--settings "$settings_file")

  # Build context-injected message
  local context
  context="$(_engine_claude_build_context "$agent_id" "$channel" "$bashclaw_bin" "$is_subagent")"
  local full_message="${context}

${message}"

  # Tool profile mapping to --allowedTools / --disallowedTools
  local profile_mapping
  profile_mapping="$(_engine_claude_map_profile "$agent_id")"
  if [[ -n "$profile_mapping" ]]; then
    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local prefix="${line:0:1}"
      local tool_name="${line:1}"
      if [[ "$prefix" == "+" ]]; then
        args+=(--allowedTools "$tool_name")
      elif [[ "$prefix" == "-" ]]; then
        args+=(--disallowedTools "$tool_name")
      fi
    done <<< "$profile_mapping"
  fi

  # Allowed tools from agent config (explicit allow list)
  local tools_config
  tools_config="$(config_agent_get_raw "$agent_id" '.tools.allow // null')"
  if ! is_jq_empty "$tools_config"; then
    local tool_name
    while IFS= read -r tool_name; do
      [[ -z "$tool_name" ]] && continue
      args+=(--allowedTools "$tool_name")
    done < <(printf '%s' "$tools_config" | jq -r '.[]' 2>/dev/null)
  fi

  # Denied tools from agent config
  local deny_config
  deny_config="$(config_agent_get_raw "$agent_id" '.tools.deny // null')"
  if ! is_jq_empty "$deny_config"; then
    local tool_name
    while IFS= read -r tool_name; do
      [[ -z "$tool_name" ]] && continue
      # Map BashClaw native tool name to Claude CLI name if applicable
      local var_name="_ENGINE_CLAUDE_TOOL_MAP_${tool_name}"
      local cc_name="${!var_name}"
      if [[ -n "$cc_name" ]]; then
        args+=(--disallowedTools "$cc_name")
      fi
    done < <(printf '%s' "$deny_config" | jq -r '.[]' 2>/dev/null)
  fi

  log_info "engine_claude: model=${model:-default} agent=$agent_id session=${cc_session_id:-new}"
  log_debug "engine_claude: claude -p <message> ${args[*]}"

  # Execute claude CLI
  local response_file error_file
  response_file="$(tmpfile "claude_engine")"
  error_file="$(tmpfile "claude_engine_err")"

  # Run in a stable working directory so Claude CLI session data persists across calls
  # (needed for --resume). Redirect stdin from /dev/null to avoid EISDIR errors.
  local _cc_workdir="${BASHCLAW_STATE_DIR:-.}/claude-workdir"
  mkdir -p "$_cc_workdir" 2>/dev/null
  (unset CLAUDECODE; export BASHCLAW_STATE_DIR BASHCLAW_CONFIG LOG_LEVEL CLAUDE_CODE_ENTRYPOINT="bashclaw" http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
   cd "$_cc_workdir"
   claude --dangerously-skip-permissions -p "$full_message" "${args[@]}" < /dev/null > "$response_file" 2>"$error_file"
   exit $?) &
  local claude_pid=$!

  # Wait with timeout
  local waited=0 timed_out=false
  while kill -0 "$claude_pid" 2>/dev/null; do
    if (( waited >= ENGINE_CLAUDE_TIMEOUT )); then
      kill "$claude_pid" 2>/dev/null || true
      wait "$claude_pid" 2>/dev/null || true
      log_error "Claude CLI timed out after ${ENGINE_CLAUDE_TIMEOUT}s"
      timed_out=true
      rm -f "$response_file" "$error_file" "$settings_file"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  local final_text="" new_session_id="" total_cost="" num_turns="" is_error=""

  if [[ "$timed_out" == "true" ]]; then
    # Timeout: skip JSON parsing, go straight to summary fallback
    log_info "engine_claude: timed out, will attempt summary fallback"
  else
    local exit_code=0
    wait "$claude_pid" 2>/dev/null || exit_code=$?

    if [[ -s "$error_file" ]]; then
      local err_content
      err_content="$(cat "$error_file" 2>/dev/null)"
      log_warn "Claude CLI stderr: ${err_content:0:500}"

      # If --resume failed because session not found, retry without --resume
      if [[ "$err_content" == *"No conversation found"* && -n "$cc_session_id" ]]; then
        log_info "engine_claude: stale session $cc_session_id, retrying without --resume"
        session_meta_update "$sess_file" "cc_session_id" '""'
        rm -f "$error_file" "$settings_file" "$response_file"

        # Rebuild args without --resume
        local retry_args=()
        local skip_next=false
        for _a in "${args[@]}"; do
          if [[ "$skip_next" == "true" ]]; then skip_next=false; continue; fi
          if [[ "$_a" == "--resume" ]]; then skip_next=true; continue; fi
          retry_args+=("$_a")
        done

        # Regenerate settings file
        settings_file="$(tmpfile "claude_settings")"
        _engine_claude_build_settings "$bashclaw_bin" > "$settings_file"
        retry_args+=(--settings "$settings_file")

        response_file="$(tmpfile "claude_engine")"
        error_file="$(tmpfile "claude_engine_err")"
        (unset CLAUDECODE; export BASHCLAW_STATE_DIR BASHCLAW_CONFIG LOG_LEVEL CLAUDE_CODE_ENTRYPOINT="bashclaw" http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
         cd "$_cc_workdir"
         claude --dangerously-skip-permissions -p "$full_message" "${retry_args[@]}" < /dev/null > "$response_file" 2>"$error_file"
         exit $?) &
        claude_pid=$!
        waited=0
        while kill -0 "$claude_pid" 2>/dev/null; do
          if (( waited >= ENGINE_CLAUDE_TIMEOUT )); then
            kill "$claude_pid" 2>/dev/null || true
            wait "$claude_pid" 2>/dev/null || true
            timed_out=true; break
          fi
          sleep 1; waited=$((waited + 1))
        done
        if [[ "$timed_out" != "true" ]]; then
          wait "$claude_pid" 2>/dev/null || exit_code=$?
        fi
        rm -f "$error_file" "$settings_file"
      fi
    fi
    rm -f "$error_file" "$settings_file" 2>/dev/null

    # Parse JSON result
    local response
    response="$(cat "$response_file" 2>/dev/null)"
    rm -f "$response_file"

    if [[ -n "$response" ]] && printf '%s' "$response" | jq empty 2>/dev/null; then
      final_text="$(printf '%s' "$response" | jq -r '.result // empty' 2>/dev/null)"
      new_session_id="$(printf '%s' "$response" | jq -r '.session_id // empty' 2>/dev/null)"
      total_cost="$(printf '%s' "$response" | jq -r '.total_cost_usd // empty' 2>/dev/null)"
      num_turns="$(printf '%s' "$response" | jq -r '.num_turns // empty' 2>/dev/null)"
      is_error="$(printf '%s' "$response" | jq -r '.is_error // false' 2>/dev/null)"

      if [[ "$is_error" == "true" ]]; then
        log_error "Claude CLI error: ${final_text:0:500}"
      fi
    elif [[ -z "$response" ]]; then
      log_error "Claude CLI returned empty output (exit=$exit_code)"
    else
      log_error "Claude CLI returned invalid JSON"
      log_debug "Claude CLI raw output: ${response:0:500}"
    fi
  fi

  # Summary fallback: when Claude timed out or used tools but produced no text,
  # send a fresh call with --max-turns 1 to force a text-only response.
  if [[ -z "$final_text" && "$is_error" != "true" ]]; then
    local need_summary=false
    if [[ "$timed_out" == "true" ]]; then
      need_summary=true
      log_info "engine_claude: timed out after ${ENGINE_CLAUDE_TIMEOUT}s, requesting text-only summary"
    elif [[ -n "$num_turns" && "$num_turns" -gt 0 ]]; then
      need_summary=true
      log_info "engine_claude: result empty after $num_turns turns, requesting text-only summary"
    fi

    if [[ "$need_summary" == "true" ]]; then
      local summary_prompt="The user asked: ${message}

You were working on this task but ran out of time (the process was stopped after ${ENGINE_CLAUDE_TIMEOUT} seconds). Please provide a helpful text response to the user. Do NOT use any tools — respond with text only. Explain what you would need to do to complete this task, what information you need, and suggest concrete next steps. Respond in Chinese if the user's message is in Chinese."

      local summary_resp_file summary_err_file
      summary_resp_file="$(tmpfile "claude_summary")"
      summary_err_file="$(tmpfile "claude_summary_err")"
      (unset CLAUDECODE; export BASHCLAW_STATE_DIR BASHCLAW_CONFIG LOG_LEVEL CLAUDE_CODE_ENTRYPOINT="bashclaw" http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
       cd "$_cc_workdir"
       claude -p "$summary_prompt" \
         --max-turns 1 --output-format json \
         < /dev/null > "$summary_resp_file" 2>"$summary_err_file"
       exit $?) &
      local summary_pid=$!
      local sw=0
      while kill -0 "$summary_pid" 2>/dev/null; do
        if (( sw >= 60 )); then
          kill "$summary_pid" 2>/dev/null || true
          break
        fi
        sleep 1
        sw=$((sw + 1))
      done
      wait "$summary_pid" 2>/dev/null || true
      local summary_response
      summary_response="$(cat "$summary_resp_file" 2>/dev/null)"
      rm -f "$summary_resp_file" "$summary_err_file"
      if [[ -n "$summary_response" ]]; then
        local summary_text
        summary_text="$(printf '%s' "$summary_response" | jq -r '.result // empty' 2>/dev/null)"
        if [[ -n "$summary_text" ]]; then
          final_text="$summary_text"
          log_info "engine_claude: got summary response (${#summary_text} chars)"
        fi
      fi
    fi

    # If still no response after summary fallback, return error
    if [[ -z "$final_text" ]]; then
      _engine_claude_fire_end_hook "$agent_id" "$channel" "" ""
      return 1
    fi
  fi

  if [[ -n "$new_session_id" ]]; then
    session_meta_update "$sess_file" "cc_session_id" "\"${new_session_id}\""
  fi

  if [[ -n "$final_text" ]]; then
    session_append "$sess_file" "assistant" "$final_text"
  fi

  if [[ -n "$total_cost" ]]; then
    session_meta_update "$sess_file" "cc_total_cost_usd" "\"${total_cost}\""
  fi
  if [[ -n "$num_turns" ]]; then
    session_meta_update "$sess_file" "cc_num_turns" "$num_turns"
  fi

  # Usage tracking
  local input_tokens output_tokens
  input_tokens="$(printf '%s' "$response" | jq -r '.usage.input_tokens // 0' 2>/dev/null)"
  output_tokens="$(printf '%s' "$response" | jq -r '.usage.output_tokens // 0' 2>/dev/null)"
  if [[ "$input_tokens" == "null" ]]; then input_tokens=0; fi
  if [[ "$output_tokens" == "null" ]]; then output_tokens=0; fi
  if (( input_tokens > 0 || output_tokens > 0 )); then
    agent_track_usage "$agent_id" "${model:-claude}" "$input_tokens" "$output_tokens"
    local prev_total
    prev_total="$(session_meta_get "$sess_file" "totalTokens" "0")"
    local new_total=$((prev_total + input_tokens + output_tokens))
    session_meta_update "$sess_file" "totalTokens" "$new_total"
  fi

  printf '%s' "$final_text"
}
