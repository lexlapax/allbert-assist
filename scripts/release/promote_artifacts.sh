#!/usr/bin/env bash
# Protected, no-build promotion of one qualified draft generation.
set -Eeuo pipefail
export LC_ALL=C
umask 077

GH_BIN="${ALLBERT_RELEASE_GH_BIN:-gh}"
COSIGN_BIN="${ALLBERT_RELEASE_COSIGN_BIN:-cosign}"
TARGETS=(linux-arm64 linux-x64 macos-arm64)

fail() {
  echo "promote-artifacts: $*" >&2
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
  sha256sum "$1" | awk '{print $1}'
}

WORK="$(mktemp -d "${RUNNER_TEMP:?RUNNER_TEMP is required}/allbert-promotion.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/publish"

release_json() {
  api "/repos/${GITHUB_REPOSITORY}/releases/${PROMOTION_RELEASE_ID}"
}

release_assets() {
  api --paginate --slurp "/repos/${GITHUB_REPOSITORY}/releases/${PROMOTION_RELEASE_ID}/assets?per_page=100" |
    jq -c '[.[][]]'
}

download_release_asset() {
  local id="$1" name="$2" digest="$3" output="$4" metadata
  metadata="$(api "/repos/${GITHUB_REPOSITORY}/releases/assets/${id}")"
  [ "$(printf '%s' "$metadata" | jq -r .id)" = "$id" ] || fail "release asset ID mismatch"
  [ "$(printf '%s' "$metadata" | jq -r .name)" = "$name" ] || fail "release asset name mismatch"
  [ "$(printf '%s' "$metadata" | jq -r .state)" = uploaded ] || fail "release asset is not uploaded"
  [ "$(printf '%s' "$metadata" | jq -r .digest | sed 's/^sha256://')" = "$digest" ] || fail "release asset API digest mismatch"
  api -H 'Accept: application/octet-stream' "/repos/${GITHUB_REPOSITORY}/releases/assets/${id}" > "$output"
  [ "$(sha256_file "$output")" = "$digest" ] || fail "release asset content digest mismatch"
}

peel_provisional_tag() {
  local ref type sha object depth=0
  ref="$(api "/repos/${GITHUB_REPOSITORY}/git/ref/tags/${PROMOTION_TAG}")"
  type="$(printf '%s' "$ref" | jq -r .object.type)"; sha="$(printf '%s' "$ref" | jq -r .object.sha)"
  while [ "$type" = tag ]; do
    depth=$((depth + 1)); [ "$depth" -le 8 ] || fail "annotated tag chain exceeds bound"
    object="$(api "/repos/${GITHUB_REPOSITORY}/git/tags/${sha}")"
    type="$(printf '%s' "$object" | jq -r .object.type)"; sha="$(printf '%s' "$object" | jq -r .object.sha)"
  done
  [ "$type" = commit ] && [ "$sha" = "$SOURCE_SHA" ] || fail "provisional tag does not peel to source SHA"
}

download_qualification() {
  local metadata run workflow zip digest entry
  metadata="$(api "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${QUALIFICATION_ARTIFACT_ID}")"
  [ "$(printf '%s' "$metadata" | jq -r .id)" = "$QUALIFICATION_ARTIFACT_ID" ] || fail "qualification artifact ID mismatch"
  [ "$(printf '%s' "$metadata" | jq -r .workflow_run.id)" = "$QUALIFICATION_RUN_ID" ] || fail "qualification run binding mismatch"
  [ "$(printf '%s' "$metadata" | jq -r .expired)" = false ] || fail "qualification evidence expired"
  digest="$(printf '%s' "$metadata" | jq -r .digest | sed 's/^sha256://')"
  [ "$digest" = "$QUALIFICATION_ARTIFACT_DIGEST" ] || fail "qualification artifact API digest mismatch"
  run="$(api "/repos/${GITHUB_REPOSITORY}/actions/runs/${QUALIFICATION_RUN_ID}")"
  workflow="$(api "/repos/${GITHUB_REPOSITORY}/actions/workflows/$(printf '%s' "$run" | jq -r .workflow_id)")"
  [ "$(printf '%s' "$run" | jq -r .event)" = workflow_dispatch ] || fail "qualification did not use workflow_dispatch"
  [ "$(printf '%s' "$run" | jq -r .head_sha)" = "$SOURCE_SHA" ] || fail "qualification run SHA mismatch"
  [ "$(printf '%s' "$run" | jq -r .conclusion)" = success ] || fail "qualification run did not succeed"
  [ "$(printf '%s' "$workflow" | jq -r .path)" = "$RELEASE_WORKFLOW_PATH" ] || fail "qualification workflow path mismatch"
  zip="$WORK/qualification.zip"
  api -H 'Accept: application/vnd.github+json' "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${QUALIFICATION_ARTIFACT_ID}/zip" > "$zip"
  [ "$(sha256_file "$zip")" = "$QUALIFICATION_ARTIFACT_DIGEST" ] || fail "qualification ZIP digest mismatch"
  while IFS= read -r entry; do case "$entry" in /*|../*|*/../*|*/..) fail "unsafe qualification ZIP entry" ;; esac; done < <(unzip -Z1 "$zip")
  mkdir -p "$WORK/qualification"; unzip -q "$zip" -d "$WORK/qualification"
  [ "$(find "$WORK/qualification" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "qualification artifact must contain one file"
  [ -f "$WORK/qualification/qualification-manifest.json" ] || fail "qualification manifest is missing"
}

