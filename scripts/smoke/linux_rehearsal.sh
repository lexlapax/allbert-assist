#!/usr/bin/env bash
# v0.62 M8.13 — Linux install/serve/service/vault rehearsal.
#
# The macOS equivalent runs interactively; this scripts the Linux path so CI (and
# an operator on a real Linux host) can exercise it. It installs the built
# artifact through the curl installer's symlink path, smokes the CLI, and — where
# the environment allows — rehearses the Secret Service vault and the systemd
# --user service. The install + CLI smoke are HARD assertions; the keyring and
# systemd steps degrade gracefully (logging SKIP) since headless runners/hosts may
# lack a D-Bus keyring daemon or a user systemd instance — exactly the documented
# fallback behaviour.
#
# Usage: linux_rehearsal.sh <extracted-release-root>
#   <release-root>  dir containing bin/allbert (the unpacked tarball's `allbert/`)
set -uo pipefail

REL_ROOT_ARG="${1:?usage: linux_rehearsal.sh <extracted-release-root>}"
REL_ROOT="$(cd "$REL_ROOT_ARG" && pwd)"
PORT="${REHEARSAL_PORT:-4199}"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
PREFIX="$WORK/prefix"
HOME_DIR="$WORK/home"
mkdir -p "$STAGE" "$HOME_DIR"
cleanup() { [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo "linux-rehearsal:$1 FAIL ${2:-}"; exit 1; }
skip() { echo "linux-rehearsal:$1 SKIP ${2:-}"; }

# v0.62 M8.17: derive the target from the runner arch (matches install.sh) so the
# rehearsal is correct on both linux-x64 and linux-arm64 runners.
case "$(uname -m)" in
  x86_64)  TARGET="linux-x64" ;;
  aarch64) TARGET="linux-arm64" ;;
  *)       fail arch "unsupported Linux arch $(uname -m)" ;;
esac

# 1) Install via the curl installer's symlink path (local file:// base).
tar -czf "$STAGE/allbert-${TARGET}.tar.gz" -C "$(dirname "$REL_ROOT")" "$(basename "$REL_ROOT")"
( cd "$STAGE" && sha256sum "allbert-${TARGET}.tar.gz" > SHA256SUMS )
ALLBERT_BASE_URL="file://$STAGE" ALLBERT_VERSION="latest" ALLBERT_PREFIX="$PREFIX" \
  sh "$(dirname "$0")/../install/install.sh" >/dev/null 2>&1 || fail install "install.sh failed"
BIN="$PREFIX/bin/allbert"
[ -L "$BIN" ] || fail install "installed entry is not a symlink"
echo "linux-rehearsal:install PASS symlinked to $(readlink "$BIN")"

# 2) CLI smoke through the installed symlink (this is where the symlink-resolution
# bug the macOS rehearsal caught would resurface on Linux).
run() { env ALLBERT_HOME="$HOME_DIR" "$BIN" "$@"; }
VSN="$(run --version 2>/dev/null | tail -n1)"
case "$VSN" in allbert\ *) echo "linux-rehearsal:version PASS $VSN" ;; *) fail version "got '$VSN'" ;; esac
run admin status >"$WORK/status.out" 2>/dev/null || fail status "admin status non-zero"
echo "linux-rehearsal:status PASS admin status ok"

# 3) serve + /health + attach round-trip.
env ALLBERT_HOME="$HOME_DIR" PHX_SERVER=1 PORT="$PORT" "$BIN" serve >"$WORK/serve.out" 2>&1 &
SERVE_PID=$!
HEALTH_OK=""
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$PORT/health" >"$WORK/health.json" 2>/dev/null && { HEALTH_OK=1; break; }
  sleep 1
done
[ -n "$HEALTH_OK" ] && echo "linux-rehearsal:health PASS $(cat "$WORK/health.json")" \
  || { cat "$WORK/serve.out"; fail health "/health did not return 200"; }
env ALLBERT_HOME="$HOME_DIR" ALLBERT_ATTACH_DEBUG=1 "$BIN" admin status >/dev/null 2>"$WORK/attach.err"
grep -q "served by the running daemon" "$WORK/attach.err" \
  && echo "linux-rehearsal:attach PASS served by the running daemon" \
  || fail attach "second command did not attach"
kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; SERVE_PID=""

# 4) Secret Service vault (tier 1 Linux). Requires secret-tool + a reachable
# D-Bus keyring; otherwise the vault resolves to the encrypted-file tier (the
# documented headless fallback) — a SKIP here, not a failure.
if command -v secret-tool >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  ref="secret://providers/anthropic/api_key"
  if secret-tool store --label="allbert-rehearsal" service allbert-assist ref "$ref" <<<"sk-ci-rehearsal" 2>/dev/null; then
    got="$(secret-tool lookup service allbert-assist ref "$ref" 2>/dev/null)"
    [ "$got" = "sk-ci-rehearsal" ] && echo "linux-rehearsal:vault-mechanism PASS secret-tool round-trip" \
      || fail vault-mechanism "secret-tool lookup mismatch"
    secret-tool clear service allbert-assist ref "$ref" 2>/dev/null || true
  else
    skip vault-mechanism "secret-tool store failed (keyring not writable)"
  fi
  tier="$(run admin vault 2>/dev/null | grep -i "Vault tier" | head -1)"
  echo "linux-rehearsal:vault-tier ${tier:-<none>}"
  echo "$tier" | grep -qi "os" && echo "linux-rehearsal:vault PASS os tier reachable" \
    || skip vault "resolved to a non-os tier: ${tier:-<none>}"
else
  skip vault "no secret-tool / D-Bus session — encrypted-file tier is the headless fallback"
fi

# 5) systemd --user service surface. A real install needs a user systemd instance
# (loginctl linger); assert the command shape + dry-run, install for real only if
# a user manager answers.
if run admin service install --dry-run >"$WORK/svc.out" 2>/dev/null; then
  echo "linux-rehearsal:service-dry-run PASS $(grep -i would "$WORK/svc.out" | head -1)"
else
  skip service-dry-run "dry-run unavailable"
fi
if systemctl --user show-environment >/dev/null 2>&1; then
  echo "linux-rehearsal:service-manager PRESENT (user systemd reachable — real install is an operator step)"
else
  skip service-manager "no user systemd instance (loginctl enable-linger needed) — Service.manager_available? degrades to foreground serve"
fi

# 6) Uninstall preserves Allbert Home.
echo marker > "$HOME_DIR/rehearsal-marker"
ALLBERT_PREFIX="$PREFIX" ALLBERT_HOME="$HOME_DIR" sh "$(dirname "$0")/../install/uninstall.sh" >/dev/null 2>&1 || fail uninstall "uninstall.sh failed"
[ -e "$BIN" ] && fail uninstall "binary still present" || echo "linux-rehearsal:uninstall PASS binary removed"
[ -f "$HOME_DIR/rehearsal-marker" ] && echo "linux-rehearsal:home-preserved PASS" || fail home-preserved "Allbert Home was removed"

echo "linux-rehearsal:all DONE (hard checks passed; keyring/systemd steps as reported above)"
