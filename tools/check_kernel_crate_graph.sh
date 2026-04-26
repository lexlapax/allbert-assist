#!/usr/bin/env bash
set -euo pipefail

mode="${1:-report}"
if [[ "$mode" != "report" && "$mode" != "--report" && "$mode" != "enforce" && "$mode" != "--enforce" ]]; then
  echo "usage: tools/check_kernel_crate_graph.sh [report|--report|enforce|--enforce]" >&2
  exit 2
fi

enforce=0
if [[ "$mode" == "enforce" || "$mode" == "--enforce" ]]; then
  enforce=1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

failures=0

check_manifest_for() {
  local label="$1"
  local manifest="$2"
  local pattern="$3"
  local description="$4"

  if [[ ! -f "$manifest" ]]; then
    echo "${label}: ${manifest} not present yet"
    return
  fi

  if rg -n "$pattern" "$manifest"; then
    echo "${label}: ${description}"
    if (( enforce == 1 )); then
      failures=$((failures + 1))
    fi
  else
    echo "${label}: ok"
  fi
}

echo "kernel crate graph check mode: $([[ $enforce -eq 1 ]] && echo enforce || echo report)"

check_manifest_for \
  "core -> services/retired" \
  "crates/allbert-kernel-core/Cargo.toml" \
  '^[[:space:]]*allbert-kernel-services[[:space:]]*=|package[[:space:]]*=[[:space:]]*"allbert-kernel-services"|^[[:space:]]*allbert-kernel[[:space:]]*=|package[[:space:]]*=[[:space:]]*"allbert-kernel"|allbert_kernel_services|allbert_kernel\b' \
  "core must not depend on services or the retired monolith"

check_manifest_for \
  "services -> retired" \
  "crates/allbert-kernel-services/Cargo.toml" \
  '^[[:space:]]*allbert-kernel[[:space:]]*=|package[[:space:]]*=[[:space:]]*"allbert-kernel"|allbert_kernel\b' \
  "services must not depend on the retired monolith"

retired_manifest_ref='allbert-kernel([^A-Za-z0-9_-]|$)'
if rg -n "$retired_manifest_ref" Cargo.toml crates/*/Cargo.toml; then
  echo "workspace still references allbert-kernel"
  if (( enforce == 1 )); then
    failures=$((failures + 1))
  fi
else
  echo "workspace has no allbert-kernel manifest references"
fi

if (( failures > 0 )); then
  echo "kernel crate graph check failed with ${failures} violation(s)" >&2
  exit 1
fi