validate_candidate_and_qualification() {
  local release candidate qualification target selected row
  release="$(release_json)"
  [ "$(printf '%s' "$release" | jq -r .id)" = "$PROMOTION_RELEASE_ID" ] || fail "draft release ID mismatch"
  [ "$(printf '%s' "$release" | jq -r .draft)" = true ] || fail "promotion requires a draft"
  [ "$(printf '%s' "$release" | jq -r .immutable)" = false ] || fail "draft is already immutable"
  [ "$(printf '%s' "$release" | jq -r .tag_name)" = "$PROMOTION_TAG" ] || fail "draft tag mismatch"
  [ "$(printf '%s' "$release" | jq -r .target_commitish)" = "$SOURCE_SHA" ] || fail "draft source SHA mismatch"
  download_release_asset "$CANDIDATE_MANIFEST_ASSET_ID" candidate-manifest.json \
    "$CANDIDATE_MANIFEST_ASSET_DIGEST" "$WORK/candidate-manifest.json"
  candidate="$WORK/candidate-manifest.json"
  qualification="$WORK/qualification/qualification-manifest.json"
  jq -e --arg repository "$GITHUB_REPOSITORY" --argjson release_id "$PROMOTION_RELEASE_ID" \
    --arg tag "$PROMOTION_TAG" --arg source_sha "$SOURCE_SHA" --arg generation "$CANDIDATE_GENERATION" \
    '.schema_version == 2 and .kind == "allbert-release-candidate-manifest" and
     .repository == $repository and .release_id == $release_id and .tag == $tag and
     .source_sha == $source_sha and .generation == $generation and (.archives | length == 3)' "$candidate" >/dev/null || fail "candidate manifest binding is invalid"
  jq -e --argjson release_id "$PROMOTION_RELEASE_ID" --arg tag "$PROMOTION_TAG" \
    --arg source_sha "$SOURCE_SHA" --arg generation "$CANDIDATE_GENERATION" \
    --argjson candidate_id "$CANDIDATE_MANIFEST_ASSET_ID" --arg candidate_digest "$CANDIDATE_MANIFEST_ASSET_DIGEST" \
    --arg candidate_sha "$(sha256_file "$candidate")" --argjson run_id "$QUALIFICATION_RUN_ID" \
    '.schema_version == 2 and .kind == "allbert-release-qualification-manifest" and
     .release_id == $release_id and .tag == $tag and .source_sha == $source_sha and
     .generation == $generation and .candidate_manifest == {asset_id: $candidate_id,
       asset_digest: $candidate_digest, sha256: $candidate_sha} and
     .workflow_run.id == $run_id and (.archives | length == 3) and
     .operator_validation == {macos_tui: "required_before_promotion",
       configured_provider: "required_before_promotion"} and
     (all(.archives[]; .qualifications == {license: "passed", protocol_tty: "passed", provider: "not_required"}))' \
    "$qualification" >/dev/null || fail "qualification manifest binding is invalid"
  for target in "${TARGETS[@]}"; do
    selected="$WORK/candidate-$target.json"; row="$WORK/qualified-$target.json"
    jq -S --arg target "$target" '.archives[] | select(.target == $target)' "$candidate" > "$selected"
    jq -S --arg target "$target" '.archives[] | select(.target == $target) | .candidate' "$qualification" > "$row"
    cmp "$selected" "$row" || fail "qualification candidate row differs for $target"
  done
}

