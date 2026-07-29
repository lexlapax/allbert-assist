#!/usr/bin/env bash
# Stateless, fail-closed promotion of already-built and qualified release bytes.
# The caller must run behind the release-promotion environment with actions:read,
# contents:write, and id-token:write. This script never checks out or builds.
set -euo pipefail
export LC_ALL=C

GH_BIN="${ALLBERT_RELEASE_GH_BIN:-gh}"
COSIGN_BIN="${ALLBERT_RELEASE_COSIGN_BIN:-cosign}"
WORK="$(mktemp -d "${RUNNER_TEMP:?RUNNER_TEMP is required}/allbert-promotion.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || {
      echo "promote-artifacts: missing $name" >&2
      exit 1
    }
  done
}

api() {
  "$GH_BIN" api "$@"
}

release_cli() {
  "$GH_BIN" release "$@"
}

sha256() {
  sha256sum "$1" | awk '{print $1}'
}

safe_extract_single() {
  local zip="$1"
  local destination="$2"
  local expected_file="$3"
  local entry
  mkdir -p "$destination"
  while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..)
      echo "promote-artifacts: unsafe ZIP entry $entry" >&2
      exit 1
      ;;
    esac
  done < <(unzip -Z1 "$zip")
  unzip -q "$zip" -d "$destination"
  [ -z "$(find "$destination" -type l -print -quit)" ]
  [ "$(find "$destination" -type f | wc -l | tr -d ' ')" -eq 1 ]
  [ -f "$destination/$expected_file" ]
}

safe_extract_archive() {
  local zip="$1"
  local destination="$2"
  local entry
  mkdir -p "$destination"
  while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..)
      echo "promote-artifacts: unsafe ZIP entry $entry" >&2
      exit 1
      ;;
    esac
  done < <(unzip -Z1 "$zip")
  unzip -q "$zip" -d "$destination"
  [ -z "$(find "$destination" -type l -print -quit)" ]
}

download_bound_evidence() {
  local role="$1"
  local artifact_id="$2"
  local expected_digest="$3"
  local expected_file="$4"
  local metadata api_digest zip
  metadata="$(api "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}")"
  [ "$(printf '%s' "$metadata" | jq -r .id)" = "$artifact_id" ]
  [ "$(printf '%s' "$metadata" | jq -r .workflow_run.id)" = "$SOURCE_RUN_ID" ]
  [ "$(printf '%s' "$metadata" | jq -r .expired)" = false ]
  api_digest="$(printf '%s' "$metadata" | jq -r '.digest // ""')"
  [ "${api_digest#sha256:}" = "$expected_digest" ]
  printf '%s' "$metadata" > "$WORK/${role}-metadata.json"

  zip="$WORK/${role}.zip"
  api -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}/zip" > "$zip"
  [ "$(sha256 "$zip")" = "$expected_digest" ]
  safe_extract_single "$zip" "$WORK/$role" "$expected_file"
}

