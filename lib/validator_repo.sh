#!/usr/bin/env bash
set -euo pipefail

# validator_repo.sh — Repo-aware base validation for BashClaw V1
# Detects project tech stack and runs appropriate validators.
# Results: PASS, FAIL_TEST, FAIL_LINT, FAIL_TYPECHECK, FAIL_REPRO, FAIL_VALIDATE, NO_VALIDATOR_FOUND
# NO_VALIDATOR_FOUND ≠ PASS
# Reference: 统一实施文档 第9节

# Detect the project's tech stack by examining files in the repo
validator_detect_stack() {
  local repo_root="${1:-.}"
  local -a stacks=()

  # Python
  if [[ -f "${repo_root}/pyproject.toml" || -f "${repo_root}/setup.py" \
     || -f "${repo_root}/setup.cfg" || -f "${repo_root}/requirements.txt" \
     || -f "${repo_root}/Pipfile" ]]; then
    stacks+=("python")
  fi

  # JavaScript / TypeScript
  if [[ -f "${repo_root}/package.json" ]]; then
    stacks+=("js")
    if [[ -f "${repo_root}/tsconfig.json" ]]; then
      stacks+=("ts")
    fi
  fi

  # Shell scripts
  local shell_count=0
  shell_count="$(find "${repo_root}" -maxdepth 3 -name "*.sh" -type f 2>/dev/null | head -20 | wc -l)"
  if [[ ${shell_count} -gt 0 ]]; then
    stacks+=("shell")
  fi

  # Docker
  if [[ -f "${repo_root}/Dockerfile" || -f "${repo_root}/docker-compose.yml" \
     || -f "${repo_root}/docker-compose.yaml" ]]; then
    stacks+=("docker")
  fi

  # SQL / migrations
  if find "${repo_root}" -maxdepth 3 -name "*.sql" -type f 2>/dev/null | head -1 | grep -q .; then
    stacks+=("sql")
  fi
  if [[ -d "${repo_root}/migrations" || -d "${repo_root}/alembic" ]]; then
    stacks+=("migration")
  fi

  if [[ ${#stacks[@]} -eq 0 ]]; then
    echo "unknown"
  else
    printf '%s\n' "${stacks[@]}"
  fi
}

# Run Python validation (Section 9.3: pytest → ruff → mypy → pyproject scripts → Makefile/justfile)
validator_run_python() {
  local repo_root="${1:-.}"
  local -a results=()

  # pytest
  if command -v pytest &>/dev/null; then
    if (cd "${repo_root}" && pytest --tb=short -q 2>&1); then
      results+=('{"name":"pytest","status":"PASS"}')
    else
      results+=('{"name":"pytest","status":"FAIL_TEST"}')
    fi
  elif [[ -f "${repo_root}/pyproject.toml" ]] && grep -q "pytest" "${repo_root}/pyproject.toml" 2>/dev/null; then
    if (cd "${repo_root}" && python -m pytest --tb=short -q 2>&1); then
      results+=('{"name":"pytest","status":"PASS"}')
    else
      results+=('{"name":"pytest","status":"FAIL_TEST"}')
    fi
  fi

  # ruff
  if command -v ruff &>/dev/null; then
    if (cd "${repo_root}" && ruff check . 2>&1); then
      results+=('{"name":"ruff","status":"PASS"}')
    else
      results+=('{"name":"ruff","status":"FAIL_LINT"}')
    fi
  fi

  # mypy
  if command -v mypy &>/dev/null; then
    if (cd "${repo_root}" && mypy . 2>&1); then
      results+=('{"name":"mypy","status":"PASS"}')
    else
      results+=('{"name":"mypy","status":"FAIL_TYPECHECK"}')
    fi
  fi

  # pyproject scripts
  if [[ -f "${repo_root}/pyproject.toml" ]] && grep -q '\[project.scripts\]' "${repo_root}/pyproject.toml" 2>/dev/null; then
    results+=('{"name":"pyproject_scripts","status":"PASS","note":"detected but not auto-run"}')
  fi

  # Makefile / justfile
  if [[ -f "${repo_root}/Makefile" ]]; then
    if grep -q "^test:" "${repo_root}/Makefile" 2>/dev/null; then
      if (cd "${repo_root}" && make test 2>&1); then
        results+=('{"name":"make_test","status":"PASS"}')
      else
        results+=('{"name":"make_test","status":"FAIL_TEST"}')
      fi
    fi
  fi
  if [[ -f "${repo_root}/justfile" ]] && command -v just &>/dev/null; then
    if just --list 2>/dev/null | grep -q "test"; then
      if (cd "${repo_root}" && just test 2>&1); then
        results+=('{"name":"just_test","status":"PASS"}')
      else
        results+=('{"name":"just_test","status":"FAIL_TEST"}')
      fi
    fi
  fi

  printf '%s\n' "${results[@]}"
}

# Run JS/TS validation (Section 9.3: npm/pnpm/yarn test → eslint → tsc --noEmit)
validator_run_js() {
  local repo_root="${1:-.}"
  local -a results=()

  # Detect package manager
  local pm="npm"
  if [[ -f "${repo_root}/pnpm-lock.yaml" ]]; then
    pm="pnpm"
  elif [[ -f "${repo_root}/yarn.lock" ]]; then
    pm="yarn"
  fi

  # Run tests
  if [[ -f "${repo_root}/package.json" ]] && grep -q '"test"' "${repo_root}/package.json" 2>/dev/null; then
    if (cd "${repo_root}" && ${pm} test 2>&1); then
      results+=('{"name":"'${pm}'_test","status":"PASS"}')
    else
      results+=('{"name":"'${pm}'_test","status":"FAIL_TEST"}')
    fi
  fi

  # eslint
  if command -v eslint &>/dev/null || [[ -f "${repo_root}/node_modules/.bin/eslint" ]]; then
    local eslint_cmd="eslint"
    [[ -f "${repo_root}/node_modules/.bin/eslint" ]] && eslint_cmd="${repo_root}/node_modules/.bin/eslint"
    if (cd "${repo_root}" && ${eslint_cmd} . 2>&1); then
      results+=('{"name":"eslint","status":"PASS"}')
    else
      results+=('{"name":"eslint","status":"FAIL_LINT"}')
    fi
  fi

  # tsc --noEmit (TypeScript only)
  if [[ -f "${repo_root}/tsconfig.json" ]]; then
    local tsc_cmd="tsc"
    [[ -f "${repo_root}/node_modules/.bin/tsc" ]] && tsc_cmd="${repo_root}/node_modules/.bin/tsc"
    if command -v "${tsc_cmd}" &>/dev/null || [[ -f "${tsc_cmd}" ]]; then
      if (cd "${repo_root}" && ${tsc_cmd} --noEmit 2>&1); then
        results+=('{"name":"tsc","status":"PASS"}')
      else
        results+=('{"name":"tsc","status":"FAIL_TYPECHECK"}')
      fi
    fi
  fi

  printf '%s\n' "${results[@]}"
}

# Run shell validation (Section 9.3: shellcheck)
validator_run_shell() {
  local repo_root="${1:-.}"
  local -a results=()

  if command -v shellcheck &>/dev/null; then
    local -a shell_files=()
    while IFS= read -r f; do
      [[ -n "${f}" ]] && shell_files+=("${f}")
    done < <(find "${repo_root}" -maxdepth 3 -name "*.sh" -type f 2>/dev/null | head -50)

    if [[ ${#shell_files[@]} -gt 0 ]]; then
      if shellcheck "${shell_files[@]}" 2>&1; then
        results+=('{"name":"shellcheck","status":"PASS"}')
      else
        results+=('{"name":"shellcheck","status":"FAIL_LINT"}')
      fi
    fi
  else
    results+=('{"name":"shellcheck","status":"NO_VALIDATOR_FOUND","note":"shellcheck not installed"}')
  fi

  printf '%s\n' "${results[@]}"
}

# Run Docker/YAML validation (Section 9.3: parse/lint/dry-run)
validator_run_docker() {
  local repo_root="${1:-.}"
  local -a results=()

  # Dockerfile lint
  if [[ -f "${repo_root}/Dockerfile" ]]; then
    if command -v hadolint &>/dev/null; then
      if hadolint "${repo_root}/Dockerfile" 2>&1; then
        results+=('{"name":"hadolint","status":"PASS"}')
      else
        results+=('{"name":"hadolint","status":"FAIL_LINT"}')
      fi
    fi
  fi

  # docker-compose config (dry-run parse)
  local compose_file=""
  if [[ -f "${repo_root}/docker-compose.yml" ]]; then
    compose_file="${repo_root}/docker-compose.yml"
  elif [[ -f "${repo_root}/docker-compose.yaml" ]]; then
    compose_file="${repo_root}/docker-compose.yaml"
  fi

  if [[ -n "${compose_file}" ]]; then
    if command -v docker-compose &>/dev/null; then
      if (cd "${repo_root}" && docker-compose config --quiet 2>&1); then
        results+=('{"name":"docker_compose_config","status":"PASS"}')
      else
        results+=('{"name":"docker_compose_config","status":"FAIL_VALIDATE"}')
      fi
    elif command -v docker &>/dev/null; then
      if (cd "${repo_root}" && docker compose config --quiet 2>&1); then
        results+=('{"name":"docker_compose_config","status":"PASS"}')
      else
        results+=('{"name":"docker_compose_config","status":"FAIL_VALIDATE"}')
      fi
    fi
  fi

  # YAML lint
  if command -v yamllint &>/dev/null; then
    local -a yaml_files=()
    while IFS= read -r f; do
      [[ -n "${f}" ]] && yaml_files+=("${f}")
    done < <(find "${repo_root}" -maxdepth 3 \( -name "*.yml" -o -name "*.yaml" \) -type f 2>/dev/null | head -20)

    if [[ ${#yaml_files[@]} -gt 0 ]]; then
      if yamllint "${yaml_files[@]}" 2>&1; then
        results+=('{"name":"yamllint","status":"PASS"}')
      else
        results+=('{"name":"yamllint","status":"FAIL_LINT"}')
      fi
    fi
  fi

  printf '%s\n' "${results[@]}"
}

# Run SQL/migration validation (Section 9.3: validate/schema diff/dry-run)
validator_run_sql() {
  local repo_root="${1:-.}"
  local -a results=()

  # Alembic migrations
  if [[ -d "${repo_root}/alembic" ]] && command -v alembic &>/dev/null; then
    if (cd "${repo_root}" && alembic check 2>&1); then
      results+=('{"name":"alembic_check","status":"PASS"}')
    else
      results+=('{"name":"alembic_check","status":"FAIL_VALIDATE"}')
    fi
  fi

  # Django migrations
  if [[ -f "${repo_root}/manage.py" ]]; then
    if (cd "${repo_root}" && python manage.py migrate --check 2>&1); then
      results+=('{"name":"django_migrate_check","status":"PASS"}')
    else
      results+=('{"name":"django_migrate_check","status":"FAIL_VALIDATE"}')
    fi
  fi

  # SQL syntax check via basic parse
  local -a sql_files=()
  while IFS= read -r f; do
    [[ -n "${f}" ]] && sql_files+=("${f}")
  done < <(find "${repo_root}" -maxdepth 3 -name "*.sql" -type f 2>/dev/null | head -20)

  if [[ ${#sql_files[@]} -gt 0 ]]; then
    if command -v sqlfluff &>/dev/null; then
      if sqlfluff lint "${sql_files[@]}" 2>&1; then
        results+=('{"name":"sqlfluff","status":"PASS"}')
      else
        results+=('{"name":"sqlfluff","status":"FAIL_LINT"}')
      fi
    else
      results+=('{"name":"sql_lint","status":"NO_VALIDATOR_FOUND","note":"no SQL linter found"}')
    fi
  fi

  printf '%s\n' "${results[@]}"
}

# Run docs-only validation (Section 9.3: optional format check)
validator_run_docs() {
  local repo_root="${1:-.}"
  local -a results=()

  # Markdown lint (optional)
  if command -v markdownlint &>/dev/null; then
    local -a md_files=()
    while IFS= read -r f; do
      [[ -n "${f}" ]] && md_files+=("${f}")
    done < <(find "${repo_root}" -maxdepth 3 -name "*.md" -type f 2>/dev/null | head -20)

    if [[ ${#md_files[@]} -gt 0 ]]; then
      if markdownlint "${md_files[@]}" 2>&1; then
        results+=('{"name":"markdownlint","status":"PASS"}')
      else
        results+=('{"name":"markdownlint","status":"FAIL_LINT"}')
      fi
    fi
  fi

  # For docs-only changes, we don't run heavy tests
  if [[ ${#results[@]} -eq 0 ]]; then
    results+=('{"name":"docs_check","status":"PASS","note":"docs_only change, no heavy validation needed"}')
  fi

  printf '%s\n' "${results[@]}"
}

# Aggregate validation results into a final status
# Returns the worst status found (Section 9.4)
validator_aggregate_status() {
  local -a results=("$@")
  local worst="PASS"

  for result in "${results[@]}"; do
    local status
    status="$(echo "${result}" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    status="${status:-PASS}"

    case "${status}" in
      FAIL_TEST|FAIL_REPRO)
        echo "${status}"
        return 0  # Test failure is terminal
        ;;
      FAIL_LINT)
        [[ "${worst}" == "PASS" || "${worst}" == "NO_VALIDATOR_FOUND" ]] && worst="${status}"
        ;;
      FAIL_TYPECHECK)
        [[ "${worst}" == "PASS" || "${worst}" == "NO_VALIDATOR_FOUND" || "${worst}" == "FAIL_LINT" ]] && worst="${status}"
        ;;
      FAIL_VALIDATE)
        [[ "${worst}" == "PASS" || "${worst}" == "NO_VALIDATOR_FOUND" ]] && worst="${status}"
        ;;
      NO_VALIDATOR_FOUND)
        [[ "${worst}" == "PASS" ]] && worst="${status}"
        ;;
    esac
  done

  echo "${worst}"
}

# Main validation entry point
# Detects stack, runs all applicable validators, returns structured result
validator_run() {
  local repo_root="${1:-.}"
  local change_type="${2:-}"

  # Detect tech stacks
  local -a stacks=()
  while IFS= read -r stack; do
    [[ -n "${stack}" ]] && stacks+=("${stack}")
  done < <(validator_detect_stack "${repo_root}")

  # Collect all validation results
  local -a all_results=()

  # Docs-only shortcut (Section 9.3)
  if [[ "${change_type}" == "docs_only" ]]; then
    while IFS= read -r r; do
      [[ -n "${r}" ]] && all_results+=("${r}")
    done < <(validator_run_docs "${repo_root}")
  else
    for stack in "${stacks[@]}"; do
      case "${stack}" in
        python)
          while IFS= read -r r; do
            [[ -n "${r}" ]] && all_results+=("${r}")
          done < <(validator_run_python "${repo_root}")
          ;;
        js|ts)
          while IFS= read -r r; do
            [[ -n "${r}" ]] && all_results+=("${r}")
          done < <(validator_run_js "${repo_root}")
          ;;
        shell)
          while IFS= read -r r; do
            [[ -n "${r}" ]] && all_results+=("${r}")
          done < <(validator_run_shell "${repo_root}")
          ;;
        docker)
          while IFS= read -r r; do
            [[ -n "${r}" ]] && all_results+=("${r}")
          done < <(validator_run_docker "${repo_root}")
          ;;
        sql|migration)
          while IFS= read -r r; do
            [[ -n "${r}" ]] && all_results+=("${r}")
          done < <(validator_run_sql "${repo_root}")
          ;;
      esac
    done
  fi

  # If no validators found at all
  if [[ ${#all_results[@]} -eq 0 ]]; then
    all_results+=('{"name":"none","status":"NO_VALIDATOR_FOUND","note":"no applicable validators detected"}')
  fi

  # Aggregate status
  local final_status
  final_status="$(validator_aggregate_status "${all_results[@]}")"

  # Build results JSON array
  local results_json="["
  local first=true
  for r in "${all_results[@]}"; do
    ${first} || results_json="${results_json},"
    results_json="${results_json}${r}"
    first=false
  done
  results_json="${results_json}]"

  cat <<EOF
{
  "validation": {
    "status": "${final_status}",
    "stacks_detected": $(printf '%s\n' "${stacks[@]}" | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[\"${stacks[*]}\"]"),
    "results": ${results_json}
  }
}
EOF
}