validate_core_asset_set() {
  local expected="$WORK/expected-core-assets" target existing assets
  : > "$expected"
  for target in "${TARGETS[@]}"; do
    jq -r --arg target "$target" '.archives[] | select(.target == $target) |
      [.archive.name, .toolchain_asset.name, .smoke_asset.name, .digest_asset.name][]' \
      "$WORK/candidate-manifest.json" >> "$expected"
  done
  echo candidate-manifest.json >> "$expected"; LC_ALL=C sort -o "$expected" "$expected"
  assets="$(release_assets)"; printf '%s' "$assets" | jq -r '.[].name' | LC_ALL=C sort > "$WORK/actual-core-assets"
  cmp "$expected" "$WORK/actual-core-assets" || fail "draft contains missing, duplicate, or unexpected pre-promotion assets"
}

upload_or_compare() {
  local name="$1" path="$2" assets count metadata id existing expected actual
  assets="$(release_assets)"; count="$(printf '%s' "$assets" | jq --arg name "$name" '[.[] | select(.name == $name)] | length')"
  case "$count" in
    0)
      api --method POST -H 'Content-Type: application/octet-stream' --input "$path" \
        "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${PROMOTION_RELEASE_ID}/assets?name=${name}" >/dev/null
      ;;
    1)
      id="$(printf '%s' "$assets" | jq -r --arg name "$name" '.[] | select(.name == $name) | .id')"
      metadata="$(api "/repos/${GITHUB_REPOSITORY}/releases/assets/${id}")"
      [ "$(printf '%s' "$metadata" | jq -r .digest | sed 's/^sha256://')" = "$(sha256_file "$path")" ] || fail "existing asset $name API digest differs"
      existing="$WORK/existing-$name"; api -H 'Accept: application/octet-stream' "/repos/${GITHUB_REPOSITORY}/releases/assets/${id}" > "$existing"
      expected="$(sha256_file "$path")"; actual="$(sha256_file "$existing")"; [ "$actual" = "$expected" ] || fail "existing asset $name differs"
      ;;
    *) fail "duplicate release asset $name" ;;
  esac
}

prepare_publication_assets() {
  local target id name digest versioned alias assets bundle_count bundle_id identity
  for target in "${TARGETS[@]}"; do
    id="$(jq -r --arg target "$target" '.archives[] | select(.target == $target) | .archive.asset_id' "$WORK/candidate-manifest.json")"
    name="$(jq -r --arg target "$target" '.archives[] | select(.target == $target) | .archive.name' "$WORK/candidate-manifest.json")"
    digest="$(jq -r --arg target "$target" '.archives[] | select(.target == $target) | .archive.asset_digest' "$WORK/candidate-manifest.json")"
    versioned="$WORK/publish/$name"; download_release_asset "$id" "$name" "$digest" "$versioned"
    alias="allbert-${target}.tar.gz"; cp "$versioned" "$WORK/publish/$alias"; upload_or_compare "$alias" "$WORK/publish/$alias"
  done
  (cd "$WORK/publish" && find . -maxdepth 1 -type f -name '*.tar.gz' -print | sed 's|^./||' | LC_ALL=C sort | while IFS= read -r file; do printf '%s  %s\n' "$(sha256_file "$file")" "$file"; done > SHA256SUMS)
  upload_or_compare SHA256SUMS "$WORK/publish/SHA256SUMS"
  assets="$(release_assets)"; bundle_count="$(printf '%s' "$assets" | jq '[.[] | select(.name == "SHA256SUMS.cosign.bundle")] | length')"
  identity="https://github.com/${GITHUB_REPOSITORY}/${RELEASE_WORKFLOW_PATH}@refs/tags/${PROMOTION_TAG}"
  if [ "$bundle_count" -eq 0 ]; then
    "$COSIGN_BIN" sign-blob --yes --bundle "$WORK/publish/SHA256SUMS.cosign.bundle" "$WORK/publish/SHA256SUMS"
    upload_or_compare SHA256SUMS.cosign.bundle "$WORK/publish/SHA256SUMS.cosign.bundle"
  elif [ "$bundle_count" -eq 1 ]; then
    bundle_id="$(printf '%s' "$assets" | jq -r '.[] | select(.name == "SHA256SUMS.cosign.bundle") | .id')"
    api -H 'Accept: application/octet-stream' "/repos/${GITHUB_REPOSITORY}/releases/assets/${bundle_id}" > "$WORK/publish/SHA256SUMS.cosign.bundle"
  else
    fail "duplicate cosign bundle"
  fi
  "$COSIGN_BIN" verify-blob --bundle "$WORK/publish/SHA256SUMS.cosign.bundle" \
    --certificate-identity "$identity" --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    "$WORK/publish/SHA256SUMS" >/dev/null
  [ "$(release_assets | jq 'length')" -eq 18 ] || fail "draft does not contain the exact final 18-asset set"
}