authenticate_source() {
  local run repository repository_id workflow_id workflow source_sha
  local ref object_type object_sha tag_object peel_depth=0
  [[ "$PROMOTION_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]
  [ "$GITHUB_REF_TYPE" = tag ]
  [ "$GITHUB_REF_NAME" = "$PROMOTION_TAG" ]
  [ "$GITHUB_REF" = "refs/tags/${PROMOTION_TAG}" ]
  [[ "$SOURCE_RUN_ID" =~ ^[1-9][0-9]*$ ]]
  [[ "$SOURCE_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
  [[ "$DIGEST_ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]]
  [[ "$QUALIFICATION_ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]]
  [[ "$DIGEST_ARTIFACT_SHA256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$QUALIFICATION_ARTIFACT_SHA256" =~ ^[0-9a-f]{64}$ ]]

  run="$(api "/repos/${GITHUB_REPOSITORY}/actions/runs/${SOURCE_RUN_ID}")"
  repository="$(api "/repos/${GITHUB_REPOSITORY}")"
  repository_id="$(printf '%s' "$repository" | jq -r .id)"
  workflow_id="$(printf '%s' "$run" | jq -r .workflow_id)"
  workflow="$(api "/repos/${GITHUB_REPOSITORY}/actions/workflows/${workflow_id}")"
  [ "$(printf '%s' "$run" | jq -r .repository.id)" = "$repository_id" ]
  [ "$(printf '%s' "$run" | jq -r .repository.full_name)" = "$GITHUB_REPOSITORY" ]
  [ "$(printf '%s' "$workflow" | jq -r .path)" = "$RELEASE_WORKFLOW_PATH" ]
  [ "$(printf '%s' "$run" | jq -r .event)" = push ]
  [ "$(printf '%s' "$run" | jq -r .status)" = completed ]
  [ "$(printf '%s' "$run" | jq -r .conclusion)" = success ]
  [ "$(printf '%s' "$run" | jq -r .run_attempt)" = "$SOURCE_RUN_ATTEMPT" ]
  source_sha="$(printf '%s' "$run" | jq -r .head_sha)"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]

  ref="$(api "/repos/${GITHUB_REPOSITORY}/git/ref/tags/${PROMOTION_TAG}")"
  object_type="$(printf '%s' "$ref" | jq -r .object.type)"
  object_sha="$(printf '%s' "$ref" | jq -r .object.sha)"
  while [ "$object_type" = tag ]; do
    peel_depth=$((peel_depth + 1))
    [ "$peel_depth" -le 8 ] || {
      echo "promote-artifacts: annotated tag chain exceeds bound" >&2
      exit 1
    }
    tag_object="$(api "/repos/${GITHUB_REPOSITORY}/git/tags/${object_sha}")"
    object_type="$(printf '%s' "$tag_object" | jq -r .object.type)"
    object_sha="$(printf '%s' "$tag_object" | jq -r .object.sha)"
  done
  [ "$object_type" = commit ]
  [ "$object_sha" = "$source_sha" ]
  [ "$GITHUB_SHA" = "$source_sha" ]

  printf '%s' "$repository_id" > "$WORK/repository-id"
  printf '%s' "$workflow_id" > "$WORK/workflow-id"
  printf '%s' "$source_sha" > "$WORK/source-sha"
}

validate_evidence() {
  local repository_id workflow_id source_sha digest_manifest qualification_manifest
  local digest_name qualification_name digest_attempt digest_inner_sha
  local m0a3_id m0a3_name m0a3_digest m0a3_attempt m0a3_inner_sha m0a3_metadata
  repository_id="$(cat "$WORK/repository-id")"
  workflow_id="$(cat "$WORK/workflow-id")"
  source_sha="$(cat "$WORK/source-sha")"

  download_bound_evidence digest "$DIGEST_ARTIFACT_ID" "$DIGEST_ARTIFACT_SHA256" \
    digest-manifest.json
  download_bound_evidence qualification "$QUALIFICATION_ARTIFACT_ID" \
    "$QUALIFICATION_ARTIFACT_SHA256" qualification-evidence-manifest.json
  digest_manifest="$WORK/digest/digest-manifest.json"
  qualification_manifest="$WORK/qualification/qualification-evidence-manifest.json"
  digest_name="$(jq -r .name "$WORK/digest-metadata.json")"
  qualification_name="$(jq -r .name "$WORK/qualification-metadata.json")"
  digest_attempt="$(jq -r .source_run.attempt "$digest_manifest")"
  [ "$digest_name" = "source-${SOURCE_RUN_ID}-a${digest_attempt}-digest-manifest" ]
  [ "$qualification_name" = "source-${SOURCE_RUN_ID}-a${SOURCE_RUN_ATTEMPT}-qualification-evidence" ]

  jq -e \
    --argjson repository_id "$repository_id" --arg repository_name "$GITHUB_REPOSITORY" \
    --argjson workflow_id "$workflow_id" --arg workflow_path "$RELEASE_WORKFLOW_PATH" \
    --arg tag "$PROMOTION_TAG" --arg ref "$GITHUB_REF" --arg source_sha "$source_sha" \
    --argjson source_run_id "$SOURCE_RUN_ID" --argjson latest_attempt "$SOURCE_RUN_ATTEMPT" \
    '.schema_version == 1 and .kind == "allbert-release-digest-manifest" and
     .repository == {id: $repository_id, full_name: $repository_name} and
     .workflow == {id: $workflow_id, path: $workflow_path} and .event == "push" and
     .tag == $tag and .ref == $ref and .ref_type == "tag" and .ref_name == $tag and
     .source_sha == $source_sha and .source_run.id == $source_run_id and
     (.source_run.attempt | type == "number") and .source_run.attempt <= $latest_attempt and
     (.archives | length == 3) and
     ([.archives[].target] | sort == ["linux-arm64", "linux-x64", "macos-arm64"])' \
    "$digest_manifest" >/dev/null

  digest_inner_sha="$(sha256 "$digest_manifest")"
  jq -e \
    --argjson repository_id "$repository_id" --arg repository_name "$GITHUB_REPOSITORY" \
    --argjson workflow_id "$workflow_id" --arg workflow_path "$RELEASE_WORKFLOW_PATH" \
    --arg tag "$PROMOTION_TAG" --arg ref "$GITHUB_REF" --arg source_sha "$source_sha" \
    --argjson source_run_id "$SOURCE_RUN_ID" --argjson source_run_attempt "$SOURCE_RUN_ATTEMPT" \
    --argjson digest_artifact_id "$DIGEST_ARTIFACT_ID" \
    --arg digest_artifact_name "$digest_name" --arg digest_artifact_digest "$DIGEST_ARTIFACT_SHA256" \
    --argjson digest_attempt "$digest_attempt" --arg digest_inner_sha "$digest_inner_sha" \
    '.schema_version == 1 and .kind == "allbert-release-qualification-manifest" and
     .repository == {id: $repository_id, full_name: $repository_name} and
     .workflow == {id: $workflow_id, path: $workflow_path} and .event == "push" and
     .tag == $tag and .ref == $ref and .ref_type == "tag" and .ref_name == $tag and
     .source_sha == $source_sha and
     .source_run == {id: $source_run_id, attempt: $source_run_attempt} and
     .digest_manifest == {artifact_id: $digest_artifact_id,
       artifact_name: $digest_artifact_name, artifact_digest: $digest_artifact_digest,
       producer_run_attempt: $digest_attempt,
       manifest_sha256: $digest_inner_sha} and
     $digest_attempt <= $source_run_attempt and
     (.m0a3_evidence.artifact_id | type == "number") and
     (.m0a3_evidence.artifact_name | type == "string") and
     (.m0a3_evidence.artifact_digest | test("^[0-9a-f]{64}$")) and
     (.m0a3_evidence.producer_run_attempt | type == "number") and
     .m0a3_evidence.producer_run_attempt <= $source_run_attempt and
     (.m0a3_evidence.evidence_sha256 | test("^[0-9a-f]{64}$")) and
     (.archives | length == 3) and
     (all(.archives[];
       (.m0a3_qualification_run_attempt | type == "number") and
       .m0a3_qualification_run_attempt >= 1 and
       .m0a3_qualification_run_attempt <= $source_run_attempt and
       (.fv_run_attempt | type == "number") and .fv_run_attempt >= 1 and
       .fv_run_attempt <= $source_run_attempt and
       .qualifications.license == "passed" and
       .qualifications.source_availability == "passed" and
       .qualifications.protocol_tty == "passed" and
       (.fv_evidence | keys == ["protocol_tty_sha256", "provider_receipt_sha256"]) and
       (.fv_evidence.protocol_tty_sha256 | test("^[0-9a-f]{64}$")) and
       .fv_evidence.provider_receipt_sha256 == null and
       .qualifications.provider == "not_required"))' \
    "$qualification_manifest" >/dev/null

  jq -S '[.archives[] | {artifact_id, artifact_name, artifact_digest,
    producer_run_attempt, target, archive_name, sha256,
    artifact_created_at, toolchain_name, toolchain_sha256}] | sort_by(.target)' \
    "$digest_manifest" > "$WORK/digest-rows.json"
  jq -S '[.archives[] | {artifact_id, artifact_name, artifact_digest,
    producer_run_attempt, target, archive_name, sha256,
    artifact_created_at, toolchain_name, toolchain_sha256}] | sort_by(.target)' \
    "$qualification_manifest" > "$WORK/qualification-rows.json"
  cmp "$WORK/digest-rows.json" "$WORK/qualification-rows.json"

  m0a3_id="$(jq -r .m0a3_evidence.artifact_id "$qualification_manifest")"
  m0a3_name="$(jq -r .m0a3_evidence.artifact_name "$qualification_manifest")"
  m0a3_digest="$(jq -r .m0a3_evidence.artifact_digest "$qualification_manifest")"
  m0a3_attempt="$(jq -r .m0a3_evidence.producer_run_attempt "$qualification_manifest")"
  m0a3_inner_sha="$(jq -r .m0a3_evidence.evidence_sha256 "$qualification_manifest")"
  [[ "$m0a3_id" =~ ^[1-9][0-9]*$ ]]
  [[ "$m0a3_attempt" =~ ^[1-9][0-9]*$ ]]
  [ "$m0a3_attempt" -le "$SOURCE_RUN_ATTEMPT" ]
  m0a3_metadata="$(api "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${m0a3_id}")"
  [ "$(printf '%s' "$m0a3_metadata" | jq -r .id)" = "$m0a3_id" ]
  [ "$(printf '%s' "$m0a3_metadata" | jq -r .workflow_run.id)" = "$SOURCE_RUN_ID" ]
  [ "$(printf '%s' "$m0a3_metadata" | jq -r .name)" = "$m0a3_name" ]
  [ "$m0a3_name" = "source-${SOURCE_RUN_ID}-a${m0a3_attempt}-m0a3-evidence" ]
  [ "$(printf '%s' "$m0a3_metadata" | jq -r .expired)" = false ]
  [ "$(printf '%s' "$m0a3_metadata" | jq -r '.digest // ""' | sed 's/^sha256://')" = "$m0a3_digest" ]
  api -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${m0a3_id}/zip" > "$WORK/m0a3.zip"
  [ "$(sha256 "$WORK/m0a3.zip")" = "$m0a3_digest" ]
  safe_extract_single "$WORK/m0a3.zip" "$WORK/m0a3" m0a3-evidence.json
  [ "$(sha256 "$WORK/m0a3/m0a3-evidence.json")" = "$m0a3_inner_sha" ]

  jq -e \
    --argjson repository_id "$repository_id" --arg repository_name "$GITHUB_REPOSITORY" \
    --argjson workflow_id "$workflow_id" --arg workflow_path "$RELEASE_WORKFLOW_PATH" \
    --arg tag "$PROMOTION_TAG" --arg ref "$GITHUB_REF" --arg source_sha "$source_sha" \
    --argjson source_run_id "$SOURCE_RUN_ID" --argjson m0a3_attempt "$m0a3_attempt" \
    --argjson digest_artifact_id "$DIGEST_ARTIFACT_ID" \
    --arg digest_artifact_name "$digest_name" --arg digest_artifact_digest "$DIGEST_ARTIFACT_SHA256" \
    --argjson digest_attempt "$digest_attempt" --arg digest_inner_sha "$digest_inner_sha" \
    '.schema_version == 1 and .kind == "allbert-release-m0a3-evidence" and
     .repository == {id: $repository_id, full_name: $repository_name} and
     .workflow == {id: $workflow_id, path: $workflow_path} and .event == "push" and
     .tag == $tag and .ref == $ref and .ref_type == "tag" and .ref_name == $tag and
     .source_sha == $source_sha and
     .source_run == {id: $source_run_id, attempt: $m0a3_attempt} and
     .digest_manifest == {artifact_id: $digest_artifact_id,
       artifact_name: $digest_artifact_name, artifact_digest: $digest_artifact_digest,
       producer_run_attempt: $digest_attempt, manifest_sha256: $digest_inner_sha} and
     (.archives | length == 3) and
     ([.archives[].target] | sort == ["linux-arm64", "linux-x64", "macos-arm64"]) and
     (all(.archives[];
       (.qualification_run_attempt | type == "number") and
       .qualification_run_attempt >= 1 and .qualification_run_attempt <= $m0a3_attempt and
       .qualifications == {license: "passed", source_availability: "passed"} and
       (.license_evidence.packaged_manifest_sha256 | test("^[0-9a-f]{64}$")) and
       (.license_evidence.source.sha256 | test("^[0-9a-f]{64}$")) and
       (.license_evidence.converter.sha256 | test("^[0-9a-f]{64}$"))))' \
    "$WORK/m0a3/m0a3-evidence.json" >/dev/null

  jq -S '[.archives[] | del(.qualification_run_attempt, .qualifications, .license_evidence)] | sort_by(.target)' \
    "$WORK/m0a3/m0a3-evidence.json" > "$WORK/m0a3-rows.json"
  cmp "$WORK/digest-rows.json" "$WORK/m0a3-rows.json"
  jq -S '[.archives[] | {target,
    m0a3_qualification_run_attempt: .qualification_run_attempt,
    license: .qualifications.license,
    source_availability: .qualifications.source_availability}] | sort_by(.target)' \
    "$WORK/m0a3/m0a3-evidence.json" > "$WORK/m0a3-outcomes.json"
  jq -S '[.archives[] | {target,
    m0a3_qualification_run_attempt: .m0a3_qualification_run_attempt,
    license: .qualifications.license,
    source_availability: .qualifications.source_availability}] | sort_by(.target)' \
    "$qualification_manifest" > "$WORK/qualification-license-outcomes.json"
  cmp "$WORK/m0a3-outcomes.json" "$WORK/qualification-license-outcomes.json"
}

