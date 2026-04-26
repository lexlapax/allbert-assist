#!/usr/bin/env bash
set -euo pipefail

mode="${1:-report}"
if [[ "$mode" != "report" && "$mode" != "--report" && "$mode" != "enforce" && "$mode" != "--enforce" ]]; then
  echo "usage: tools/check_kernel_size.sh [report|--report|enforce|--enforce]" >&2
  exit 2
fi

enforce=0
if [[ "$mode" == "enforce" || "$mode" == "--enforce" ]]; then
  enforce=1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

failures=0

count_rs_loc() {
  local path="$1"
  if [[ -f "$path" ]]; then
    wc -l <"$path" | tr -d ' '
  elif [[ -d "$path" ]]; then
    find "$path" -type f -name '*.rs' -print0 | xargs -0 cat 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

report_limit() {
  local label="$1"
  local path="$2"
  local limit="$3"
  local loc
  loc="$(count_rs_loc "$path")"
  printf '%-46s %7s LOC' "$label" "$loc"
  if [[ "$limit" != "none" ]]; then
    printf '  limit <%s' "$limit"
    if (( enforce == 1 && loc >= limit )); then
      printf '  FAIL'
      failures=$((failures + 1))
    fi
  fi
  printf '\n'
}

echo "kernel size check mode: $([[ $enforce -eq 1 ]] && echo enforce || echo report)"
report_limit "current allbert-kernel src/" "crates/allbert-kernel/src" "none"
report_limit "current allbert-kernel lib.rs" "crates/allbert-kernel/src/lib.rs" "none"
report_limit "future allbert-kernel-core src/" "crates/allbert-kernel-core/src" "20000"
report_limit "future allbert-kernel-core lib.rs" "crates/allbert-kernel-core/src/lib.rs" "4000"
report_limit "future allbert-kernel-services src/" "crates/allbert-kernel-services/src" "30000"

if [[ -d "crates/allbert-kernel" ]]; then
  echo "retired crate presence: crates/allbert-kernel exists"
  if (( enforce == 1 )); then
    failures=$((failures + 1))
  fi
else
  echo "retired crate presence: crates/allbert-kernel absent"
fi

if (( failures > 0 )); then
  echo "kernel size check failed with ${failures} violation(s)" >&2
  exit 1
fi

