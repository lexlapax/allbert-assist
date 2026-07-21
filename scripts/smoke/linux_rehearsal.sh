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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
PREFIX="$WORK/prefix"
HOME_DIR="$WORK/home"
mkdir -p "$STAGE" "$HOME_DIR"
cleanup() { [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo "linux-rehearsal:$1 FAIL ${2:-}"; exit 1; }
skip() { echo "linux-rehearsal:$1 SKIP ${2:-}"; }

if [ "$(id -u)" -eq 0 ]; then
  fail user "run as a non-root user; erlexec refuses root startup without an effective user"
fi

# v0.62 M8.17: derive the target from the runner arch (matches install.sh) so the
# rehearsal is correct on both linux-x64 and linux-arm64 runners.
case "$(uname -m)" in
  x86_64)  TARGET="linux-x64" ;;
  aarch64) TARGET="linux-arm64" ;;
  *)       fail arch "unsupported Linux arch $(uname -m)" ;;
esac

# 1) CI signs a local checksum with GitHub OIDC and exercises the real installer.
# Published-container rehearsal receives a stage whose bundle was already
# verified by the host command in the operator runbook. It re-checks the exact
# SHA256 row inside the container, then reproduces the install layout directly;
# this avoids adding a signature-verification bypass to install.sh or bootstrapping
# an unverified Linux cosign binary inside the container.
if [ -n "${ALLBERT_REHEARSAL_PREVERIFIED_STAGE:-}" ]; then
  STAGE="$(cd "$ALLBERT_REHEARSAL_PREVERIFIED_STAGE" && pwd)"
  VERSION="${ALLBERT_REHEARSAL_VERSION:?set ALLBERT_REHEARSAL_VERSION (for example v1.0.4)}"
  VERSION="v${VERSION#v}"
  ARTIFACT="allbert-${VERSION}-${TARGET}.tar.gz"
  [ -f "$STAGE/$ARTIFACT" ] || fail install-preverified "missing $STAGE/$ARTIFACT"
  [ -f "$STAGE/SHA256SUMS" ] || fail install-preverified "missing SHA256SUMS"
  expected="$(awk -v f="$ARTIFACT" '$2 == f {print $1}' "$STAGE/SHA256SUMS")"
  [ -n "$expected" ] || fail install-preverified "no exact checksum row for $ARTIFACT"
  actual="$(sha256sum "$STAGE/$ARTIFACT" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || fail install-preverified "checksum mismatch"

  LIB_DIR="$PREFIX/lib/allbert"
  mkdir -p "$LIB_DIR" "$PREFIX/bin"
  tar -xzf "$STAGE/$ARTIFACT" -C "$LIB_DIR" --strip-components=1
  ln -sf "$LIB_DIR/bin/allbert" "$PREFIX/bin/allbert"
  {
    echo "$LIB_DIR"
    echo "$PREFIX/bin/allbert"
  } >"$LIB_DIR/.install-manifest"
  echo "linux-rehearsal:install-preverified PASS exact published checksum and install layout"
else
  tar -czf "$STAGE/allbert-${TARGET}.tar.gz" -C "$(dirname "$REL_ROOT")" "$(basename "$REL_ROOT")"
  ( cd "$STAGE" && sha256sum "allbert-${TARGET}.tar.gz" > SHA256SUMS )
  if [ "${ALLBERT_REHEARSAL_SIGN_CHECKSUMS:-}" = "1" ]; then
    command -v cosign >/dev/null 2>&1 || fail install "cosign unavailable for local checksum signing"
    ( cd "$STAGE" && cosign sign-blob --yes --bundle SHA256SUMS.cosign.bundle SHA256SUMS >/dev/null ) \
      || fail install "failed to sign local SHA256SUMS"
  fi
  if ! ALLBERT_BASE_URL="file://$STAGE" ALLBERT_VERSION="latest" ALLBERT_PREFIX="$PREFIX" \
    sh "$(dirname "$0")/../install/install.sh" >"$WORK/install.out" 2>&1; then
    cat "$WORK/install.out"
    fail install "install.sh failed"
  fi
