#!/usr/bin/env sh
# Allbert uninstaller (v0.62 M2). Removes only the files the install manifest
# recorded. Allbert Home (~/.allbert) is preserved unless --purge is passed.
set -eu

main() {
  PREFIX="${ALLBERT_PREFIX:-$HOME/.local}"
  LIB_DIR="$PREFIX/lib/allbert"
  MANIFEST="$LIB_DIR/.install-manifest"
  PURGE=0
  for arg in "$@"; do
    [ "$arg" = "--purge" ] && PURGE=1
  done

  if [ -f "$MANIFEST" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] && rm -rf "$path"
    done < "$MANIFEST"
    echo "allbert: removed installed files."
  else
    echo "allbert: no install manifest at $MANIFEST — nothing to remove." >&2
  fi

  if [ "$PURGE" -eq 1 ]; then
    home="${ALLBERT_HOME:-$HOME/.allbert}"
    rm -rf "$home"
    echo "allbert: --purge removed Allbert Home ($home)."
  else
    echo "allbert: Allbert Home preserved. Re-run with --purge to remove your data."
  fi
}

main "$@"
