#!/usr/bin/env sh
# Allbert curl installer (v0.62 M2).
#
#   curl -fsSL https://raw.githubusercontent.com/lexlapax/allbert-assist/main/scripts/install/install.sh | sh
#
# Prefer download-then-inspect:
#   curl -fsSLO https://.../install.sh && less install.sh && sh install.sh
#
# Verifies the signed release SHA256SUMS with cosign before checking the
# artifact SHA256, installs only documented files, writes an uninstall manifest,
# and never touches Allbert Home. Wrapped in main() so a truncated download
# cannot run a partial script.
set -eu

main() {
  REPO="${ALLBERT_REPO:-lexlapax/allbert-assist}"
  VERSION="${ALLBERT_VERSION:-latest}"
  # v0.62 M8.17: release tags and canonical assets are `v`-prefixed
  # (`v0.62.0`, `allbert-v0.62.0-<target>.tar.gz`). Normalize a bare
  # `ALLBERT_VERSION=0.62.0` to `v0.62.0` (strip-then-add) so it doesn't
  # double-404 on both the tag path and the asset name. `latest` stays special.
  if [ "$VERSION" != "latest" ]; then
    VERSION="v${VERSION#v}"
  fi
  PREFIX="${ALLBERT_PREFIX:-$HOME/.local}"
  BIN_DIR="$PREFIX/bin"
  LIB_DIR="$PREFIX/lib/allbert"
  MANIFEST="$LIB_DIR/.install-manifest"

  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os-$arch" in
    Darwin-arm64)  target="macos-arm64" ;;
    Linux-x86_64)  target="linux-x64" ;;
    Linux-aarch64) target="linux-arm64" ;;
    *)
      echo "allbert: unsupported platform $os-$arch." >&2
      echo "Tier 1: macos-arm64, linux-x64, linux-arm64. Windows: use WSL2 (a Linux target)." >&2
      exit 1
      ;;
  esac

  # ALLBERT_BASE_URL overrides where artifacts are fetched from (a mirror, or a
  # local file:// dir for release rehearsals); otherwise use the GitHub release.
  if [ -n "${ALLBERT_BASE_URL:-}" ]; then
    base="$ALLBERT_BASE_URL"
  elif [ "$VERSION" = "latest" ]; then
    base="https://github.com/$REPO/releases/latest/download"
  else
    base="https://github.com/$REPO/releases/download/$VERSION"
  fi

  # Canonical asset names match the release workflow: `allbert-v<version>-<target>.tar.gz`
  # for a pinned tag, and a version-less `allbert-<target>.tar.gz` alias for `latest`.
  if [ "$VERSION" = "latest" ]; then
    artifact="allbert-${target}.tar.gz"
  else
    artifact="allbert-${VERSION}-${target}.tar.gz"
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "allbert: downloading $artifact"
  curl -fsSL "$base/$artifact" -o "$tmp/$artifact"
  curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
  curl -fsSL "$base/SHA256SUMS.cosign.bundle" -o "$tmp/SHA256SUMS.cosign.bundle"

  echo "allbert: verifying release signature"
  if ! command -v cosign >/dev/null 2>&1; then
    cat >&2 <<'EOF'
allbert: cosign is required to verify Allbert release checksums.
Install cosign, then rerun this installer:
  macOS/Homebrew: brew install cosign
  Linux: https://docs.sigstore.dev/cosign/installation/
Refusing to install without signature verification.
EOF
    exit 1
  fi

  cosign verify-blob \
    --bundle "$tmp/SHA256SUMS.cosign.bundle" \
    --certificate-identity-regexp "https://github.com/lexlapax/allbert-assist/.github/workflows/release-artifacts.yml@refs/tags/.*" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "$tmp/SHA256SUMS" >/dev/null

  echo "allbert: verifying checksum"
  # v0.62 M8.17: match the filename as an EXACT SHA256SUMS field (not a regex —
  # the dots in the name would be wildcards, and a plain grep would also match a
  # longer `…tar.gz.sig` line as a prefix). awk compares field 2 verbatim.
  expected="$(awk -v f="$artifact" '$2 == f {print $1}' "$tmp/SHA256SUMS")"
  if [ -z "$expected" ]; then
    echo "allbert: no checksum for $artifact in SHA256SUMS — refusing to install." >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tmp/$artifact" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$tmp/$artifact" | awk '{print $1}')"
  fi
  if [ "$expected" != "$actual" ]; then
    echo "allbert: checksum mismatch — expected $expected got $actual. Aborting." >&2
    exit 1
  fi

  echo "allbert: installing to $LIB_DIR"
  rm -rf "$LIB_DIR"
  mkdir -p "$LIB_DIR" "$BIN_DIR"
  tar -xzf "$tmp/$artifact" -C "$LIB_DIR" --strip-components=1
  ln -sf "$LIB_DIR/bin/allbert" "$BIN_DIR/allbert"

  # Uninstall manifest: only what we wrote (never Allbert Home).
  {
    echo "$LIB_DIR"
    echo "$BIN_DIR/allbert"
  } > "$MANIFEST"

  echo "allbert: installed. Ensure $BIN_DIR is on your PATH, then run:"
  echo "    allbert admin service install --dry-run"
  echo "    allbert admin service install"
  echo "    allbert admin confirmations approve <ID>"
  echo "allbert: your data lives in Allbert Home (~/.allbert) and is never touched by (un)install."
  echo "allbert: if your platform has no user service manager, use 'allbert serve --open' as a repair fallback."
}

main "$@"
