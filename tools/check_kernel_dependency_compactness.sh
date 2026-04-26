#!/usr/bin/env bash
set -euo pipefail

mode="${1:-report}"
if [[ "$mode" != "report" && "$mode" != "--report" && "$mode" != "enforce" && "$mode" != "--enforce" ]]; then
  echo "usage: tools/check_kernel_dependency_compactness.sh [report|--report|enforce|--enforce]" >&2
  exit 2
fi

enforce=0
if [[ "$mode" == "enforce" || "$mode" == "--enforce" ]]; then
  enforce=1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

core_manifest="crates/allbert-kernel-core/Cargo.toml"
services_manifest="crates/allbert-kernel-services/Cargo.toml"
forbidden_core='^[[:space:]]*(reqwest|tantivy|mlua|tracing-subscriber|tracing-appender|pulldown-cmark|serde_yaml|flate2|base64|tempfile|libc)[[:space:]]*='
retired_kernel='^[[:space:]]*allbert-kernel[[:space:]]*=|package[[:space:]]*=[[:space:]]*"allbert-kernel"|allbert_kernel\b'
services_dependency='^[[:space:]]*allbert-kernel-services[[:space:]]*=|package[[:space:]]*=[[:space:]]*"allbert-kernel-services"|allbert_kernel_services\b'
failures=0

normal_dependencies() {
  local manifest="$1"
  awk '
    /^\[dependencies\]$/ { in_deps = 1; next }
    /^\[/ { in_deps = 0 }
    in_deps { print }
  ' "$manifest"
}

echo "kernel dependency compactness check mode: $([[ $enforce -eq 1 ]] && echo enforce || echo report)"

if [[ ! -f "$core_manifest" ]]; then
  echo "core manifest not present yet: ${core_manifest}"
  if (( enforce == 1 )); then
    failures=$((failures + 1))
  fi
else
  echo "checking core forbidden normal dependencies"
  if normal_dependencies "$core_manifest" | rg -n "$forbidden_core"; then
    echo "core owns forbidden concrete-service dependencies"
    if (( enforce == 1 )); then
      failures=$((failures + 1))
    fi
  else
    echo "core forbidden dependency check: ok"
  fi

  if normal_dependencies "$core_manifest" | rg -n "$services_dependency"; then
    echo "core depends on services"
    if (( enforce == 1 )); then
      failures=$((failures + 1))
    fi
  else
    echo "core -> services dependency check: ok"
  fi
fi

if [[ ! -f "$services_manifest" ]]; then
  echo "services manifest not present yet: ${services_manifest}"
  if (( enforce == 1 )); then
    failures=$((failures + 1))
  fi
else
  echo "checking services retired-monolith dependency"
  if normal_dependencies "$services_manifest" | rg -n "$retired_kernel"; then
    echo "services depends on retired allbert-kernel"
    if (( enforce == 1 )); then
      failures=$((failures + 1))
    fi
  else
    echo "services retired dependency check: ok"
  fi
fi

if (( failures > 0 )); then
  echo "kernel dependency compactness check failed with ${failures} violation(s)" >&2
  exit 1
fi
