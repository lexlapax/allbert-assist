#!/usr/bin/env sh
# Fill a Homebrew formula from a release SHA256SUMS file. This updates the
# formula version, per-target release URLs, and per-target SHA256 values so the
# tap cannot accidentally keep resolving to an older Allbert release.
#
#   homebrew/fill-sha256.sh SHA256SUMS [path/to/allbert.rb]
#
# Fetch the SHA256SUMS from the release first, e.g.:
#   gh release download vX.Y.Z --pattern SHA256SUMS --dir /tmp
set -eu

SUMS="${1:?usage: fill-sha256.sh SHA256SUMS [formula.rb]}"
FORMULA="${2:-homebrew/allbert.rb}"

[ -f "$SUMS" ] || { echo "fill-sha256: no such file: $SUMS" >&2; exit 1; }
[ -f "$FORMULA" ] || { echo "fill-sha256: no such formula: $FORMULA" >&2; exit 1; }

# Version is derived from the versioned asset names in SHA256SUMS.
VERSION="$(grep -oE 'allbert-v[0-9][0-9.]*-' "$SUMS" | head -1 | sed -E 's/allbert-v(.*)-/\1/')"
[ -n "$VERSION" ] || { echo "fill-sha256: could not derive version from $SUMS" >&2; exit 1; }
TAG="v$VERSION"
BASE_URL="https://github.com/lexlapax/allbert-assist/releases/download/$TAG"

sum() {
  # v0.62 M8.17: match the asset name as an EXACT SHA256SUMS field (awk $2 ==),
  # not a regex whose dots are wildcards and whose value would also prefix-match
  # a `…tar.gz.sig` line.
  s="$(awk -v f="allbert-${TAG}-$1.tar.gz" '$2 == f {print $1}' "$SUMS")"
  [ -n "$s" ] || { echo "fill-sha256: no checksum for $1 in $SUMS" >&2; exit 1; }
  # Validate it is a bare 64-hex digest before it reaches the sed replacement,
  # so a malformed SHA256SUMS can't inject sed metacharacters into the formula.
  case "$s" in
    *[!0-9a-fA-F]* | "") echo "fill-sha256: malformed checksum for $1: $s" >&2; exit 1 ;;
  esac
  [ "${#s}" -eq 64 ] || { echo "fill-sha256: checksum for $1 is not 64 hex chars: $s" >&2; exit 1; }
  echo "$s"
}

MACOS_ARM64_SHA="$(sum macos-arm64)"
LINUX_X64_SHA="$(sum linux-x64)"
LINUX_ARM64_SHA="$(sum linux-arm64)"

TMP_FORMULA="${FORMULA}.tmp.$$"
trap 'rm -f "$TMP_FORMULA"' EXIT

awk \
  -v version="$VERSION" \
  -v macos_arm64_url="$BASE_URL/allbert-${TAG}-macos-arm64.tar.gz" \
  -v linux_x64_url="$BASE_URL/allbert-${TAG}-linux-x64.tar.gz" \
  -v linux_arm64_url="$BASE_URL/allbert-${TAG}-linux-arm64.tar.gz" \
  -v macos_arm64_sha="$MACOS_ARM64_SHA" \
  -v linux_x64_sha="$LINUX_X64_SHA" \
  -v linux_arm64_sha="$LINUX_ARM64_SHA" '
    /^  version / {
      print "  version \"" version "\""
      next
    }
    /allbert-v.*-macos-arm64\.tar\.gz/ {
      print "      url \"" macos_arm64_url "\""
      target = "macos-arm64"
      next
    }
    /allbert-v.*-linux-x64\.tar\.gz/ {
      print "      url \"" linux_x64_url "\""
      target = "linux-x64"
      next
    }
    /allbert-v.*-linux-arm64\.tar\.gz/ {
      print "      url \"" linux_arm64_url "\""
      target = "linux-arm64"
      next
    }
    target == "macos-arm64" && /^[[:space:]]*sha256 / {
      print "      sha256 \"" macos_arm64_sha "\""
      target = ""
      next
    }
    target == "linux-x64" && /^[[:space:]]*sha256 / {
      print "      sha256 \"" linux_x64_sha "\""
      target = ""
      next
    }
    target == "linux-arm64" && /^[[:space:]]*sha256 / {
      print "      sha256 \"" linux_arm64_sha "\""
      target = ""
      next
    }
    { print }
  ' "$FORMULA" > "$TMP_FORMULA"

mv "$TMP_FORMULA" "$FORMULA"
trap - EXIT

echo "fill-sha256: filled $FORMULA for v$VERSION"
grep -nE "version |url |sha256" "$FORMULA"
