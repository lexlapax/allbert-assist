#!/usr/bin/env bash
# Build and smoke one v1.3 release target from the current exact checkout.
# GitHub draft creation, SSH/Docker transport, upload, and promotion stay in the
# operator request flow; this helper emits only the four files named below.
set -Eeuo pipefail
export LC_ALL=C.UTF-8
export MIX_ENV=prod
umask 077

TARGET="${1:?usage: build_candidate.sh TARGET OUTPUT_DIR}"
OUTPUT_DIR="${2:?usage: build_candidate.sh TARGET OUTPUT_DIR}"
EXPECTED_SHA="${ALLBERT_EXPECTED_SHA:?set ALLBERT_EXPECTED_SHA}"
GENERATION="${ALLBERT_CANDIDATE_GENERATION:?set ALLBERT_CANDIDATE_GENERATION}"
BUILDER_CLASS="${ALLBERT_BUILDER_CLASS:?set ALLBERT_BUILDER_CLASS}"
PLAYWRIGHT_NODE_PATH="${PLAYWRIGHT_NODE_PATH:?set PLAYWRIGHT_NODE_PATH}"
BROWSER_BINARY_PATH="${BROWSER_BINARY_PATH:?set BROWSER_BINARY_PATH}"

OTP_VERSION="29.0.1"
ELIXIR_VERSION="1.19.5"
HEX_VERSION="2.5.1"
REBAR3_VERSION="3.25.1"
TARGETS="linux-arm64 linux-x64 macos-arm64"

fail() {
  echo "candidate-build: FAIL $*" >&2
  exit 1
}

[ "$(id -u)" -ne 0 ] || fail "candidate build and smoke must run as a non-root user"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

case " $TARGETS " in
  *" $TARGET "*) ;;
  *) fail "unsupported target $TARGET" ;;
