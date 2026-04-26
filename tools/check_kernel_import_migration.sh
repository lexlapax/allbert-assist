#!/usr/bin/env bash
set -euo pipefail

mode="${1:-report}"
if [[ "$mode" != "report" && "$mode" != "--report" && "$mode" != "enforce" && "$mode" != "--enforce" ]]; then
  echo "usage: tools/check_kernel_import_migration.sh [report|--report|enforce|--enforce]" >&2
  exit 2
fi

enforce=0
if [[ "$mode" == "enforce" || "$mode" == "--enforce" ]]; then
  enforce=1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

pattern='allbert_kernel\b|allbert-kernel([^A-Za-z0-9_-]|$)|crates/allbert-kernel([^A-Za-z0-9_-]|$)'

echo "kernel import migration check mode: $([[ $enforce -eq 1 ]] && echo enforce || echo report)"

if (( enforce == 1 )); then
  if rg -n "$pattern" crates Cargo.toml Cargo.lock; then
    echo "retired allbert-kernel references remain in workspace code/manifests" >&2
    exit 1
  fi
  echo "no retired allbert-kernel references in workspace code/manifests"
  exit 0
fi

if rg -n "$pattern" crates Cargo.toml Cargo.lock; then
  echo "report-only: references above must be migrated before v0.14.2 release exit"
else
  echo "no retired allbert-kernel references in workspace code/manifests"
fi
