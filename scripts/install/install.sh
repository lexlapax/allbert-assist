#!/usr/bin/env sh
# Allbert curl installer (v0.62 M2).
#
#   curl -fsSL https://raw.githubusercontent.com/lexlapax/allbert-assist/main/scripts/install/install.sh | sh
#
# Prefer download-then-inspect:
#   curl -fsSLO https://.../install.sh && less install.sh && sh install.sh
#
# Verifies the release artifact's SHA256 against the release's SHA256SUMS,
# installs only documented files, writes an uninstall manifest, and never
# touches Allbert Home. Wrapped in main() so a truncated download cannot run
# a partial script.
set -eu

main() {
  REPO="${ALLBERT_REPO:-lexlapax/allbert-assist}"
  VERSION="${ALLBERT_VERSION:-latest}"
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

  if [ "$VERSION" = "latest" ]; then
    base="https://github.com/$REPO/releases/latest/download"
  else
    base="https://github.com/$REPO/releases/download/$VERSION"
  fi

  artifact="allbert-${VERSION}-${target}.tar.gz"
  [ "$VERSION" = "latest" ] && artifact="allbert-${target}.tar.gz"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "allbert: downloading $artifact"
  curl -fsSL "$base/$artifact" -o "$tmp/$artifact"
  curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"

  echo "allbert: verifying checksum"
  expected="$(grep " $artifact\$" "$tmp/SHA256SUMS" | awk '{print $1}')"
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
  echo "    allbert serve"
  echo "allbert: your data lives in Allbert Home (~/.allbert) and is never touched by (un)install."
}

main "$@"