publish_draft() {
  local immutable prerelease=false published attempt=1
  immutable="$(api "/repos/${GITHUB_REPOSITORY}/immutable-releases")"
  [ "$(printf '%s' "$immutable" | jq -r .enabled)" = true ] || fail "GitHub immutable releases are not enabled"
  case "$PROMOTION_TAG" in *-*) prerelease=true ;; esac
  jq -S -n --argjson prerelease "$prerelease" '{draft: false, prerelease: $prerelease, make_latest: "true"}' > "$WORK/publish.json"
  published="$(api --method PATCH --input "$WORK/publish.json" "/repos/${GITHUB_REPOSITORY}/releases/${PROMOTION_RELEASE_ID}")"
  [ "$(printf '%s' "$published" | jq -r .draft)" = false ] || fail "release did not publish"
  while [ "$attempt" -le 10 ]; do
    published="$(release_json)"
    if [ "$(printf '%s' "$published" | jq -r .immutable)" = true ]; then
      printf 'promote-artifacts: PASS release_id=%s tag=%s source_sha=%s immutable=true\n' "$PROMOTION_RELEASE_ID" "$PROMOTION_TAG" "$SOURCE_SHA"
      return 0
    fi
    sleep 1; attempt=$((attempt + 1))
  done
  fail "published release did not become immutable"
}

require_env GITHUB_REPOSITORY GITHUB_REF GITHUB_REF_NAME GITHUB_SHA RELEASE_WORKFLOW_PATH \
  PROMOTION_RELEASE_ID PROMOTION_TAG SOURCE_SHA CANDIDATE_GENERATION \
  CANDIDATE_MANIFEST_ASSET_ID CANDIDATE_MANIFEST_ASSET_DIGEST QUALIFICATION_RUN_ID \
  QUALIFICATION_ARTIFACT_ID QUALIFICATION_ARTIFACT_DIGEST OPERATOR_TUI_VALIDATION \
  CONFIGURED_PROVIDER_VALIDATION
[[ "$PROMOTION_RELEASE_ID" =~ ^[1-9][0-9]*$ ]] || fail "invalid release ID"
[[ "$CANDIDATE_MANIFEST_ASSET_ID" =~ ^[1-9][0-9]*$ ]] || fail "invalid candidate manifest asset ID"
[[ "$QUALIFICATION_RUN_ID" =~ ^[1-9][0-9]*$ ]] || fail "invalid qualification run ID"
[[ "$QUALIFICATION_ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]] || fail "invalid qualification artifact ID"
[[ "$CANDIDATE_MANIFEST_ASSET_DIGEST" =~ ^[0-9a-f]{64}$ ]] || fail "invalid candidate manifest digest"
[[ "$QUALIFICATION_ARTIFACT_DIGEST" =~ ^[0-9a-f]{64}$ ]] || fail "invalid qualification artifact digest"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source SHA"
[ "$GITHUB_REF" = "refs/tags/${PROMOTION_TAG}" ] && [ "$GITHUB_REF_NAME" = "$PROMOTION_TAG" ] || fail "promotion must dispatch at the provisional tag"
[ "$GITHUB_SHA" = "$SOURCE_SHA" ] || fail "promotion workflow SHA differs from candidate SHA"
[ "$OPERATOR_TUI_VALIDATION" = confirmed ] || fail "operator TUI validation is not confirmed"
[ "$CONFIGURED_PROVIDER_VALIDATION" = confirmed ] || fail "configured-provider validation is not confirmed"

peel_provisional_tag
download_qualification
validate_candidate_and_qualification
validate_core_asset_set
prepare_publication_assets
publish_draft
