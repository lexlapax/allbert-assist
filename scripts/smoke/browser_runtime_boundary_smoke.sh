#!/usr/bin/env bash
# v1.0.4 — prove browser runtimes are host dependencies, not artifact payload.
# Usage: browser_runtime_boundary_smoke.sh <extracted-release-root>
set -euo pipefail

REL_ROOT_ARG="${1:?usage: browser_runtime_boundary_smoke.sh <release-root>}"
REL_ROOT="$(cd "$REL_ROOT_ARG" && pwd)"
BRIDGE="$REL_ROOT/plugins/allbert.browser/priv/playwright_bridge"

fail() {
  echo "browser-runtime-boundary:$1 FAIL $2"
  exit 1
}

[ -f "$BRIDGE/bridge.js" ] || fail bridge "missing Allbert bridge source"
[ -f "$BRIDGE/package.json" ] || fail bridge "missing reviewed dependency manifest"
[ -f "$BRIDGE/package-lock.json" ] || fail bridge "missing reviewed dependency lock"

FORBIDDEN="$(
  find "$REL_ROOT" -type d \
    \( -name node_modules -o -name .local-browsers \) \
    -print -quit 2>/dev/null || true
)"

[ -z "$FORBIDDEN" ] || \
  fail external "found $FORBIDDEN; Node, Playwright, and Chromium must be supplied by the host"

FORBIDDEN_EXECUTABLE="$(
  find "$REL_ROOT" -type f \
    \( -name node -o -name node.exe -o -name chromium -o \
       -name chromium-browser -o -name chrome -o -name headless_shell \) \
    -perm -111 -print -quit 2>/dev/null || true
)"

[ -z "$FORBIDDEN_EXECUTABLE" ] || \
  fail external "found executable $FORBIDDEN_EXECUTABLE; host runtimes may not be staged"

echo "browser-runtime-boundary:external PASS artifact contains no Node package tree or browser payload"
