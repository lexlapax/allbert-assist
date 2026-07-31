#!/usr/bin/env bash
# Stateless staging and no-build qualification for operator-built draft assets.
set -Eeuo pipefail
export LC_ALL=C
umask 077

GH_BIN="${ALLBERT_RELEASE_GH_BIN:-gh}"
TARGETS=(linux-arm64 linux-x64 macos-arm64)

fail() {
  echo "stage-artifacts: $*" >&2
  exit 1
}

require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || fail "missing $name"
  done
}

api() {
  "$GH_BIN" api "$@"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

register_cleanup() {
  local path="$1"
  local quoted
  printf -v quoted '%q' "$path"
  trap "rm -rf -- $quoted" EXIT
}

release_json() {
  api "/repos/${GITHUB_REPOSITORY}/releases/$1"
}

release_assets() {
  api --paginate --slurp "/repos/${GITHUB_REPOSITORY}/releases/$1/assets?per_page=100" |
    jq -c '[.[][]]'
}

asset_metadata() {
  api "/repos/${GITHUB_REPOSITORY}/releases/assets/$1"
}

asset_digest() {
  local asset_id="$1"
  local attempt=1 metadata digest
  while [ "$attempt" -le 10 ]; do
    metadata="$(asset_metadata "$asset_id")"
    digest="$(printf '%s' "$metadata" | jq -r '.digest // ""' | sed 's/^sha256://')"
    if [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      printf '%s' "$metadata"
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  fail "release asset $asset_id has no stable SHA-256 digest"
}

upload_asset() {
  local release_id="$1"
  local path="$2"
  local name response asset_id metadata expected actual
  name="$(basename "$path")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe release asset name $name"
  response="$(api --method POST -H 'Content-Type: application/octet-stream' --input "$path" \
    "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?name=${name}")"
  asset_id="$(printf '%s' "$response" | jq -r .id)"
  [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || fail "upload returned an invalid asset ID for $name"
  metadata="$(asset_digest "$asset_id")"
  [ "$(printf '%s' "$metadata" | jq -r .name)" = "$name" ] || fail "uploaded asset name changed"
  [ "$(printf '%s' "$metadata" | jq -r .state)" = uploaded ] || fail "asset $name is not uploaded"
  expected="$(sha256_file "$path")"
  actual="$(printf '%s' "$metadata" | jq -r .digest | sed 's/^sha256://')"
  [ "$actual" = "$expected" ] || fail "GitHub digest differs for $name"
  printf '%s' "$metadata" | jq -S --arg sha256 "$expected" \
    '{asset_id: .id, name, size, asset_digest: (.digest | sub("^sha256:"; "")), sha256: $sha256}'
}

download_asset() {
  local release_id="$1"
  local asset_id="$2"
  local expected_name="$3"
  local expected_digest="$4"
  local output="$5"
  local metadata
  metadata="$(asset_metadata "$asset_id")"
  [ "$(printf '%s' "$metadata" | jq -r .id)" = "$asset_id" ] || fail "asset ID mismatch"
  [ "$(printf '%s' "$metadata" | jq -r .name)" = "$expected_name" ] || fail "asset name mismatch"
  [ "$(printf '%s' "$metadata" | jq -r .state)" = uploaded ] || fail "asset is not uploaded"
  [ "$(printf '%s' "$metadata" | jq -r .digest | sed 's/^sha256://')" = "$expected_digest" ] ||
    fail "asset API digest mismatch for $expected_name"
  [ "$(printf '%s' "$metadata" | jq -r .url)" = \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}" ] ||
    fail "asset repository binding mismatch"
  api -H 'Accept: application/octet-stream' \
    "/repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}" > "$output"
  [ "$(sha256_file "$output")" = "$expected_digest" ] || fail "download digest mismatch for $expected_name"
  [ "$(printf '%s' "$metadata" | jq -r .size)" = "$(wc -c < "$output" | tr -d ' ')" ] ||
    fail "download size mismatch for $expected_name"
  [ "$release_id" = "$(release_json "$release_id" | jq -r .id)" ] || fail "release disappeared"
}

validate_release_path() {
  local entry="$1"
  case "$entry" in
    ""|/*|..|../*|*/../*|*/..|*[[:space:]]*) fail "unsafe release archive entry $entry" ;;
  esac
  case "$entry" in allbert|allbert/*) ;; *) fail "unsafe release archive entry $entry" ;; esac
}

validate_release_link() {
  local type="$1" member="$2" target="$3" combined part
  local -a parts stack
  validate_release_path "$member"
  case "$target" in ""|/*|*[[:space:]]*) fail "unsafe release archive link $member -> $target" ;; esac
  case "$type" in
    symlink) combined="${member%/*}/$target" ;;
    hardlink) combined="$target" ;;
    *) fail "unknown release archive link type $type" ;;
  esac
  IFS='/' read -r -a parts <<< "$combined"
  stack=()
  for part in "${parts[@]}"; do
    case "$part" in
      ""|.) ;;
      ..)
        [ "${#stack[@]}" -gt 1 ] || fail "unsafe release archive link $member -> $target"
        unset "stack[$((${#stack[@]} - 1))]"
        ;;
      *) stack+=("$part") ;;
    esac
  done
  [ "${stack[0]:-}" = allbert ] || fail "unsafe release archive link $member -> $target"
}

preflight_release_archive() {
  local archive="$1" before after entry listing type prefix member target
  before="$(sha256_file "$archive")"
  while IFS= read -r entry; do validate_release_path "$entry"; done < <(tar -tzf "$archive")
  while IFS= read -r listing; do
    type="${listing:0:1}"
    case "$type" in
      -|d) ;;
      l)
        case "$listing" in
          *" -> "*) prefix="${listing%% -> *}"; member="${prefix##* }"; target="${listing##* -> }"; validate_release_link symlink "$member" "$target" ;;
          *) fail "malformed release archive symlink" ;;
        esac
        ;;
      h)
        case "$listing" in
          *" link to "*) prefix="${listing%% link to *}"; member="${prefix##* }"; target="${listing##* link to }"; validate_release_link hardlink "$member" "$target" ;;
          *) fail "malformed release archive hardlink" ;;
        esac
        ;;
      *) fail "unsafe release archive entry type $type" ;;
    esac
  done < <(tar -tvzf "$archive")
  after="$(sha256_file "$archive")"
  [ "$before" = "$after" ] || fail "release archive changed during preflight"
}

extract_release() {
  local archive="$1" destination="$2"
  [ ! -e "$destination" ] || fail "release extraction destination already exists"
  preflight_release_archive "$archive"
  mkdir -p "$destination"
  # Qualification runs under umask 077, but the packaged mode bits are part of
  # the sealed license/payload evidence. Preserve the preflighted archive modes
  # instead of allowing the verifier's environment to rewrite them on extract.
  tar -xpzf "$archive" -C "$destination"
  [ -x "$destination/allbert/bin/allbert" ] || fail "packaged allbert executable is missing"
}

validate_local_generation() {
  local version="$1" source_sha="$2" generation="$3" directory="$4" work="$5"
  local target archive toolchain smoke digest archive_sha digest_sha openssl
  [ -d "$directory" ] && [ ! -L "$directory" ] || fail "candidate directory must be a regular directory"
  : > "$work/expected"
  for target in "${TARGETS[@]}"; do
    archive="allbert-${version}-${target}.tar.gz"
    toolchain="toolchain-${target}.json"
    smoke="smoke-${target}.json"
    digest="${archive}.sha256"
    printf '%s\n' "$archive" "$toolchain" "$smoke" "$digest" >> "$work/expected"
    for name in "$archive" "$toolchain" "$smoke" "$digest"; do
      [ -f "$directory/$name" ] && [ ! -L "$directory/$name" ] || fail "missing regular candidate file $name"
    done
    archive_sha="$(sha256_file "$directory/$archive")"
    digest_sha="$(awk -v name="$archive" 'NF == 2 && $2 == name {print $1}' "$directory/$digest")"
    [ "$archive_sha" = "$digest_sha" ] || fail "archive digest row differs for $target"
    jq -e --arg target "$target" --arg source_sha "$source_sha" --arg generation "$generation" \
      '.schema_version == 2 and .kind == "allbert-candidate-toolchain" and
       .target == $target and .source_sha == $source_sha and .generation == $generation and
       ((if ($target | startswith("linux-")) then
           .builder.class == "docker-linux" and
           .builder.container_image == "hexpm/erlang" and
           .builder.container_digest == "sha256:d8c7836b5b2b3b90918fb504b9eac563814503957875658528d9ab4581bf1e6b" and
           .builder.libc == {family: "glibc", version: "2.36"} and
           .builder.native_nifs == "source" and
           (.runtime.openssl | startswith("OpenSSL 3.")) and
           .runtime.sctp == {package: "libsctp1", version: "1.0.19+dfsg-2",
             soname: "libsctp.so.1"}
         else
           .builder.class == "operator-macos" and .builder.libc == null and
           .builder.native_nifs == null and .runtime.openssl == null and
           .runtime.sctp == null
         end)) and
       .runtime.otp == "29.0.1" and .runtime.elixir == "1.19.5" and
       .build_tools.hex == "2.5.1" and .build_tools.rebar3 == "3.25.1" and
       (.external_runtime.node | test("^[0-9]+\\.[0-9]+\\.[0-9]+")) and
       .external_runtime.playwright == "1.58.2" and
       (.external_runtime.browser | type == "string" and length > 0 and length <= 200)' \
      "$directory/$toolchain" >/dev/null ||
      fail "invalid exact-toolchain row for $target"
    openssl="$(jq -r '.runtime.openssl // empty' "$directory/$toolchain")"
    jq -e --arg target "$target" --arg source_sha "$source_sha" --arg generation "$generation" \
      --arg archive "$archive" --arg archive_sha "$archive_sha" --arg openssl "$openssl" \
      '.schema_version == 2 and .kind == "allbert-candidate-target-smoke" and
       .target == $target and .source_sha == $source_sha and .generation == $generation and
       .archive == $archive and .archive_sha256 == $archive_sha and .outcome == "passed" and
       (.checks == (["boot", "version", "plugins", "browser_external_runtime", "browser_doctor",
         "browser_no_download", "health", "attach", "no_mix", "license_json", "sqlite_runtime",
         "crypto_linkage"] +
         (if ($target | startswith("linux-")) then ["linux_sctp"] else [] end))) and
       (if ($target | startswith("linux-")) then
          .linux_crypto == {needed: "libcrypto.so.3", openssl: $openssl} and
          .linux_sctp == {package: "libsctp1", version: "1.0.19+dfsg-2",
            soname: "libsctp.so.1"}
        else .linux_crypto == null and .linux_sctp == null end)' \
      "$directory/$smoke" >/dev/null ||
      fail "invalid target-smoke row for $target"
    if [ "$target" = macos-arm64 ]; then
      jq -e '.macos_exqlite.install_name == "@loader_path/sqlite3_nif.so" and
        (.macos_exqlite.sha256 | test("^[0-9a-f]{64}$"))' "$directory/$smoke" >/dev/null ||
        fail "macOS Exqlite package-stability evidence is missing"
    fi
  done
  LC_ALL=C sort -o "$work/expected" "$work/expected"
  find "$directory" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort > "$work/actual"
  [ -z "$(find "$directory" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] ||
    fail "candidate directory contains non-regular entries"
  cmp "$work/expected" "$work/actual" || fail "candidate directory has missing, duplicate, or unexpected files"
}

stage_generation() {
  local release_id="$1" version="$2" source_sha="$3" generation="$4" directory="$5" output="$6"
  local work release target archive toolchain smoke digest archive_record toolchain_record smoke_record digest_record manifest_record
  [[ "$release_id" =~ ^[1-9][0-9]*$ ]] || fail "invalid release ID"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "invalid version"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source SHA"
  [[ "$generation" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "invalid generation"
  work="$(mktemp -d)"; register_cleanup "$work"; mkdir -p "$work/records" "$(dirname "$output")"
  release="$(release_json "$release_id")"
  [ "$(printf '%s' "$release" | jq -r .draft)" = true ] || fail "candidate release is not a draft"
  [ "$(printf '%s' "$release" | jq -r .immutable)" = false ] || fail "candidate release is already immutable"
  [ "$(printf '%s' "$release" | jq -r .tag_name)" = "$version" ] || fail "draft version mismatch"
  [ "$(printf '%s' "$release" | jq -r .target_commitish)" = "$source_sha" ] || fail "draft target SHA mismatch"
  [ "$(release_assets "$release_id" | jq 'length')" -eq 0 ] || fail "draft must have zero assets before complete-generation staging"
  validate_local_generation "$version" "$source_sha" "$generation" "$directory" "$work"

  for target in "${TARGETS[@]}"; do
    archive="allbert-${version}-${target}.tar.gz"; toolchain="toolchain-${target}.json"
    smoke="smoke-${target}.json"; digest="${archive}.sha256"
    archive_record="$(upload_asset "$release_id" "$directory/$archive")"
    toolchain_record="$(upload_asset "$release_id" "$directory/$toolchain")"
    smoke_record="$(upload_asset "$release_id" "$directory/$smoke")"
    digest_record="$(upload_asset "$release_id" "$directory/$digest")"
    jq -S -n --arg target "$target" --argjson archive "$archive_record" \
      --argjson toolchain_asset "$toolchain_record" --argjson smoke_asset "$smoke_record" \
      --argjson digest "$digest_record" --slurpfile toolchain "$directory/$toolchain" \
      --slurpfile smoke "$directory/$smoke" \
      '{target: $target, archive: $archive, toolchain_asset: $toolchain_asset,
        smoke_asset: $smoke_asset, digest_asset: $digest,
        toolchain: $toolchain[0], smoke: $smoke[0]}' > "$work/records/$target.json"
  done

  jq -S -n --argjson release_id "$release_id" --arg repository "$GITHUB_REPOSITORY" \
    --arg version "$version" --arg source_sha "$source_sha" --arg generation "$generation" \
    --slurpfile linux_arm64 "$work/records/linux-arm64.json" \
    --slurpfile linux_x64 "$work/records/linux-x64.json" \
    --slurpfile macos_arm64 "$work/records/macos-arm64.json" \
    '{schema_version: 2, kind: "allbert-release-candidate-manifest",
      repository: $repository, release_id: $release_id, tag: $version,
      source_sha: $source_sha, generation: $generation,
      archives: [$linux_arm64[0], $linux_x64[0], $macos_arm64[0]]}' > "$output"
  manifest_record="$(upload_asset "$release_id" "$output")"
  [ "$(release_assets "$release_id" | jq 'length')" -eq 13 ] || fail "staged draft does not contain exactly 13 candidate assets"
  printf 'release_id=%s\nmanifest_asset_id=%s\nmanifest_asset_digest=%s\nmanifest_sha256=%s\n' \
    "$release_id" "$(printf '%s' "$manifest_record" | jq -r .asset_id)" \
    "$(printf '%s' "$manifest_record" | jq -r .asset_digest)" "$(sha256_file "$output")"
}

open_candidate_manifest() {
  local release_id="$1" asset_id="$2" digest="$3" work="$4" output="$5" release
  [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || fail "invalid candidate manifest asset ID"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid candidate manifest digest"
  download_asset "$release_id" "$asset_id" candidate-manifest.json "$digest" "$output"
  release="$(release_json "$release_id")"
  [ "$(printf '%s' "$release" | jq -r .draft)" = true ] || fail "qualification requires a draft release"
  jq -e --arg repository "$GITHUB_REPOSITORY" --argjson release_id "$release_id" \
    '.schema_version == 2 and .kind == "allbert-release-candidate-manifest" and
     .repository == $repository and .release_id == $release_id and
     (.source_sha | test("^[0-9a-f]{40}$")) and (.generation | type == "string") and
     (.archives | length == 3) and
     ([.archives[].target] | sort == ["linux-arm64", "linux-x64", "macos-arm64"])' "$output" >/dev/null ||
    fail "candidate manifest shape or repository binding is invalid"
  [ "$(jq -r .tag "$output")" = "$(printf '%s' "$release" | jq -r .tag_name)" ] || fail "candidate tag differs from draft"
  [ "$(jq -r .source_sha "$output")" = "$(printf '%s' "$release" | jq -r .target_commitish)" ] || fail "candidate SHA differs from draft"
}

qualify_target() {
  local target="$1" release_id="$2" manifest_id="$3" manifest_digest="$4" output="$5"
  local work manifest row archive_name archive_id archive_digest toolchain_name toolchain_id toolchain_digest
  local smoke_name smoke_id smoke_digest digest_name digest_id digest_digest release_root viewer fv host_libc host_libc_version
  case " ${TARGETS[*]} " in *" $target "*) ;; *) fail "unsupported target $target" ;; esac
  if [[ "$target" == linux-* ]]; then
    host_libc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    [[ "$host_libc" =~ ^glibc\ ([0-9]+\.[0-9]+)$ ]] ||
      fail "Linux qualifier host did not report a supported glibc version: ${host_libc:-unknown}"
    host_libc_version="${BASH_REMATCH[1]}"
    [ "$(printf '%s\n' 2.36 "$host_libc_version" | sort -V | head -n 1)" = 2.36 ] ||
      fail "Linux qualifier host requires glibc >= 2.36; found $host_libc_version"
  fi
  work="$(mktemp -d)"; register_cleanup "$work"; mkdir -p "$(dirname "$output")"
  manifest="$work/candidate-manifest.json"
  open_candidate_manifest "$release_id" "$manifest_id" "$manifest_digest" "$work" "$manifest"
  row="$work/row.json"; jq -S --arg target "$target" '.archives[] | select(.target == $target)' "$manifest" > "$row"
  [ "$(jq -r .target "$row")" = "$target" ] || fail "candidate target row missing"

  archive_name="$(jq -r .archive.name "$row")"; archive_id="$(jq -r .archive.asset_id "$row")"; archive_digest="$(jq -r .archive.asset_digest "$row")"
  toolchain_name="$(jq -r .toolchain_asset.name "$row")"; toolchain_id="$(jq -r .toolchain_asset.asset_id "$row")"; toolchain_digest="$(jq -r .toolchain_asset.asset_digest "$row")"
  smoke_name="$(jq -r .smoke_asset.name "$row")"; smoke_id="$(jq -r .smoke_asset.asset_id "$row")"; smoke_digest="$(jq -r .smoke_asset.asset_digest "$row")"
  digest_name="$(jq -r .digest_asset.name "$row")"; digest_id="$(jq -r .digest_asset.asset_id "$row")"; digest_digest="$(jq -r .digest_asset.asset_digest "$row")"
  download_asset "$release_id" "$archive_id" "$archive_name" "$archive_digest" "$work/$archive_name"
  download_asset "$release_id" "$toolchain_id" "$toolchain_name" "$toolchain_digest" "$work/$toolchain_name"
  download_asset "$release_id" "$smoke_id" "$smoke_name" "$smoke_digest" "$work/$smoke_name"
  download_asset "$release_id" "$digest_id" "$digest_name" "$digest_digest" "$work/$digest_name"
  [ "$(sha256_file "$work/$archive_name")" = "$(jq -r .archive.sha256 "$row")" ] || fail "archive content hash mismatch"
  jq -S . "$work/$toolchain_name" > "$work/toolchain.sorted"; jq -S .toolchain "$row" > "$work/bound-toolchain.sorted"; cmp "$work/toolchain.sorted" "$work/bound-toolchain.sorted"
  jq -S . "$work/$smoke_name" > "$work/smoke.sorted"; jq -S .smoke "$row" > "$work/bound-smoke.sorted"; cmp "$work/smoke.sorted" "$work/bound-smoke.sorted"
  grep -Fxq "$(jq -r .archive.sha256 "$row")  $archive_name" "$work/$digest_name" || fail "digest file is not exact"

  extract_release "$work/$archive_name" "$work/release"
  release_root="$work/release/allbert"; viewer="$release_root/bin/allbert"; mkdir -p "$work/home"
  for required in LICENSE NOTICE THIRD-PARTY-LICENSES.md THIRD-PARTY-MANIFEST.json; do [ -f "$release_root/$required" ] || fail "packaged $required is missing"; done
  (cd "$work" && env -i HOME="$work" ALLBERT_HOME="$work/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh LANG=C.UTF-8 "$viewer" licenses summary) > "$work/summary.txt"
  (cd "$work" && env -i HOME="$work" ALLBERT_HOME="$work/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh LANG=C.UTF-8 "$viewer" licenses --json) > "$work/licenses.json"
  jq -S . "$work/licenses.json" > "$work/viewer-manifest.json"; jq -S . "$release_root/THIRD-PARTY-MANIFEST.json" > "$work/packaged-manifest.json"; cmp "$work/viewer-manifest.json" "$work/packaged-manifest.json"
  jq -e --arg target "$target" '.schema_version == 1 and .target.triple == $target and (.components | length > 0)' "$work/licenses.json" >/dev/null || fail "packaged license viewer failed"

  fv="$work/fv.json"
  scripts/smoke/v121_tui_qualification.sh "$release_root" "$target" "$fv"
  jq -e --arg target "$target" '.schema_version == 1 and .target == $target and .protocol_tty == "passed" and .provider == "not_required"' "$fv" >/dev/null || fail "packaged TUI protocol qualification failed"
  jq -S -n --arg target "$target" --argjson release_id "$release_id" \
    --arg manifest_sha256 "$(sha256_file "$manifest")" --arg license_sha256 "$(sha256_file "$work/licenses.json")" \
    --arg summary_sha256 "$(sha256_file "$work/summary.txt")" --slurpfile candidate "$row" --slurpfile fv "$fv" \
    '{schema_version: 2, kind: "allbert-release-qualification-target-row", target: $target,
      release_id: $release_id, candidate_manifest_sha256: $manifest_sha256,
      candidate: $candidate[0], qualifications: {license: "passed", protocol_tty: "passed",
        provider: "not_required"}, evidence: {license_manifest_sha256: $license_sha256,
        license_summary_sha256: $summary_sha256, protocol_tty_sha256: $fv[0].evidence.protocol_tty_sha256}}' > "$output"
}

download_action_row() {
  local target="$1" work="$2" name metadata count id digest zip entry
  name="qualification-${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}-${target}"
  metadata="$(api --paginate --slurp "/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts?per_page=100" | jq -c '[.[].artifacts[] | select(.name == "'"$name"'")]')"
  count="$(printf '%s' "$metadata" | jq 'length')"; [ "$count" -eq 1 ] || fail "expected one $target qualification artifact, found $count"
  id="$(printf '%s' "$metadata" | jq -r '.[0].id')"; digest="$(printf '%s' "$metadata" | jq -r '.[0].digest | sub("^sha256:"; "")')"
  zip="$work/$target.zip"; api -H 'Accept: application/vnd.github+json' "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${id}/zip" > "$zip"
  [ "$(sha256_file "$zip")" = "$digest" ] || fail "qualification artifact ZIP digest mismatch"
  while IFS= read -r entry; do case "$entry" in /*|../*|*/../*|*/..) fail "unsafe qualification ZIP entry" ;; esac; done < <(unzip -Z1 "$zip")
  mkdir -p "$work/$target"; unzip -q "$zip" -d "$work/$target"
  [ -f "$work/$target/qualification-${target}.json" ] || fail "qualification row missing"
  printf '%s\n' "$id $digest"
}

collect_qualification() {
  local release_id="$1" manifest_id="$2" manifest_digest="$3" output="$4" work manifest target action_binding row selected
  work="$(mktemp -d)"; register_cleanup "$work"; mkdir -p "$work/rows" "$(dirname "$output")"
  manifest="$work/candidate-manifest.json"; open_candidate_manifest "$release_id" "$manifest_id" "$manifest_digest" "$work" "$manifest"
  for target in "${TARGETS[@]}"; do
    action_binding="$(download_action_row "$target" "$work")"; row="$work/$target/qualification-${target}.json"
    jq -e --arg target "$target" --argjson release_id "$release_id" --arg manifest_sha "$(sha256_file "$manifest")" \
      '.schema_version == 2 and .kind == "allbert-release-qualification-target-row" and
       .target == $target and .release_id == $release_id and .candidate_manifest_sha256 == $manifest_sha and
       .qualifications == {license: "passed", protocol_tty: "passed", provider: "not_required"}' "$row" >/dev/null || fail "invalid $target qualification row"
    selected="$work/selected-$target.json"; jq -S --arg target "$target" '.archives[] | select(.target == $target)' "$manifest" > "$selected"; jq -S .candidate "$row" > "$work/candidate-$target.json"; cmp "$selected" "$work/candidate-$target.json"
    jq -S --argjson artifact_id "${action_binding%% *}" --arg artifact_digest "${action_binding##* }" '. + {evidence_artifact_id: $artifact_id, evidence_artifact_digest: $artifact_digest}' "$row" > "$work/rows/$target.json"
  done
  jq -S -n --argjson release_id "$release_id" --arg tag "$(jq -r .tag "$manifest")" \
    --arg source_sha "$(jq -r .source_sha "$manifest")" --arg generation "$(jq -r .generation "$manifest")" \
    --argjson candidate_asset_id "$manifest_id" --arg candidate_asset_digest "$manifest_digest" \
    --arg candidate_sha256 "$(sha256_file "$manifest")" --argjson workflow_run_id "$GITHUB_RUN_ID" \
    --argjson workflow_run_attempt "$GITHUB_RUN_ATTEMPT" \
    --slurpfile linux_arm64 "$work/rows/linux-arm64.json" --slurpfile linux_x64 "$work/rows/linux-x64.json" --slurpfile macos_arm64 "$work/rows/macos-arm64.json" \
    '{schema_version: 2, kind: "allbert-release-qualification-manifest", release_id: $release_id,
      tag: $tag, source_sha: $source_sha, generation: $generation,
      candidate_manifest: {asset_id: $candidate_asset_id, asset_digest: $candidate_asset_digest,
        sha256: $candidate_sha256}, workflow_run: {id: $workflow_run_id, attempt: $workflow_run_attempt},
      operator_validation: {macos_tui: "required_before_promotion", configured_provider: "required_before_promotion"},
      archives: [$linux_arm64[0], $linux_x64[0], $macos_arm64[0]]}' > "$output"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "qualification-sha256=$(sha256_file "$output")" >> "$GITHUB_OUTPUT"; fi
}

