#!/usr/bin/env bash
set -euo pipefail

# risk_classifier.sh — Risk classification for BashClaw V1
# Analyzes file paths, diff content, and change patterns to determine:
#   - tier suggestion (1/2/3)
#   - risk_tags (list of matched risk domains)
#   - changeType (one of 8 categories)
# Reference: 统一实施文档 第16节

# Source guard to prevent double-loading readonly variables
[[ -n "${_RISK_CLASSIFIER_LOADED:-}" ]] && return 0 2>/dev/null || true
_RISK_CLASSIFIER_LOADED=1

# High-risk keywords for path/filename matching (Section 16.2)
readonly RISK_KEYWORDS=(
  "auth" "permission" "oauth" "token" "secret"
  "payment" "billing" "deploy" "migration" "schema"
  "prod" "acl"
)

# Diff content patterns that indicate elevated risk (Section 16.3)
readonly DIFF_PATTERNS=(
  "token" "session" "jwt"
  "role" "permission" "tenant"
  "secret" "credential" "env"
  "migration" "alter[[:space:]]+table"
  "deploy" "helm" "docker"
  "subprocess" "ssh"
)

# Classify risk from changed file paths
# Outputs matched risk tags, one per line
risk_classify_paths() {
  local -a files=("$@")
  local -a tags=()
  local seen=""

  for file in "${files[@]}"; do
    local lower_file
    lower_file="$(echo "${file}" | tr '[:upper:]' '[:lower:]')"
    for keyword in "${RISK_KEYWORDS[@]}"; do
      if [[ "${lower_file}" == *"${keyword}"* ]]; then
        # Deduplicate
        if [[ "${seen}" != *"|${keyword}|"* ]]; then
          tags+=("${keyword}")
          seen="${seen}|${keyword}|"
        fi
      fi
    done
  done

  printf '%s\n' "${tags[@]}"
}

# Classify risk from diff content
# Reads diff from stdin or file argument
# Outputs matched risk tags, one per line
risk_classify_diff_content() {
  local diff_content=""
  if [[ $# -gt 0 && -f "$1" ]]; then
    diff_content="$(cat "$1")"
  else
    diff_content="$(cat)"
  fi

  local lower_content
  lower_content="$(echo "${diff_content}" | tr '[:upper:]' '[:lower:]')"

  local -a tags=()
  local seen=""

  for pattern in "${DIFF_PATTERNS[@]}"; do
    if echo "${lower_content}" | grep -qiE "${pattern}"; then
      # Normalize pattern for tag name (remove regex chars)
      local tag
      tag="$(echo "${pattern}" | sed 's/\[.*\].*//;s/[^a-z_]/_/g')"
      if [[ "${seen}" != *"|${tag}|"* ]]; then
        tags+=("${tag}")
        seen="${seen}|${tag}|"
      fi
    fi
  done

  printf '%s\n' "${tags[@]}"
}

# Determine changeType from diff content and file list (Section 16.4)
# Returns one of: docs_only, comment_only, test_only, logic_change,
#   config_change, schema_change, infra_change, mixed_change
risk_classify_change_type() {
  local -a files=("$@")
  local has_docs=false
  local has_comments=false
  local has_tests=false
  local has_logic=false
  local has_config=false
  local has_schema=false
  local has_infra=false
  local type_count=0

  for file in "${files[@]}"; do
    local lower
    lower="$(echo "${file}" | tr '[:upper:]' '[:lower:]')"
    local ext="${lower##*.}"
    local basename
    basename="$(basename "${lower}")"

    # Documentation files
    if [[ "${ext}" == "md" || "${ext}" == "rst" || "${ext}" == "txt" \
       || "${ext}" == "adoc" || "${basename}" == "readme" \
       || "${basename}" == "changelog" || "${basename}" == "license" \
       || "${lower}" == *"/docs/"* || "${lower}" == *"/doc/"* ]]; then
      has_docs=true
      continue
    fi

    # Test files
    if [[ "${lower}" == *"test"* || "${lower}" == *"spec"* \
       || "${lower}" == *"__tests__"* || "${lower}" == *"_test."* \
       || "${lower}" == *".test."* || "${lower}" == *".spec."* \
       || "${lower}" == *"/tests/"* || "${lower}" == *"/test/"* ]]; then
      has_tests=true
      continue
    fi

    # Schema / migration files
    if [[ "${ext}" == "sql" || "${lower}" == *"migration"* \
       || "${lower}" == *"schema"* || "${lower}" == *"alembic"* \
       || "${lower}" == *"migrate"* ]]; then
      has_schema=true
      continue
    fi

    # Infrastructure files
    if [[ "${ext}" == "yml" || "${ext}" == "yaml" ]] \
       && [[ "${lower}" == *"docker"* || "${lower}" == *"helm"* \
          || "${lower}" == *"k8s"* || "${lower}" == *"kubernetes"* \
          || "${lower}" == *"ci"* || "${lower}" == *"cd"* \
          || "${lower}" == *"deploy"* || "${lower}" == *"terraform"* \
          || "${lower}" == *"ansible"* || "${basename}" == ".github"* ]]; then
      has_infra=true
      continue
    fi
    if [[ "${basename}" == "dockerfile"* || "${ext}" == "tf" \
       || "${basename}" == "jenkinsfile" || "${basename}" == ".gitlab-ci.yml" \
       || "${basename}" == ".github" ]]; then
      has_infra=true
      continue
    fi

    # Config files
    if [[ "${ext}" == "json" || "${ext}" == "toml" || "${ext}" == "ini" \
       || "${ext}" == "cfg" || "${ext}" == "conf" || "${ext}" == "env" \
       || "${basename}" == ".env"* || "${basename}" == "pyproject.toml" \
       || "${basename}" == "package.json" || "${basename}" == "tsconfig.json" \
       || "${basename}" == ".eslintrc"* || "${basename}" == ".prettierrc"* ]]; then
      has_config=true
      continue
    fi

    # Default: logic change (source code)
    has_logic=true
  done

  # Count how many types are present
  ${has_docs} && type_count=$((type_count + 1))
  ${has_tests} && type_count=$((type_count + 1))
  ${has_logic} && type_count=$((type_count + 1))
  ${has_config} && type_count=$((type_count + 1))
  ${has_schema} && type_count=$((type_count + 1))
  ${has_infra} && type_count=$((type_count + 1))

  # Determine single type or mixed
  if [[ ${type_count} -eq 0 ]]; then
    # Only comments or empty — check if we had files at all
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "docs_only"
    else
      echo "comment_only"
    fi
  elif [[ ${type_count} -eq 1 ]]; then
    if ${has_docs}; then echo "docs_only"
    elif ${has_tests}; then echo "test_only"
    elif ${has_logic}; then echo "logic_change"
    elif ${has_config}; then echo "config_change"
    elif ${has_schema}; then echo "schema_change"
    elif ${has_infra}; then echo "infra_change"
    else echo "mixed_change"
    fi
  else
    echo "mixed_change"
  fi
}

# Check if a changeType is considered low-risk (Section 16.5)
risk_is_low_risk_change_type() {
  local change_type="$1"
  case "${change_type}" in
    docs_only|comment_only|test_only) return 0 ;;
    *) return 1 ;;
  esac
}