esac
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "expected SHA must be 40 lowercase hex characters"
[[ "$GENERATION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "invalid candidate generation"

[ -d "$OUTPUT_DIR" ] || fail "output directory does not exist"
[ ! -L "$OUTPUT_DIR" ] || fail "output directory must not be a symlink"
[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "output directory must be empty"
[ -f "$PLAYWRIGHT_NODE_PATH/playwright/package.json" ] || fail "Playwright package is unavailable"
[ -x "$BROWSER_BINARY_PATH" ] || fail "browser binary is unavailable"

SOURCE_SHA="$(git rev-parse HEAD)"
[ "$SOURCE_SHA" = "$EXPECTED_SHA" ] || fail "checkout SHA differs from the bound candidate SHA"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "tracked worktree is not clean"

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
case "$TARGET" in
  macos-arm64)
    [ "$HOST_OS" = Darwin ] && [ "$HOST_ARCH" = arm64 ] || fail "macos-arm64 requires Darwin/arm64"
    [ "$BUILDER_CLASS" = operator-macos ] || fail "macos-arm64 requires operator-macos builder class"
    ;;
  linux-x64)
    [ "$HOST_OS" = Linux ] && { [ "$HOST_ARCH" = x86_64 ] || [ "$HOST_ARCH" = amd64 ]; } ||
      fail "linux-x64 requires Linux/x86_64"
    [ "$BUILDER_CLASS" = native-linux ] || fail "linux-x64 requires native-linux builder class"
    ;;
  linux-arm64)
    [ "$HOST_OS" = Linux ] && { [ "$HOST_ARCH" = aarch64 ] || [ "$HOST_ARCH" = arm64 ]; } ||
      fail "linux-arm64 requires Linux/aarch64"
    [ "$BUILDER_CLASS" = docker-linux-arm64 ] || fail "linux-arm64 requires docker-linux-arm64 builder class"
    : "${ALLBERT_CONTAINER_IMAGE:?set ALLBERT_CONTAINER_IMAGE}"
    : "${ALLBERT_CONTAINER_IMAGE_DIGEST:?set ALLBERT_CONTAINER_IMAGE_DIGEST}"
    [[ "$ALLBERT_CONTAINER_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      fail "container image digest must be a pinned sha256"
    ;;
esac

VERSION="$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*/\1/p' mix.exs | head -1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "could not resolve project version"
ARCHIVE="allbert-v${VERSION}-${TARGET}.tar.gz"
TOOLCHAIN="toolchain-${TARGET}.json"
SMOKE="smoke-${TARGET}.json"
DIGEST="${ARCHIVE}.sha256"

RUNTIME_OTP="$(elixir -e 'release = List.to_string(:erlang.system_info(:otp_release)); path = Path.join([:code.root_dir(), "releases", release, "OTP_VERSION"]); IO.write(File.read!(path) |> String.trim() |> String.trim_leading("OTP-"))')"
RUNTIME_ELIXIR="$(elixir -e 'IO.write(System.version())')"
RUNTIME_ERTS="$(elixir -e 'IO.write(:erlang.system_info(:version))')"
[ "$RUNTIME_OTP" = "$OTP_VERSION" ] || fail "OTP $RUNTIME_OTP does not match $OTP_VERSION"
[ "$RUNTIME_ELIXIR" = "$ELIXIR_VERSION" ] || fail "Elixir $RUNTIME_ELIXIR does not match $ELIXIR_VERSION"

RESOLVED_HEX="$(mix hex.info | awk '/^Hex:/ {value=$2} END {print value}')"
[ "$RESOLVED_HEX" = "$HEX_VERSION" ] || fail "Hex $RESOLVED_HEX does not match $HEX_VERSION"

ELIXIR_SERIES="$(printf '%s' "$RUNTIME_ELIXIR" | awk -F. '{print $1 "-" $2}')"
OTP_SERIES="$(printf '%s' "$RUNTIME_OTP" | awk -F. '{print $1}')"
REBAR3_BIN="${ALLBERT_REBAR3_BIN:-${MIX_HOME:-$HOME/.mix}/elixir/${ELIXIR_SERIES}-otp-${OTP_SERIES}/rebar3}"
[ -x "$REBAR3_BIN" ] || fail "exact rebar3 is unavailable at $REBAR3_BIN"
RESOLVED_REBAR3="$($REBAR3_BIN --version | awk 'NR == 1 {print $2}')"
[ "$RESOLVED_REBAR3" = "$REBAR3_VERSION" ] || fail "rebar3 $RESOLVED_REBAR3 does not match $REBAR3_VERSION"
export MIX_REBAR3="$REBAR3_BIN"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/allbert-candidate-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
RELEASE_ROOT="$WORK/allbert"

mix deps.get --only prod
mix hex.audit
mix release allbert --overwrite --path "$RELEASE_ROOT"

tar -czf "$WORK/$ARCHIVE" -C "$WORK" allbert
if ! bash scripts/smoke/artifact_smoke.sh "$RELEASE_ROOT" "$TARGET" > "$WORK/smoke.log"; then
  cat "$WORK/smoke.log" >&2 || true
  fail "target smoke exited non-zero"
fi
grep -q "^smoke:all PASS target=${TARGET} version=${VERSION}$" "$WORK/smoke.log" ||
  fail "target smoke did not emit its terminal PASS"
if grep -q ' FAIL ' "$WORK/smoke.log"; then
  fail "target smoke contains a failure"
fi

ARCHIVE_SHA256="$(sha256_file "$WORK/$ARCHIVE")"
SMOKE_LOG_SHA256="$(sha256_file "$WORK/smoke.log")"
PLAYWRIGHT_VERSION="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$PLAYWRIGHT_NODE_PATH/playwright/package.json")"
[ "$PLAYWRIGHT_VERSION" = 1.58.2 ] || fail "Playwright $PLAYWRIGHT_VERSION does not match 1.58.2"
NODE_VERSION="$(node -p 'process.versions.node')"
[[ "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "could not resolve the host Node version"
BROWSER_VERSION="$("$BROWSER_BINARY_PATH" --version | tr -d '\r\n')"
[ -n "$BROWSER_VERSION" ] && [ "${#BROWSER_VERSION}" -le 200 ] ||
  fail "could not resolve the host browser version"

CONTAINER_IMAGE="${ALLBERT_CONTAINER_IMAGE:-}"
CONTAINER_DIGEST="${ALLBERT_CONTAINER_IMAGE_DIGEST:-}"
jq -S -n \
  --arg target "$TARGET" --arg source_sha "$SOURCE_SHA" --arg generation "$GENERATION" \
  --arg builder_class "$BUILDER_CLASS" --arg host_os "$HOST_OS" --arg host_arch "$HOST_ARCH" \
  --arg container_image "$CONTAINER_IMAGE" --arg container_digest "$CONTAINER_DIGEST" \
  --arg otp "$RUNTIME_OTP" --arg elixir "$RUNTIME_ELIXIR" --arg erts "$RUNTIME_ERTS" \
  --arg hex "$RESOLVED_HEX" --arg rebar3 "$RESOLVED_REBAR3" \
  --arg node "$NODE_VERSION" --arg playwright "$PLAYWRIGHT_VERSION" \
  --arg browser "$BROWSER_VERSION" \
  '{schema_version: 2, kind: "allbert-candidate-toolchain", target: $target,
    source_sha: $source_sha, generation: $generation, builder: {
      class: $builder_class, os: $host_os, arch: $host_arch,
      container_image: (if $container_image == "" then null else $container_image end),
      container_digest: (if $container_digest == "" then null else $container_digest end)},
    runtime: {otp: $otp, elixir: $elixir, erts: $erts},
    build_tools: {hex: $hex, rebar3: $rebar3},
    external_runtime: {node: $node, playwright: $playwright, browser: $browser}}' > "$WORK/$TOOLCHAIN"

MACOS_NIF_SHA256=""
MACOS_NIF_INSTALL_NAME=""
if [ "$TARGET" = macos-arm64 ]; then
  NIF="$(find "$RELEASE_ROOT/lib" -path '*/exqlite-*/priv/sqlite3_nif.so' -type f -print)"
  [ "$(printf '%s\n' "$NIF" | awk 'NF {count++} END {print count+0}')" -eq 1 ] ||
    fail "expected exactly one packaged Exqlite NIF"
  MACOS_NIF_INSTALL_NAME="$(otool -D "$NIF" | tail -n +2 | awk 'NF {print; count++} END {if (count != 1) exit 1}')"
  [ "$MACOS_NIF_INSTALL_NAME" = '@loader_path/sqlite3_nif.so' ] ||
    fail "Exqlite install name is not package-manager stable"
  codesign --verify --strict "$NIF"
  MACOS_NIF_SHA256="$(sha256_file "$NIF")"
fi

jq -S -n \
  --arg target "$TARGET" --arg source_sha "$SOURCE_SHA" --arg generation "$GENERATION" \
  --arg archive "$ARCHIVE" --arg archive_sha256 "$ARCHIVE_SHA256" \
  --arg smoke_log_sha256 "$SMOKE_LOG_SHA256" --arg nif_sha256 "$MACOS_NIF_SHA256" \
  --arg nif_install_name "$MACOS_NIF_INSTALL_NAME" \
  '{schema_version: 2, kind: "allbert-candidate-target-smoke", target: $target,
    source_sha: $source_sha, generation: $generation, archive: $archive,
    archive_sha256: $archive_sha256, outcome: "passed",
    checks: ["boot", "version", "plugins", "browser_external_runtime", "browser_doctor",
      "browser_no_download", "health", "attach", "no_mix", "sqlite_runtime", "crypto_linkage"],
    smoke_log_sha256: $smoke_log_sha256,
    macos_exqlite: (if $nif_sha256 == "" then null else
      {sha256: $nif_sha256, install_name: $nif_install_name} end)}' > "$WORK/$SMOKE"

printf '%s  %s\n' "$ARCHIVE_SHA256" "$ARCHIVE" > "$WORK/$DIGEST"
mv "$WORK/$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE"
mv "$WORK/$TOOLCHAIN" "$OUTPUT_DIR/$TOOLCHAIN"
mv "$WORK/$SMOKE" "$OUTPUT_DIR/$SMOKE"
mv "$WORK/$DIGEST" "$OUTPUT_DIR/$DIGEST"
printf 'candidate-build: PASS target=%s sha=%s generation=%s archive_sha256=%s\n' \
  "$TARGET" "$SOURCE_SHA" "$GENERATION" "$ARCHIVE_SHA256"
