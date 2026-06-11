#!/usr/bin/env bash
set -euo pipefail

# routing.sh — Command prefix parsing and engine override routing
# Handles /review and /critical prefix commands.
# BASHCLAW_ENGINE_OVERRIDE has single-invocation scope.
# Reference: 统一实施文档 第6节, 第16节

# Parse command prefix to determine requested tier
# Input: user command string
# Output: sets ROUTING_TIER and ROUTING_COMMAND variables
routing_parse_prefix() {
  local input="$1"

  # Strip leading whitespace
  input="$(echo "${input}" | sed 's/^[[:space:]]*//')"

  # Check for /critical prefix (Tier 3)
  if [[ "${input}" == "/critical "* || "${input}" == "/critical" ]]; then
    ROUTING_TIER="3"
    ROUTING_TIER_NAME="critical"
    ROUTING_COMMAND="${input#/critical}"
    ROUTING_COMMAND="$(echo "${ROUTING_COMMAND}" | sed 's/^[[:space:]]*//')"
    return 0
  fi

  # Check for /review prefix (Tier 2)
  if [[ "${input}" == "/review "* || "${input}" == "/review" ]]; then
    ROUTING_TIER="2"
    ROUTING_TIER_NAME="reviewed"
    ROUTING_COMMAND="${input#/review}"
    ROUTING_COMMAND="$(echo "${ROUTING_COMMAND}" | sed 's/^[[:space:]]*//')"
    return 0
  fi

  # Default: no prefix, Tier 1
  ROUTING_TIER="1"
  ROUTING_TIER_NAME="default"
  ROUTING_COMMAND="${input}"
}

# Apply BASHCLAW_ENGINE_OVERRIDE for single invocation scope
# Returns the engine to use and clears the override
routing_get_engine_override() {
  local override="${BASHCLAW_ENGINE_OVERRIDE:-}"

  if [[ -n "${override}" ]]; then
    # Validate the override value
    case "${override}" in
      opus4.6|codex)
        echo "${override}"
        # Clear override after single use (single-invocation scope)
        unset BASHCLAW_ENGINE_OVERRIDE
        return 0
        ;;
      *)
        echo "WARNING: Invalid BASHCLAW_ENGINE_OVERRIDE value: ${override}" >&2
        echo "WARNING: Valid values are: opus4.6, codex" >&2
        unset BASHCLAW_ENGINE_OVERRIDE
        return 1
        ;;
    esac
  fi

  return 1
}

# Apply BASHCLAW_TIER_OVERRIDE for single invocation scope
routing_get_tier_override() {
  local override="${BASHCLAW_TIER_OVERRIDE:-}"

  if [[ -n "${override}" ]]; then
    case "${override}" in
      1|2|3)
        echo "${override}"
        unset BASHCLAW_TIER_OVERRIDE
        return 0
        ;;
      *)
        echo "WARNING: Invalid BASHCLAW_TIER_OVERRIDE value: ${override}" >&2
        return 1
        ;;
    esac
  fi

  return 1
}

# Determine effective tier considering all inputs:
# 1. Explicit prefix (/review, /critical)
# 2. BASHCLAW_TIER_OVERRIDE
# 3. Risk classification auto-upgrade
# Tier can only be upgraded, never downgraded by auto-classification
routing_resolve_tier() {
  local prefix_tier="${1:-1}"
  local risk_tier="${2:-1}"

  local effective_tier="${prefix_tier}"

  # Check environment override (single-invocation scope)
  local env_tier=""
  env_tier="$(routing_get_tier_override 2>/dev/null || echo "")"
  if [[ -n "${env_tier}" ]]; then
    effective_tier="${env_tier}"
  fi

  # Risk classification can only upgrade, never downgrade
  if [[ "${risk_tier}" -gt "${effective_tier}" ]]; then
    effective_tier="${risk_tier}"
  fi

  echo "${effective_tier}"
}

# Map tier number to tier name
routing_tier_name() {
  local tier="${1:-1}"
  case "${tier}" in
    1) echo "default" ;;
    2) echo "reviewed" ;;
    3) echo "critical" ;;
    *) echo "unknown" ;;
  esac
}

# Full routing resolution
# Parses input, applies overrides, returns structured routing decision
routing_resolve() {
  local input="$1"
  local risk_tier="${2:-1}"

  # Parse prefix
  routing_parse_prefix "${input}"
  local prefix_tier="${ROUTING_TIER}"
  local command="${ROUTING_COMMAND}"

  # Resolve effective tier
  local effective_tier
  effective_tier="$(routing_resolve_tier "${prefix_tier}" "${risk_tier}")"

  # Resolve engine
  local engine=""
  engine="$(routing_get_engine_override 2>/dev/null || echo "")"

  local tier_name
  tier_name="$(routing_tier_name "${effective_tier}")"

  cat <<EOF
{
  "routing": {
    "command": "$(echo "${command}" | sed 's/"/\\"/g')",
    "prefix_tier": ${prefix_tier},
    "risk_tier": ${risk_tier},
    "effective_tier": ${effective_tier},
    "tier_name": "${tier_name}",
    "engine_override": "${engine}"
  }
}
EOF
}