fi
BIN="$PREFIX/bin/allbert"
[ -L "$BIN" ] || fail install "installed entry is not a symlink"
echo "linux-rehearsal:install PASS symlinked to $(readlink "$BIN")"

# 2) CLI smoke through the installed symlink (this is where the symlink-resolution
# bug the macOS rehearsal caught would resurface on Linux).
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -x "$NODE_BIN" ] || fail browser-doctor "node host prerequisite unavailable"
NODE_MAJOR="$($NODE_BIN -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 18 ] || fail browser-doctor "Node >=18 required; found major $NODE_MAJOR"
RUNTIME_BIN="$WORK/runtime-bin"
PACKAGE_MANAGER_AUDIT="$WORK/package-manager.audit"
mkdir -p "$RUNTIME_BIN"
ln -sf "$NODE_BIN" "$RUNTIME_BIN/node"
for package_manager in npm npx apt apt-get brew dnf pacman yum; do
  {
    echo '#!/bin/sh'
    echo 'printf "%s\n" "$(basename "$0") $*" >> "$ALLBERT_PACKAGE_MANAGER_AUDIT"'
    echo 'exit 97'
  } > "$RUNTIME_BIN/$package_manager"
  chmod +x "$RUNTIME_BIN/$package_manager"
done

run() {
  env HOME="$WORK" ALLBERT_HOME="$HOME_DIR" \
    PATH="$RUNTIME_BIN:/usr/bin:/bin" \
    NODE_PATH="${PLAYWRIGHT_NODE_PATH:-}" \
    PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-}" \
    ALLBERT_PACKAGE_MANAGER_AUDIT="$PACKAGE_MANAGER_AUDIT" \
    "$BIN" "$@"
}
VSN="$(run --version 2>/dev/null | tail -n1)"
case "$VSN" in allbert\ *) echo "linux-rehearsal:version PASS $VSN" ;; *) fail version "got '$VSN'" ;; esac
run admin status >"$WORK/status.out" 2>/dev/null || fail status "admin status non-zero"
echo "linux-rehearsal:status PASS admin status ok"

# 2a) v1.0.4: Node, Playwright, and Chromium are explicit host dependencies.
# The artifact carries only the reviewed Allbert bridge/manifests; it may not
# carry a Node package tree or browser payload.
bash "$SCRIPT_DIR/browser_runtime_boundary_smoke.sh" "$REL_ROOT" || \
  fail browser-external-runtime "artifact contains a forbidden browser runtime"
echo "linux-rehearsal:browser-external-runtime PASS no runtime bundled"

PLAYWRIGHT_NODE_PATH="${PLAYWRIGHT_NODE_PATH:?set PLAYWRIGHT_NODE_PATH to the host package directory containing playwright}"
BROWSER_BINARY_PATH="${BROWSER_BINARY_PATH:?set BROWSER_BINARY_PATH to the host Chromium/Chrome executable}"
[ -f "$PLAYWRIGHT_NODE_PATH/playwright/package.json" ] || \
  fail browser-doctor "host Playwright package missing below PLAYWRIGHT_NODE_PATH=$PLAYWRIGHT_NODE_PATH"
[ -x "$BROWSER_BINARY_PATH" ] || \
  fail browser-doctor "host Chromium executable unavailable at BROWSER_BINARY_PATH=$BROWSER_BINARY_PATH"
run admin settings set browser.driver.binary_path "$BROWSER_BINARY_PATH" >/dev/null
run admin settings set browser.driver.node_path "$NODE_BIN" >/dev/null
run admin settings set browser.driver.node_module_path "$PLAYWRIGHT_NODE_PATH" >/dev/null
run admin settings set browser.driver.version_pin 1.58.2 >/dev/null
# Hosted release runners can take longer than the 30-second interactive default
# to start an OS Chromium process. Bound only this disposable rehearsal Home at
# 60 seconds; the live doctor and exact-version assertions remain mandatory.
run admin settings set browser.navigation.timeout_ms 60000 >/dev/null