collect_archives() {
  local digest_manifest="$WORK/digest/digest-manifest.json"
  local now max_age_seconds
  local artifact_id artifact_name artifact_digest producer_attempt target archive_name archive_sha
  local created toolchain_name toolchain_sha metadata created_epoch age jobs zip root
  mkdir -p "$WORK/publish"
  now="${ALLBERT_RELEASE_NOW_EPOCH:-$(date -u +%s)}"
  max_age_seconds=$((MAX_NATIVE_ARTIFACT_AGE_DAYS * 86400))

  while IFS=$'\t' read -r artifact_id artifact_name artifact_digest producer_attempt target archive_name archive_sha created toolchain_name toolchain_sha; do
    [[ "$artifact_id" =~ ^[1-9][0-9]*$ ]]
    [ "$artifact_name" = "source-${SOURCE_RUN_ID}-a${producer_attempt}-${target}-archive" ]
    [ "$archive_name" = "allbert-${PROMOTION_TAG}-${target}.tar.gz" ]
    metadata="$(api "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}")"
    [ "$(printf '%s' "$metadata" | jq -r .id)" = "$artifact_id" ]
    [ "$(printf '%s' "$metadata" | jq -r .workflow_run.id)" = "$SOURCE_RUN_ID" ]
    [ "$(printf '%s' "$metadata" | jq -r .name)" = "$artifact_name" ]
    [ "$(printf '%s' "$metadata" | jq -r .created_at)" = "$created" ]
    [ "$(printf '%s' "$metadata" | jq -r .expired)" = false ]
    [ "$(printf '%s' "$metadata" | jq -r '.digest // ""' | sed 's/^sha256://')" = "$artifact_digest" ]
    created_epoch="$(date -u -d "$created" +%s)"
    age=$((now - created_epoch))
    [ "$age" -ge 0 ]
    [ "$age" -le "$max_age_seconds" ] || {
      echo "promote-artifacts: $artifact_name exceeds the ${MAX_NATIVE_ARTIFACT_AGE_DAYS}-day window" >&2
      exit 1
    }

    jobs="$(api --paginate --slurp \
      "/repos/${GITHUB_REPOSITORY}/actions/runs/${SOURCE_RUN_ID}/attempts/${producer_attempt}/jobs?per_page=100")"
    [ "$(printf '%s' "$jobs" | jq --arg name "build-${target}" \
      '[.[].jobs[] | select(.name == $name and .conclusion == "success" and
        ([.steps[]? | select(.name == "Upload immutable native archive" and
          .conclusion == "success")] | length) == 1)] | length')" -eq 1 ]

    zip="$WORK/archive-${target}.zip"
    root="$WORK/archive-${target}"
    api -H "Accept: application/vnd.github+json" \
      "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}/zip" > "$zip"
    [ "$(sha256 "$zip")" = "$artifact_digest" ]
    safe_extract_archive "$zip" "$root"
    [ "$(find "$root" -type f | wc -l | tr -d ' ')" -eq 2 ]
    [ "$(sha256 "$root/$archive_name")" = "$archive_sha" ]
    [ "$(sha256 "$root/$toolchain_name")" = "$toolchain_sha" ]
    cp "$root/$archive_name" "$WORK/publish/$archive_name"
  done < <(jq -r '.archives[] | [.artifact_id, .artifact_name, .artifact_digest,
    .producer_run_attempt, .target, .archive_name, .sha256,
    .artifact_created_at, .toolchain_name, .toolchain_sha256] | @tsv' "$digest_manifest")

  for target in linux-arm64 linux-x64 macos-arm64; do
    cp "$WORK/publish/allbert-${PROMOTION_TAG}-${target}.tar.gz" \
      "$WORK/publish/allbert-${target}.tar.gz"
  done
  (
    cd "$WORK/publish"
    find . -maxdepth 1 -type f -name '*.tar.gz' -print \
      | sed 's|^./||' | LC_ALL=C sort \
      | while IFS= read -r asset; do
          printf '%s  %s\n' "$(sha256 "$asset")" "$asset"
        done > SHA256SUMS
  )
}

