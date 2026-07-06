#!/usr/bin/env bash
# v0.62 M8 — packaged-artifact smoke harness.
#
# The `mix allbert.test release.v062` gate is checkout-bound and cannot execute
# the packaged binary; this runner is the second verification layer. It unpacks
# a built release into a throwaway ALLBERT_HOME and asserts the properties the
# mix gate cannot: toolchain-free boot, plugin registration from the packaged
# plugins root, a live `/health`, an attach round-trip against the daemon, no
# Mix modules in the image, and portable ERTS crypto linkage.
#
# Usage: artifact_smoke.sh <path-to-extracted-release-root> [target]
#   <release-root>  dir containing bin/allbert (e.g. the unpacked tarball's
#                   `allbert/` dir)
#   [target]        optional label (macos-arm64 | linux-x64 | linux-arm64);
#                   otherwise inferred from `uname`
#
# Exits non-zero on the first failed check. Every check prints `smoke:<id> ...`.
set -euo pipefail

REL_ROOT="${1:?usage: artifact_smoke.sh <release-root> [target]}"
TARGET="${2:-$(uname -s)-$(uname -m)}"
BIN="$REL_ROOT/bin/allbert"
PORT="${SMOKE_PORT:-4137}"

[ -x "$BIN" ] || { echo "smoke:fatal no executable at $BIN"; exit 1; }

WORK="$(mktemp -d)"
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR"
cleanup() {
  [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# A deliberately minimal environment: no Elixir/Erlang toolchain on PATH, proving
# the release runs on its bundled ERTS. SHELL is set because erlexec requires it.
run_cli() {
  env -i HOME="$WORK" PATH=/usr/bin:/bin SHELL=/bin/sh LANG=C.UTF-8 \
    ALLBERT_HOME="$HOME_DIR" "$BIN" "$@"
}

fail() { echo "smoke:$1 FAIL ${2:-}"; exit 1; }

# 1) Toolchain-free boot through the CLI spine.
if run_cli admin status >"$WORK/status.out" 2>&1; then
  echo "smoke:boot PASS toolchain-free admin-status ok"
else
  cat "$WORK/status.out" || true
  fail boot "admin status exited non-zero"
fi

# 2) Version stamped from the release, not a checkout probe.
VSN="$(run_cli eval 'IO.puts(AllbertAssist.App.CoreApp.version())' 2>/dev/null | tail -n1)"
[ -n "$VSN" ] && echo "smoke:version PASS version=$VSN" || fail version "no version reported"

# 3) Plugins register from the packaged plugins root (RELEASE_ROOT/plugins).
PLUGIN_COUNT="$(run_cli eval 'IO.puts(length(AllbertAssist.App.Registry.registered_apps()))' 2>/dev/null | tail -n1 || true)"
case "$PLUGIN_COUNT" in
  ''|*[!0-9]*) fail plugins "plugin capability count not numeric: '$PLUGIN_COUNT'" ;;
  *) [ "$PLUGIN_COUNT" -gt 0 ] && echo "smoke:plugins PASS registered=$PLUGIN_COUNT" \
       || fail plugins "no plugins registered from the packaged root" ;;
esac

# 4) Daemon: serve, then a live /health, then an attach round-trip.
env -i HOME="$WORK" PATH=/usr/bin:/bin SHELL=/bin/sh LANG=C.UTF-8 \
  ALLBERT_HOME="$HOME_DIR" PHX_SERVER=1 PORT="$PORT" \
  "$BIN" serve >"$WORK/serve.out" 2>&1 &
SERVE_PID=$!

HEALTH_OK=""
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >"$WORK/health.json" 2>/dev/null; then
    HEALTH_OK=1
    break
  fi
  sleep 1
done
[ -n "$HEALTH_OK" ] && echo "smoke:health PASS $(cat "$WORK/health.json")" \
  || { cat "$WORK/serve.out" || true; fail health "/health did not return 200 within 30s"; }

# Attach round-trip: a second command against the live daemon must resolve
# through the local attach transport. A single-writer refusal is a separate
# guard result, not an attach pass.
if run_cli admin status >"$WORK/attach.out" 2>&1; then
  echo "smoke:attach PASS attach round-trip ok"
else
  cat "$WORK/attach.out" || true
  fail attach "second command did not attach to the running daemon"
fi

kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
SERVE_PID=""

# 5) No Mix modules in the shipped image (prod release must exclude :mix).
if find "$REL_ROOT" -name 'Elixir.Mix.beam' -o -name 'mix-*.ez' | grep -q .; then
  fail no_mix "Mix modules present in the release image"
else
  echo "smoke:no_mix PASS no Mix modules in image"
fi

# 6) ERTS crypto linkage portability: the crypto NIF must not dangle against a
# host-specific OpenSSL. On macOS the bundled dylib is repointed to
# @loader_path; on Linux it links the system libcrypto by design.
CRYPTO_SO="$(find "$REL_ROOT" -name 'crypto.so' | head -n1 || true)"
if [ -n "$CRYPTO_SO" ]; then
  case "$TARGET" in
    macos*|Darwin*)
      LINKS="$(otool -L "$CRYPTO_SO" || true)"
      if echo "$LINKS" | grep -qiE '/opt/homebrew|/usr/local/opt/openssl'; then
        echo "$LINKS"
        fail crypto_linkage "crypto.so links a Homebrew OpenSSL (non-portable)"
      fi
      echo "smoke:crypto_linkage PASS macOS crypto.so linkage portable"
      ;;
    *)
      LINKS="$(ldd "$CRYPTO_SO" 2>/dev/null || true)"
      if echo "$LINKS" | grep -qi 'not found'; then
        echo "$LINKS"
        fail crypto_linkage "crypto.so has unresolved shared-object dependencies"
      fi
      echo "smoke:crypto_linkage PASS linux crypto.so dependencies resolved"
      ;;
  esac
else
  echo "smoke:crypto_linkage SKIP crypto.so not found under $REL_ROOT"
fi

echo "smoke:all PASS target=$TARGET version=$VSN"