if browser_doctor="$(run eval 'Application.ensure_all_started(:allbert_assist); case AllbertAssist.Actions.Runner.run("browser_doctor", %{}, %{actor: "linux-rehearsal", channel: :cli}) do {:ok, %{doctor: %{live_check_status: :ok, details: %{playwright_version: "1.58.2"}}}} -> IO.puts("packaged-browser-doctor-ok"); other -> IO.inspect(other); System.halt(1) end' 2>&1)"; then
  echo "$browser_doctor" >"$WORK/browser-doctor.out"
  grep -q 'packaged-browser-doctor-ok' "$WORK/browser-doctor.out" || \
    fail browser-doctor "doctor did not emit the success marker"
  echo "linux-rehearsal:browser-doctor PASS host Playwright 1.58.2 and OS Chromium about:blank launch"
else
  echo "$browser_doctor"
  fail browser-doctor "packaged browser doctor failed"
fi

if [ -s "$PACKAGE_MANAGER_AUDIT" ]; then
  cat "$PACKAGE_MANAGER_AUDIT"
  fail browser-no-download "runtime attempted a package-manager invocation"
elif [ -e "$WORK/.cache/ms-playwright" ] || [ -e "$WORK/Library/Caches/ms-playwright" ]; then
  fail browser-no-download "doctor created a default Playwright browser cache"
else
  echo "linux-rehearsal:browser-no-download PASS no package-manager invocation or default browser cache"
fi

# 2b) v0.63 M8.8: bare / first-run command through the packaged `eval` dispatch — the
# path that crashed with `unknown registry: Req.Finch` (eval loads-but-does-not-start OTP
# apps, so the first-model probe's Req.Finch pool was absent). `admin status` above
# initialised the Home DB; mark onboarding complete so `detect` reaches the localhost
# probe, then assert bare `allbert` runs it without the registry crash.
printf '{"onboarding_complete": true, "profile_reviewed": true}' > "$HOME_DIR/onboarding.json"
run >"$WORK/firstrun.out" 2>&1 || true
if grep -q "unknown registry: Req.Finch" "$WORK/firstrun.out"; then
  cat "$WORK/firstrun.out"; fail first-run-eval "bare allbert crashed on Req.Finch (eval did not start :req)"
fi
echo "linux-rehearsal:first-run-eval PASS bare allbert ran the first-model probe with no Req.Finch crash"
rm -f "$HOME_DIR/onboarding.json"

# 2c) v0.63 M8.8: a CA trust store must ship in the release so hosted-provider HTTPS works
# on a host with an empty/unloadable OS store (bundled castore fallback).
if ls "$REL_ROOT"/lib/castore-*/priv/cacerts.pem >/dev/null 2>&1; then
  echo "linux-rehearsal:castore-bundled PASS CA bundle ships in the release"
else
  fail castore-bundled "no bundled castore cacerts.pem in the release (hosted TLS fails offline)"
fi

# 2d) v0.63 M8.8: hosted-provider doctor through the eval path must not raise the
# castore/CA-trust error. Best-effort — SKIP when no hosted profile is configured (no key
# in CI). A 401/403 or endpoint error is acceptable; we fail only on the castore/CA crash.
run admin models doctor openai >"$WORK/doctor.out" 2>&1 || true
if grep -qiE "castore|default CA trust store" "$WORK/doctor.out"; then
  cat "$WORK/doctor.out"; fail hosted-doctor-eval "doctor hit the castore/CA-trust error"
elif grep -qiE "unknown|no such profile|not.*configured|no.*provider" "$WORK/doctor.out"; then
  skip hosted-doctor-eval "no hosted profile configured (set one with a key to exercise TLS)"
else
  echo "linux-rehearsal:hosted-doctor-eval PASS no castore/CA error on the hosted doctor path"
fi

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