list_assets() {
  api --paginate --slurp \
    "/repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?per_page=100" \
    | jq -c '[.[][]]'
}

compare_or_upload() {
  local name="$1"
  local path="$2"
  local assets count asset_id existing expected actual
  assets="$(list_assets)"
  count="$(printf '%s' "$assets" | jq --arg name "$name" '[.[] | select(.name == $name)] | length')"
  case "$count" in
    0) release_cli upload "$PROMOTION_TAG" "$path" --repo "$GITHUB_REPOSITORY" ;;
    1)
      asset_id="$(printf '%s' "$assets" | jq -r --arg name "$name" '.[] | select(.name == $name) | .id')"
      existing="$WORK/existing-${name}"
      api -H "Accept: application/octet-stream" \
        "/repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}" > "$existing"
      expected="$(sha256 "$path")"
      actual="$(sha256 "$existing")"
      [ "$actual" = "$expected" ] || {
        echo "promote-artifacts: existing asset $name differs; refusing replacement" >&2
        exit 1
      }
      ;;
    *) echo "promote-artifacts: duplicate release asset $name" >&2; exit 1 ;;
  esac
}

publish() {
  local prerelease release expected_names current_assets existing_name asset
  local assets bundle_count identity bundle_id
  prerelease=false
  case "$PROMOTION_TAG" in *-*) prerelease=true ;; esac

  if release="$(api "/repos/${GITHUB_REPOSITORY}/releases/tags/${PROMOTION_TAG}" 2>/dev/null)"; then
    [ "$(printf '%s' "$release" | jq -r .tag_name)" = "$PROMOTION_TAG" ]
    [ "$(printf '%s' "$release" | jq -r .prerelease)" = "$prerelease" ]
    case "$(printf '%s' "$release" | jq -r .draft)" in
      true|false) ;;
      *) echo "promote-artifacts: existing release has incompatible draft state" >&2; exit 1 ;;
    esac
  else
    args=("$PROMOTION_TAG" --repo "$GITHUB_REPOSITORY" --title "$PROMOTION_TAG" \
      --generate-notes --verify-tag --draft)
    [ "$prerelease" = false ] || args+=(--prerelease)
    release_cli create "${args[@]}"
    release="$(api "/repos/${GITHUB_REPOSITORY}/releases/tags/${PROMOTION_TAG}")"
  fi
  release_id="$(printf '%s' "$release" | jq -r .id)"
  [[ "$release_id" =~ ^[1-9][0-9]*$ ]]

  expected_names="$WORK/expected-assets.txt"
  {
    find "$WORK/publish" -maxdepth 1 -type f -name '*.tar.gz' -exec basename {} \;
    echo SHA256SUMS
    echo SHA256SUMS.cosign.bundle
  } | LC_ALL=C sort > "$expected_names"

  current_assets="$(list_assets)"
  while IFS= read -r existing_name; do
    grep -Fxq "$existing_name" "$expected_names" || {
      echo "promote-artifacts: unexpected existing asset $existing_name" >&2
      exit 1
    }
  done < <(printf '%s' "$current_assets" | jq -r '.[].name')

  while IFS= read -r asset; do
    [ "$asset" = SHA256SUMS.cosign.bundle ] && continue
    compare_or_upload "$asset" "$WORK/publish/$asset"
  done < "$expected_names"

  assets="$(list_assets)"
  bundle_count="$(printf '%s' "$assets" | jq \
    '[.[] | select(.name == "SHA256SUMS.cosign.bundle")] | length')"
  identity="https://github.com/${GITHUB_REPOSITORY}/${RELEASE_WORKFLOW_PATH}@refs/tags/${PROMOTION_TAG}"
  if [ "$bundle_count" -eq 0 ]; then
    "$COSIGN_BIN" sign-blob --yes --bundle "$WORK/publish/SHA256SUMS.cosign.bundle" \
      "$WORK/publish/SHA256SUMS"
    compare_or_upload SHA256SUMS.cosign.bundle "$WORK/publish/SHA256SUMS.cosign.bundle"
  elif [ "$bundle_count" -eq 1 ]; then
    bundle_id="$(printf '%s' "$assets" | jq -r \
      '.[] | select(.name == "SHA256SUMS.cosign.bundle") | .id')"
    api -H "Accept: application/octet-stream" \
      "/repos/${GITHUB_REPOSITORY}/releases/assets/${bundle_id}" \
      > "$WORK/publish/SHA256SUMS.cosign.bundle"
  else
    echo "promote-artifacts: duplicate cosign bundle" >&2
    exit 1
  fi
  "$COSIGN_BIN" verify-blob \
    --bundle "$WORK/publish/SHA256SUMS.cosign.bundle" \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "$WORK/publish/SHA256SUMS" >/dev/null

  assets="$(list_assets)"
  [ "$(printf '%s' "$assets" | jq 'length')" -eq "$(wc -l < "$expected_names" | tr -d ' ')" ]
  while IFS= read -r asset; do
    [ "$(printf '%s' "$assets" | jq --arg name "$asset" \
      '[.[] | select(.name == $name)] | length')" -eq 1 ]
  done < "$expected_names"
  if [ "$(printf '%s' "$release" | jq -r .draft)" = true ]; then
    release_cli edit "$PROMOTION_TAG" --repo "$GITHUB_REPOSITORY" --draft=false
  fi
}

require_env GITHUB_REPOSITORY GITHUB_REF GITHUB_REF_TYPE GITHUB_REF_NAME GITHUB_SHA \
  RELEASE_WORKFLOW_PATH MAX_NATIVE_ARTIFACT_AGE_DAYS PROMOTION_TAG SOURCE_RUN_ID \
  SOURCE_RUN_ATTEMPT DIGEST_ARTIFACT_ID DIGEST_ARTIFACT_SHA256 \
  QUALIFICATION_ARTIFACT_ID QUALIFICATION_ARTIFACT_SHA256

authenticate_source
validate_evidence
collect_archives
publish
