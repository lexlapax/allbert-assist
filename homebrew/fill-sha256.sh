#!/usr/bin/env sh
# Fill the REPLACE_*_SHA256 placeholders in a Homebrew formula from a release
# SHA256SUMS file (v0.62 M8.12). Run this after the release-artifacts workflow
# publishes the GitHub release, then commit/push the filled formula to the tap.
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

sum() {
  # v0.62 M8.17: match the asset name as an EXACT SHA256SUMS field (awk $2 ==),
  # not a regex whose dots are wildcards and whose value would also prefix-match
  # a `…tar.gz.sig` line.
  s="$(awk -v f="allbert-v${VERSION}-$1.tar.gz" '$2 == f {print $1}' "$SUMS")"
  [ -n "$s" ] || { echo "fill-sha256: no checksum for $1 in $SUMS" >&2; exit 1; }
  # Validate it is a bare 64-hex digest before it reaches the sed replacement,
  # so a malformed SHA256SUMS can't inject sed metacharacters into the formula.
  case "$s" in
    *[!0-9a-fA-F]* | "") echo "fill-sha256: malformed checksum for $1: $s" >&2; exit 1 ;;
  esac
  [ "${#s}" -eq 64 ] || { echo "fill-sha256: checksum for $1 is not 64 hex chars: $s" >&2; exit 1; }
  echo "$s"
}

sed -i.bak \
  -e "s/REPLACE_MACOS_ARM64_SHA256/$(sum macos-arm64)/" \
  -e "s/REPLACE_LINUX_X64_SHA256/$(sum linux-x64)/" \
  -e "s/REPLACE_LINUX_ARM64_SHA256/$(sum linux-arm64)/" \
  "$FORMULA"
rm -f "$FORMULA.bak"

echo "fill-sha256: filled $FORMULA for v$VERSION"
grep -n "sha256" "$FORMULA"
