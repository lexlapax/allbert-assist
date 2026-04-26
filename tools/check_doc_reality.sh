#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

failures=()

add_failure() {
  failures+=("$1")
}

has_doc_ack() {
  local pattern="$1"
  rg -q "$pattern" docs README.md CHANGELOG.md
}

check_required_ack() {
  local code_pattern="$1"
  local ack_pattern="$2"
  local label="$3"

  if rg -q "$code_pattern" crates; then
    if ! has_doc_ack "$ack_pattern"; then
      add_failure "$label is present in code but has no matching doc acknowledgement."
    fi
  fi
}

check_overclaim_context() {
  local docs
  docs="$(rg -n --glob '*.md' \
    'adapter daemon protocol is shipped|adapter protocol is shipped|real-backend adapter training is shipped|real backend training is shipped|self-diagnosis remediation is shipped|diagnosis remediation is shipped|production training uses the configured backend|remediation produces concrete candidates' \
    docs README.md CHANGELOG.md || true)"

  if [[ -z "$docs" ]]; then
    return
  fi

  while IFS=: read -r file line _rest; do
    [[ -n "${file:-}" && -n "${line:-}" ]] || continue
    local start=$(( line > 5 ? line - 5 : 1 ))
    local end=$(( line + 5 ))
    local window
    window="$(sed -n "${start},${end}p" "$file")"
    if ! printf '%s\n' "$window" | rg -q 'partial as of v0\.[0-9]+|planned for v0\.[0-9]+(\.[0-9]+)?|reconciled in v0\.[0-9]+(\.[0-9]+)?|scaffolded|Status: Stub'; then
      add_failure "Possible unqualified overclaim at ${file}:${line}"
    fi
  done <<< "$docs"
}

check_roadmap_statuses() {
  local roadmap="docs/plans/roadmap.md"
  while IFS='|' read -r _ release _focus status plan _rest; do
    release="$(printf '%s' "$release" | xargs)"
    status="$(printf '%s' "$status" | xargs)"
    plan="$(printf '%s' "$plan" | sed -E 's/.*\(([^)]+)\).*/\1/' | xargs)"

    [[ "$release" =~ ^v ]] || continue
    [[ -n "$plan" && "$plan" != "$status" ]] || continue

    local plan_path="docs/plans/$plan"
    if [[ ! -f "$plan_path" ]]; then
      add_failure "Roadmap row $release points to missing plan $plan_path"
      continue
    fi

    local plan_status
    plan_status="$(rg -n '^Status:' "$plan_path" | head -n 1 | cut -d: -f3- | xargs || true)"
    if [[ "$status" == "Shipped" && "$plan_status" != "Shipped" ]]; then
      add_failure "Roadmap row $release is Shipped but $plan_path says Status: ${plan_status:-<missing>}"
    fi
    if [[ "$status" == "Draft" && "$plan_status" != "Draft" ]]; then
      add_failure "Roadmap row $release is Draft but $plan_path says Status: ${plan_status:-<missing>}"
    fi
    if [[ "$status" == "Stub" && "$plan_status" != "Stub" ]]; then
      add_failure "Roadmap row $release is Stub but $plan_path says Status: ${plan_status:-<missing>}"
    fi
  done < "$roadmap"
}

check_required_ack 'adapter_surface_not_implemented' 'partial as of v0\.14; tracked by v0\.14\.1' 'adapter_surface_not_implemented'
check_required_ack 'unimplemented!|todo!|_not_implemented' 'not implemented|planned for v0\.|partial as of v0\.|Status: Stub' 'code escape hatch'
check_required_ack 'FakeAdapterTrainer' 'FakeAdapterTrainer|fake backend|explicit fake backend' 'FakeAdapterTrainer'

check_overclaim_context
check_roadmap_statuses

if (( ${#failures[@]} > 0 )); then
  printf 'doc-reality check failed:\n' >&2
  for failure in "${failures[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi

printf 'doc-reality check passed\n'