case "${1:-}" in
  stage-generation)
    require_env GITHUB_REPOSITORY; [ "$#" -eq 7 ] || fail "usage: stage-generation RELEASE_ID VERSION SHA GENERATION DIR MANIFEST"
    stage_generation "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  qualify-target)
    require_env GITHUB_REPOSITORY; [ "$#" -eq 6 ] || fail "usage: qualify-target TARGET RELEASE_ID MANIFEST_ID MANIFEST_DIGEST OUTPUT"
    qualify_target "$2" "$3" "$4" "$5" "$6"
    ;;
  collect-qualification)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT; [ "$#" -eq 5 ] || fail "usage: collect-qualification RELEASE_ID MANIFEST_ID MANIFEST_DIGEST OUTPUT"
    collect_qualification "$2" "$3" "$4" "$5"
    ;;
  extract-release)
    [ "$#" -eq 3 ] || fail "usage: extract-release ARCHIVE DESTINATION"
    extract_release "$2" "$3"
    ;;
  validate-release-path)
    [ "$#" -eq 2 ]; validate_release_path "$2"
    ;;
  validate-release-link)
    [ "$#" -eq 4 ]; validate_release_link "$2" "$3" "$4"
    ;;
  *) fail "unknown mode; use stage-generation, qualify-target, collect-qualification, extract-release, validate-release-path, or validate-release-link" ;;
esac