# Suggest a tier based on risk analysis (Section 16.6)
# Returns: 1, 2, or 3
risk_suggest_tier() {
  local change_type="$1"
  shift
  local -a risk_tags=("$@")

  # Tier 3 triggers: critical risk domains
  local tier3_keywords=("auth" "permission" "oauth" "token" "secret" "payment" "billing" "deploy" "migration" "schema" "prod" "acl")
  for tag in "${risk_tags[@]}"; do
    for kw in "${tier3_keywords[@]}"; do
      if [[ "${tag}" == "${kw}" ]]; then
        echo "3"
        return 0
      fi
    done
  done

  # Tier 2 triggers: non-low-risk change types
  if ! risk_is_low_risk_change_type "${change_type}"; then
    echo "2"
    return 0
  fi

  # Default: Tier 1
  echo "1"
}

# Full risk classification pipeline
# Usage: risk_classify [--files file1 file2 ...] [--diff diff_file]
# Outputs JSON-like structured result
risk_classify() {
  local -a files=()
  local diff_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --files)
        shift
        while [[ $# -gt 0 && "$1" != "--"* ]]; do
          files+=("$1")
          shift
        done
        ;;
      --diff)
        shift
        diff_file="${1:-}"
        [[ -n "${diff_file}" ]] && shift
        ;;
      *)
        shift
        ;;
    esac
  done

  # Collect risk tags from paths
  local -a path_tags=()
  if [[ ${#files[@]} -gt 0 ]]; then
    while IFS= read -r tag; do
      [[ -n "${tag}" ]] && path_tags+=("${tag}")
    done < <(risk_classify_paths "${files[@]}")
  fi

  # Collect risk tags from diff content
  local -a diff_tags=()
  if [[ -n "${diff_file}" && -f "${diff_file}" ]]; then
    while IFS= read -r tag; do
      [[ -n "${tag}" ]] && diff_tags+=("${tag}")
    done < <(risk_classify_diff_content "${diff_file}")
  fi

  # Merge and deduplicate tags
  local -a all_tags=()
  local seen=""
  for tag in "${path_tags[@]}" "${diff_tags[@]}"; do
    if [[ "${seen}" != *"|${tag}|"* ]]; then
      all_tags+=("${tag}")
      seen="${seen}|${tag}|"
    fi
  done

  # Determine changeType
  local change_type="logic_change"
  if [[ ${#files[@]} -gt 0 ]]; then
    change_type="$(risk_classify_change_type "${files[@]}")"
  fi

  # Suggest tier
  local tier
  tier="$(risk_suggest_tier "${change_type}" "${all_tags[@]+"${all_tags[@]}"}")"

  # Output structured result
  local tags_json="[]"
  if [[ ${#all_tags[@]} -gt 0 ]]; then
    tags_json="["
    local first=true
    for tag in "${all_tags[@]}"; do
      ${first} || tags_json="${tags_json},"
      tags_json="${tags_json}\"${tag}\""
      first=false
    done
    tags_json="${tags_json}]"
  fi

  cat <<EOF
{
  "tier_suggestion": ${tier},
  "risk_tags": ${tags_json},
  "change_type": "${change_type}",
  "file_count": ${#files[@]},
  "risk_tag_count": ${#all_tags[@]}
}
EOF
}
