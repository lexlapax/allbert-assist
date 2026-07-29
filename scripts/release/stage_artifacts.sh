#!/usr/bin/env bash
# Stateless v1.2.2 source-run artifact selection and digest-manifest composer.
# Every lookup is scoped to GITHUB_RUN_ID and every accepted archive is tied to
# one successful build-<target> job attempt. No artifact is selected by latest.
set -euo pipefail

GH_BIN="${ALLBERT_RELEASE_GH_BIN:-gh}"
TARGETS=(linux-arm64 linux-x64 macos-arm64)

require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || {
      echo "stage-artifacts: missing $name" >&2
      exit 1
    }
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

artifact_pages() {
  api --paginate --slurp \
    "/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts?per_page=100"
}

attempt_jobs() {
  local attempt="$1"
  api --paginate --slurp \
    "/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${attempt}/jobs?per_page=100"
}

producer_attempts() {
  local target="$1"
  local attempt jobs producers

  attempt=1
  while [ "$attempt" -le "$GITHUB_RUN_ATTEMPT" ]; do
    jobs="$(attempt_jobs "$attempt")" || return 1
    producers="$(printf '%s' "$jobs" | jq --arg name "build-${target}" \
      '[.[].jobs[] | select(.name == $name and .conclusion == "success" and
        ([.steps[]? | select(.name == "Upload immutable native archive" and
          .conclusion == "success")] | length) == 1)] | length')" || return 1
    [ "$producers" -le 1 ] || {
      echo "stage-artifacts: duplicate successful producer jobs for ${target} attempt ${attempt}" >&2
      exit 1
    }
    [ "$producers" -eq 0 ] || printf '%s\n' "$attempt"
    attempt=$((attempt + 1))
  done
}

accepted_artifact() {
  local target="$1"
  local artifacts producers producer_count producer_attempt expected_name matches artifact_count
  local accepted_id accepted_name accepted_digest accepted_created expired
  producers="$(producer_attempts "$target")" || return 1
  producer_count="$(printf '%s\n' "$producers" | awk 'NF {count += 1} END {print count + 0}')"

  [ "$producer_count" -le 1 ] || {
    echo "stage-artifacts: multiple successful ${target} producer attempts in run ${GITHUB_RUN_ID}" >&2
    exit 1
  }
  [ "$producer_count" -eq 1 ] || return 4
  producer_attempt="$(printf '%s\n' "$producers" | awk 'NF {print; exit}')"
  expected_name="source-${GITHUB_RUN_ID}-a${producer_attempt}-${target}-archive"

  artifacts="$(artifact_pages | jq -c '[.[].artifacts[]]')" || return 1
  matches="$(printf '%s' "$artifacts" | jq -c --arg name "$expected_name" \
    '[.[] | select(.name == $name)]')" || return 1
  artifact_count="$(printf '%s' "$matches" | jq 'length')" || return 1
  [ "$artifact_count" -eq 1 ] || {
    echo "stage-artifacts: successful ${target} producer attempt ${producer_attempt} requires exactly one extant artifact; found ${artifact_count}" >&2
    exit 1
  }

  accepted_id="$(printf '%s' "$matches" | jq -r '.[0].id')"
  accepted_name="$(printf '%s' "$matches" | jq -r '.[0].name')"
  accepted_digest="$(printf '%s' "$matches" | jq -r '.[0].digest // ""' | sed 's/^sha256://')"
  accepted_created="$(printf '%s' "$matches" | jq -r '.[0].created_at')"
  expired="$(printf '%s' "$matches" | jq -r '.[0].expired')"
  [[ "$accepted_id" =~ ^[1-9][0-9]*$ ]] || {
    echo "stage-artifacts: invalid artifact id for ${target}" >&2
    return 1
  }
  [ "$expired" = false ] || {
    echo "stage-artifacts: successful ${target} producer artifact is expired" >&2
    exit 1
  }
  [[ "$accepted_digest" =~ ^[0-9a-f]{64}$ ]] || {
    echo "stage-artifacts: invalid artifact digest for ${target}" >&2
    return 1
  }

  jq -S -n \
    --argjson artifact_id "$accepted_id" \
    --arg artifact_name "$accepted_name" \
    --arg artifact_digest "$accepted_digest" \
    --arg artifact_created_at "$accepted_created" \
    --argjson producer_run_attempt "$producer_attempt" \
    '{artifact_id: $artifact_id, artifact_name: $artifact_name,
      artifact_digest: $artifact_digest, artifact_created_at: $artifact_created_at,
      producer_run_attempt: $producer_run_attempt}'
}

validate_toolchain() {
  local target="$1"
  local file="$2"
  jq -e \
    --arg target "$target" --arg source_sha "$GITHUB_SHA" \
    --arg setup_sha "$SETUP_BEAM_SHA" --arg otp "$OTP_VERSION" \
    --arg elixir "$ELIXIR_VERSION" --arg rebar3 "$REBAR3_VERSION" \
    --arg hex "$HEX_VERSION" \
    '.schema_version == 1 and .target == $target and .source_sha == $source_sha and
     .setup_beam.action_sha == $setup_sha and .setup_beam.version_type == "strict" and
     .setup_beam.reported_action_revision == "ea45c80" and
     .setup_beam.otp.input == $otp and .setup_beam.elixir.input == $elixir and
     .setup_beam.rebar3.input == $rebar3 and .hex.input == $hex and
     .setup_beam.otp.resolved == ("OTP-" + $otp) and
     .setup_beam.elixir.resolved == ("v" + $elixir + "-otp-" + ($otp | split(".")[0])) and
     .setup_beam.rebar3.resolved == $rebar3 and .hex.resolved == $hex and
     .runtime.otp == $otp and .runtime.elixir == $elixir and
     (.runtime.erts | type == "string" and length > 0)' \
    "$file" >/dev/null
}

safe_extract_artifact() {
  local artifact_json="$1"
  local destination="$2"
  local id name digest metadata zip entry
  id="$(printf '%s' "$artifact_json" | jq -r .artifact_id)"
  name="$(printf '%s' "$artifact_json" | jq -r .artifact_name)"
  digest="$(printf '%s' "$artifact_json" | jq -r .artifact_digest)"
  zip="${destination}.zip"
  [ ! -e "$destination" ]
  mkdir -p "$destination"
  metadata="$(api "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${id}")"
  [ "$(printf '%s' "$metadata" | jq -r .id)" = "$id" ]
  [ "$(printf '%s' "$metadata" | jq -r .name)" = "$name" ]
  [ "$(printf '%s' "$metadata" | jq -r .workflow_run.id)" = "$GITHUB_RUN_ID" ]
  [ "$(printf '%s' "$metadata" | jq -r .expired)" = false ]
  [ "$(printf '%s' "$metadata" | jq -r '.digest // ""' | sed 's/^sha256://')" = "$digest" ]
  api -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${id}/zip" > "$zip"
  [ "$(sha256_file "$zip")" = "$digest" ] || {
    echo "stage-artifacts: artifact $id ZIP digest mismatch" >&2
    exit 1
  }
  while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..)
      echo "stage-artifacts: unsafe ZIP entry $entry" >&2
      exit 1
      ;;
    esac
  done < <(unzip -Z1 "$zip")
  unzip -q "$zip" -d "$destination"
  [ -z "$(find "$destination" -type l -print -quit)" ]
}

download_bound_single() {
  local artifact_id="$1"
  local artifact_digest="$2"
  local expected_file="$3"
  local destination="$4"
  local metadata_output="$5"
  local metadata zip entry
  [[ "$artifact_id" =~ ^[1-9][0-9]*$ ]]
  [[ "$artifact_digest" =~ ^[0-9a-f]{64}$ ]]
  [ ! -e "$destination" ]
  metadata="$(api "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}")"
  [ "$(printf '%s' "$metadata" | jq -r .id)" = "$artifact_id" ]
  [ "$(printf '%s' "$metadata" | jq -r .workflow_run.id)" = "$GITHUB_RUN_ID" ]
  [ "$(printf '%s' "$metadata" | jq -r .expired)" = false ]
  [ "$(printf '%s' "$metadata" | jq -r '.digest // ""' | sed 's/^sha256://')" = "$artifact_digest" ]
  printf '%s' "$metadata" > "$metadata_output"
  zip="${destination}.zip"
  api -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}/zip" > "$zip"
  [ "$(sha256_file "$zip")" = "$artifact_digest" ]
  mkdir -p "$destination"
  while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..)
      echo "stage-artifacts: unsafe ZIP entry $entry" >&2
      exit 1
      ;;
    esac
  done < <(unzip -Z1 "$zip")
  unzip -q "$zip" -d "$destination"
  [ -z "$(find "$destination" -type l -print -quit)" ]
  [ "$(find "$destination" -type f | wc -l | tr -d ' ')" -eq 1 ]
  [ -f "$destination/$expected_file" ]
}

validate_digest_manifest() {
  local manifest="$1"
  local metadata="$2"
  local run workflow workflow_id repository_id attempt artifact_name
  run="$(api "/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}")"
  workflow_id="$(printf '%s' "$run" | jq -r .workflow_id)"
  workflow="$(api "/repos/${GITHUB_REPOSITORY}/actions/workflows/${workflow_id}")"
  repository_id="$(printf '%s' "$run" | jq -r .repository.id)"
  [ "$(printf '%s' "$run" | jq -r .repository.full_name)" = "$GITHUB_REPOSITORY" ]
  [ "$(printf '%s' "$run" | jq -r .event)" = push ]
  [ "$(printf '%s' "$run" | jq -r .head_sha)" = "$GITHUB_SHA" ]
  [ "$(printf '%s' "$run" | jq -r .run_attempt)" = "$GITHUB_RUN_ATTEMPT" ]
  [ "$(printf '%s' "$workflow" | jq -r .path)" = "$RELEASE_WORKFLOW_PATH" ]
  attempt="$(jq -r .source_run.attempt "$manifest")"
  artifact_name="source-${GITHUB_RUN_ID}-a${attempt}-digest-manifest"
  [ "$(jq -r .name "$metadata")" = "$artifact_name" ]

  jq -e \
    --argjson repository_id "$repository_id" --arg repository_name "$GITHUB_REPOSITORY" \
    --argjson workflow_id "$workflow_id" --arg workflow_path "$RELEASE_WORKFLOW_PATH" \
    --arg tag "$GITHUB_REF_NAME" --arg ref "$GITHUB_REF" --arg source_sha "$GITHUB_SHA" \
    --argjson source_run_id "$GITHUB_RUN_ID" --argjson current_attempt "$GITHUB_RUN_ATTEMPT" \
    '.schema_version == 1 and .kind == "allbert-release-digest-manifest" and
     .repository == {id: $repository_id, full_name: $repository_name} and
     .workflow == {id: $workflow_id, path: $workflow_path} and .event == "push" and
     .tag == $tag and .ref == $ref and .ref_type == "tag" and .ref_name == $tag and
     .source_sha == $source_sha and .source_run.id == $source_run_id and
     (.source_run.attempt | type == "number") and .source_run.attempt >= 1 and
     .source_run.attempt <= $current_attempt and (.archives | length == 3) and
     ([.archives[].target] | sort == ["linux-arm64", "linux-x64", "macos-arm64"]) and
     (all(.archives[];
       (.artifact_id | type == "number") and .artifact_id >= 1 and
       (.producer_run_attempt | type == "number") and .producer_run_attempt >= 1 and
       .producer_run_attempt <= $current_attempt and
       .artifact_name == ("source-" + ($source_run_id | tostring) + "-a" +
         (.producer_run_attempt | tostring) + "-" + .target + "-archive") and
       (.artifact_digest | test("^[0-9a-f]{64}$")) and
       .archive_name == ("allbert-" + $tag + "-" + .target + ".tar.gz") and
       (.sha256 | test("^[0-9a-f]{64}$")) and
       (.artifact_created_at | type == "string") and
       .toolchain_name == ("toolchain-" + .target + ".json") and
       (.toolchain_sha256 | test("^[0-9a-f]{64}$"))))' "$manifest" >/dev/null
}

open_digest_manifest() {
  local artifact_id="$1"
  local artifact_digest="$2"
  local work="$3"
  download_bound_single "$artifact_id" "$artifact_digest" digest-manifest.json \
    "$work/digest" "$work/digest-metadata.json"
  validate_digest_manifest "$work/digest/digest-manifest.json" "$work/digest-metadata.json"
}

download_target_artifact() {
  local target="$1"
  local manifest="$2"
  local destination="$3"
  local accepted selected
  local archive_name toolchain_name archive_sha toolchain_sha
  accepted="$(accepted_artifact "$target")" || {
    echo "stage-artifacts: no successful ${target} archive" >&2
    exit 1
  }
  selected="$(jq -c --arg target "$target" '.archives[] | select(.target == $target)' "$manifest")"
  [ -n "$selected" ]
  printf '%s' "$accepted" | jq -S \
    '{artifact_id, artifact_name, artifact_digest, artifact_created_at,
      producer_run_attempt}' > "${destination}.accepted.json"
  printf '%s' "$selected" | jq -S \
    '{artifact_id, artifact_name, artifact_digest, artifact_created_at,
      producer_run_attempt}' > "${destination}.selected.json"
  cmp "${destination}.accepted.json" "${destination}.selected.json"
  safe_extract_artifact "$accepted" "$destination"
  archive_name="$(printf '%s' "$selected" | jq -r .archive_name)"
  toolchain_name="$(printf '%s' "$selected" | jq -r .toolchain_name)"
  archive_sha="$(printf '%s' "$selected" | jq -r .sha256)"
  toolchain_sha="$(printf '%s' "$selected" | jq -r .toolchain_sha256)"
  [ "$(find "$destination" -type f | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(sha256_file "$destination/$archive_name")" = "$archive_sha" ]
  [ "$(sha256_file "$destination/$toolchain_name")" = "$toolchain_sha" ]
  validate_toolchain "$target" "$destination/$toolchain_name"
}

validate_release_path() {
  local entry="$1"
  case "$entry" in
    ""|/*|..|../*|*/../*|*/..|*[[:space:]]*)
      echo "stage-artifacts: unsafe release archive entry $entry" >&2
      return 1
      ;;
  esac
  case "$entry" in
    allbert|allbert/*) ;;
    *)
      echo "stage-artifacts: unsafe release archive entry $entry" >&2
      return 1
      ;;
  esac
}

validate_release_link() {
  local type="$1"
  local member="$2"
  local target="$3"
  local combined part
  local -a parts stack
  validate_release_path "$member"
  case "$target" in
    ""|/*|*[[:space:]]*)
      echo "stage-artifacts: unsafe release archive link $member -> $target" >&2
      return 1
      ;;
  esac
  case "$type" in
    symlink) combined="${member%/*}/$target" ;;
    hardlink) combined="$target" ;;
    *) echo "stage-artifacts: unknown release archive link type $type" >&2; return 1 ;;
  esac
  IFS='/' read -r -a parts <<< "$combined"
  stack=()
  for part in "${parts[@]}"; do
    case "$part" in
      ""|.) ;;
      ..)
        [ "${#stack[@]}" -gt 1 ] || {
          echo "stage-artifacts: unsafe release archive link $member -> $target" >&2
          return 1
        }
        unset "stack[$((${#stack[@]} - 1))]"
        ;;
      *) stack+=("$part") ;;
    esac
  done
  [ "${stack[0]:-}" = allbert ] || {
    echo "stage-artifacts: unsafe release archive link $member -> $target" >&2
    return 1
  }
}

preflight_release_archive() {
  local archive="$1"
  local before after entry listing type prefix member target
  before="$(sha256_file "$archive")"
  while IFS= read -r entry; do
    validate_release_path "$entry"
  done < <(tar -tzf "$archive")
  while IFS= read -r listing; do
    type="${listing:0:1}"
    case "$type" in
      -|d) ;;
      l)
        case "$listing" in
          *" -> "*)
            prefix="${listing%% -> *}"
            member="${prefix##* }"
            target="${listing##* -> }"
            validate_release_link symlink "$member" "$target"
            ;;
          *) echo "stage-artifacts: malformed release archive symlink" >&2; return 1 ;;
        esac
        ;;
      h)
        case "$listing" in
          *" link to "*)
            prefix="${listing%% link to *}"
            member="${prefix##* }"
            target="${listing##* link to }"
            validate_release_link hardlink "$member" "$target"
            ;;
          *) echo "stage-artifacts: malformed release archive hardlink" >&2; return 1 ;;
        esac
        ;;
      *) echo "stage-artifacts: unsafe release archive entry type $type" >&2; return 1 ;;
    esac
  done < <(tar -tvzf "$archive")
  after="$(sha256_file "$archive")"
  [ "$before" = "$after" ] || {
    echo "stage-artifacts: release archive changed during preflight" >&2
    return 1
  }
}

extract_release() {
  local archive="$1"
  local destination="$2"
  [ ! -e "$destination" ]
  preflight_release_archive "$archive"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination"
  [ -x "$destination/allbert/bin/allbert" ]
}

qualify_license() {
  local target="$1"
  local digest_id="$2"
  local digest_sha="$3"
  local output="$4"
  local work manifest archive_name release_root viewer manifest_sha openssl_bundled
  local source_url source_expected source_actual converter_url converter_expected converter_actual
  work="$(mktemp -d)"
  register_cleanup "$work"
  open_digest_manifest "$digest_id" "$digest_sha" "$work"
  manifest="$work/digest/digest-manifest.json"
  download_target_artifact "$target" "$manifest" "$work/archive"
  archive_name="$(jq -r --arg target "$target" \
    '.archives[] | select(.target == $target) | .archive_name' "$manifest")"
  extract_release "$work/archive/$archive_name" "$work/release"
  release_root="$work/release/allbert"
  viewer="$release_root/bin/allbert"
  mkdir -p "$work/home" "$(dirname "$output")"
  for required in LICENSE NOTICE THIRD-PARTY-LICENSES.md THIRD-PARTY-MANIFEST.json; do
    [ -f "$release_root/$required" ]
  done

  (cd "$work" && env -i HOME="$work" ALLBERT_HOME="$work/home" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh LANG=C.UTF-8 \
    "$viewer" licenses summary) > "$work/summary.txt"
  (cd "$work" && env -i HOME="$work" ALLBERT_HOME="$work/home" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh LANG=C.UTF-8 \
    "$viewer" licenses --json) > "$work/licenses.json"
  (cd "$work" && env -i HOME="$work" ALLBERT_HOME="$work/home" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh LANG=C.UTF-8 \
    "$viewer" licenses notices) > "$work/notices.txt"
  (cd "$work" && env -i HOME="$work" ALLBERT_HOME="$work/home" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh LANG=C.UTF-8 \
    "$viewer" licenses show castore-mozilla-ca) > "$work/show.txt"
  jq -S . "$work/licenses.json" > "$work/viewer-manifest.json"
  jq -S . "$release_root/THIRD-PARTY-MANIFEST.json" > "$work/packaged-manifest.json"
  cmp "$work/packaged-manifest.json" "$work/viewer-manifest.json"
  jq -e --arg target "$target" \
    '.schema_version == 1 and .target.triple == $target and
     ([.components[] | select(.id == "castore-mozilla-ca" and .source_required == true)] | length) == 1 and
     (.warnings | type == "array" and length >= 1)' "$work/licenses.json" >/dev/null

  source_url="$(jq -r '.components[] | select(.id == "castore-mozilla-ca") | .source.immutable_url' "$work/licenses.json")"
  source_expected="$(jq -r '.components[] | select(.id == "castore-mozilla-ca") | .source.sha256' "$work/licenses.json")"
  converter_url="$(jq -r '.components[] | select(.id == "castore-mozilla-ca") | .source.converter.immutable_url' "$work/licenses.json")"
  converter_expected="$(jq -r '.components[] | select(.id == "castore-mozilla-ca") | .source.converter.sha256' "$work/licenses.json")"
  [[ "$source_url" == https://* ]]
  [[ "$converter_url" == https://* ]]
  [[ "$source_expected" =~ ^[0-9a-f]{64}$ ]]
  [[ "$converter_expected" =~ ^[0-9a-f]{64}$ ]]
  curl --proto '=https' --tlsv1.2 -fsSL "$source_url" -o "$work/source"
  curl --proto '=https' --tlsv1.2 -fsSL "$converter_url" -o "$work/converter"
  source_actual="$(sha256_file "$work/source")"
  converter_actual="$(sha256_file "$work/converter")"
  [ "$source_actual" = "$source_expected" ]
  [ "$converter_actual" = "$converter_expected" ]
  manifest_sha="$(sha256_file "$release_root/THIRD-PARTY-MANIFEST.json")"
  if find "$release_root" -type f -name 'libcrypto.3.dylib' -print -quit | grep -q .; then
    openssl_bundled=true
  else
    openssl_bundled=false
  fi

  jq -S -n \
    --arg target "$target" --arg source_url "$source_url" \
    --arg source_sha256 "$source_actual" --arg converter_url "$converter_url" \
    --arg converter_sha256 "$converter_actual" --arg manifest_sha256 "$manifest_sha" \
    --arg summary_sha256 "$(sha256_file "$work/summary.txt")" \
    --arg notices_sha256 "$(sha256_file "$work/notices.txt")" \
    --arg show_sha256 "$(sha256_file "$work/show.txt")" \
    --argjson openssl_bundled "$openssl_bundled" \
    --slurpfile archive <(jq -S --arg target "$target" \
      '.archives[] | select(.target == $target)' "$manifest") \
    --slurpfile toolchain "$work/archive/toolchain-${target}.json" \
    '{schema_version: 1, kind: "allbert-release-m0a3-target-row", target: $target,
      archive: $archive[0],
      qualifications: {license: "passed", source_availability: "passed"},
      evidence: {packaged_manifest_sha256: $manifest_sha256,
        viewer_summary_sha256: $summary_sha256, viewer_notices_sha256: $notices_sha256,
        viewer_show_sha256: $show_sha256,
        source: {immutable_url: $source_url, sha256: $source_sha256},
        converter: {immutable_url: $converter_url, sha256: $converter_sha256},
        openssl: {libcrypto_3_dylib_bundled: $openssl_bundled},
        toolchain: $toolchain[0]}}' > "$output"
}

qualified_row_artifact() {
  local phase="$1"
  local target="$2"
  local job_name step_name artifact_name jobs producers artifacts matches count
  local attempt producer_attempt expired
  case "$phase" in
    m0a3)
      job_name="m0a3-license-${target}"
      step_name="Upload immutable M0.a3 target row"
      ;;
    m0c3)
      job_name="m0c3-fv-${target}"
      step_name="Upload immutable M0.c3 target row"
      ;;
    *) echo "stage-artifacts: unknown qualification phase $phase" >&2; exit 2 ;;
  esac
  producer_attempt=""
  attempt=1
  while [ "$attempt" -le "$GITHUB_RUN_ATTEMPT" ]; do
    jobs="$(attempt_jobs "$attempt")"
    producers="$(printf '%s' "$jobs" | jq --arg name "$job_name" --arg step "$step_name" \
      '[.[].jobs[] | select(.name == $name and .conclusion == "success" and
        ([.steps[]? | select(.name == $step and .conclusion == "success")] | length) == 1)] | length')"
    [ "$producers" -le 1 ] || {
      echo "stage-artifacts: duplicate ${phase} ${target} producers in attempt ${attempt}" >&2
      exit 1
    }
    [ "$producers" -eq 0 ] || producer_attempt="$attempt"
    attempt=$((attempt + 1))
  done
  [ -n "$producer_attempt" ] || return 4
  artifact_name="source-${GITHUB_RUN_ID}-a${producer_attempt}-${target}-${phase}-row"
  artifacts="$(artifact_pages | jq -c '[.[].artifacts[]]')"
  matches="$(printf '%s' "$artifacts" | jq -c --arg name "$artifact_name" \
    '[.[] | select(.name == $name)]')"
  count="$(printf '%s' "$matches" | jq 'length')"
  [ "$count" -eq 1 ] || {
    echo "stage-artifacts: ${phase} ${target} requires one row artifact; found ${count}" >&2
    exit 1
  }
  expired="$(printf '%s' "$matches" | jq -r '.[0].expired')"
  [ "$expired" = false ] || {
    echo "stage-artifacts: ${phase} ${target} row artifact is expired" >&2
    exit 1
  }
  printf '%s' "$matches" | jq -S --argjson attempt "$producer_attempt" \
    '.[0] | {artifact_id: .id, artifact_name: .name,
    artifact_digest: (.digest | sub("^sha256:"; "")),
    artifact_created_at: .created_at, producer_run_attempt: $attempt}'
}

download_qualified_row() {
  local phase="$1"
  local target="$2"
  local destination="$3"
  local filename="$4"
  local artifact
  artifact="$(qualified_row_artifact "$phase" "$target")"
  printf '%s' "$artifact" > "${destination}.artifact.json"
  safe_extract_artifact "$artifact" "$destination"
  [ "$(find "$destination" -type f | wc -l | tr -d ' ')" -eq 1 ]
  [ -f "$destination/$filename" ]
}

compose_m0a3() {
  local digest_id="$1"
  local digest_sha="$2"
  local output="$3"
  local work manifest target row selected digest_name digest_attempt
  work="$(mktemp -d)"
  register_cleanup "$work"
  mkdir -p "$work/rows" "$(dirname "$output")"
  open_digest_manifest "$digest_id" "$digest_sha" "$work"
  manifest="$work/digest/digest-manifest.json"
  for target in "${TARGETS[@]}"; do
    download_qualified_row m0a3 "$target" "$work/row-$target" "m0a3-${target}.json"
    row="$work/row-$target/m0a3-${target}.json"
    jq -e --arg target "$target" \
      '.schema_version == 1 and .kind == "allbert-release-m0a3-target-row" and
       .target == $target and .archive.target == $target and
       .qualifications == {license: "passed", source_availability: "passed"} and
       (.evidence.packaged_manifest_sha256 | test("^[0-9a-f]{64}$")) and
       (.evidence.source.sha256 | test("^[0-9a-f]{64}$")) and
       (.evidence.converter.sha256 | test("^[0-9a-f]{64}$"))' "$row" >/dev/null
    selected="$work/selected-$target.json"
    jq -S --arg target "$target" '.archives[] | select(.target == $target)' \
      "$manifest" > "$selected"
    jq -S .archive "$row" > "$work/row-archive-$target.json"
    cmp "$selected" "$work/row-archive-$target.json"
    jq -S --argjson qualification_attempt \
      "$(jq -r .producer_run_attempt "$work/row-$target.artifact.json")" \
      '.archive + {qualification_run_attempt: $qualification_attempt,
        qualifications: .qualifications, license_evidence: .evidence}' \
      "$row" > "$work/rows/$target.json"
  done
  digest_name="$(jq -r .name "$work/digest-metadata.json")"
  digest_attempt="$(jq -r .source_run.attempt "$manifest")"
  jq -S -n \
    --slurpfile digest "$manifest" --argjson source_attempt "$GITHUB_RUN_ATTEMPT" \
    --argjson digest_id "$digest_id" --arg digest_name "$digest_name" \
    --arg digest_sha "$digest_sha" --argjson digest_attempt "$digest_attempt" \
    --arg digest_inner_sha "$(sha256_file "$manifest")" \
    --slurpfile linux_arm64 "$work/rows/linux-arm64.json" \
    --slurpfile linux_x64 "$work/rows/linux-x64.json" \
    --slurpfile macos_arm64 "$work/rows/macos-arm64.json" \
    '$digest[0] as $d | {schema_version: 1, kind: "allbert-release-m0a3-evidence",
      repository: $d.repository, workflow: $d.workflow, event: $d.event,
      tag: $d.tag, ref: $d.ref, ref_type: $d.ref_type, ref_name: $d.ref_name,
      source_sha: $d.source_sha, source_run: {id: $d.source_run.id, attempt: $source_attempt},
      digest_manifest: {artifact_id: $digest_id, artifact_name: $digest_name,
        artifact_digest: $digest_sha, producer_run_attempt: $digest_attempt,
        manifest_sha256: $digest_inner_sha},
      archives: [$linux_arm64[0], $linux_x64[0], $macos_arm64[0]]}' > "$output"
  echo "evidence-sha256=$(sha256_file "$output")" >> "$GITHUB_OUTPUT"
}

validate_m0a3() {
  local m0a3="$1"
  local m0a3_metadata="$2"
  local digest_manifest="$3"
  local digest_id="$4"
  local digest_sha="$5"
  local digest_metadata="$6"
  local m0a3_attempt m0a3_name
  m0a3_attempt="$(jq -r .source_run.attempt "$m0a3")"
  m0a3_name="source-${GITHUB_RUN_ID}-a${m0a3_attempt}-m0a3-evidence"
  [ "$(jq -r .name "$m0a3_metadata")" = "$m0a3_name" ]
  jq -e \
    --argjson source_run_id "$GITHUB_RUN_ID" --argjson current_attempt "$GITHUB_RUN_ATTEMPT" \
    --argjson digest_id "$digest_id" --arg digest_name "$(jq -r .name "$digest_metadata")" \
    --arg digest_sha "$digest_sha" --argjson digest_attempt "$(jq -r .source_run.attempt "$digest_manifest")" \
    --arg digest_inner_sha "$(sha256_file "$digest_manifest")" \
    --slurpfile digest "$digest_manifest" \
    '.schema_version == 1 and .kind == "allbert-release-m0a3-evidence" and
     .repository == $digest[0].repository and .workflow == $digest[0].workflow and
     .event == $digest[0].event and .tag == $digest[0].tag and .ref == $digest[0].ref and
     .ref_type == $digest[0].ref_type and .ref_name == $digest[0].ref_name and
     .source_sha == $digest[0].source_sha and .source_run.id == $source_run_id and
     (.source_run.attempt | type == "number") and .source_run.attempt >= 1 and
     .source_run.attempt <= $current_attempt and
     .digest_manifest == {artifact_id: $digest_id, artifact_name: $digest_name,
       artifact_digest: $digest_sha, producer_run_attempt: $digest_attempt,
       manifest_sha256: $digest_inner_sha} and (.archives | length == 3) and
     ([.archives[].target] | sort == ["linux-arm64", "linux-x64", "macos-arm64"]) and
     (all(.archives[]; (.qualification_run_attempt | type == "number") and
       .qualification_run_attempt >= 1 and .qualification_run_attempt <= $current_attempt and
       .qualifications == {license: "passed", source_availability: "passed"} and
       (.license_evidence.packaged_manifest_sha256 | test("^[0-9a-f]{64}$")) and
       (.license_evidence.source.sha256 | test("^[0-9a-f]{64}$")) and
       (.license_evidence.converter.sha256 | test("^[0-9a-f]{64}$"))))' "$m0a3" >/dev/null
  jq -S '[.archives[] | del(.qualification_run_attempt, .qualifications, .license_evidence)] | sort_by(.target)' \
    "$m0a3" > "${m0a3}.archive-rows"
  jq -S '[.archives[]] | sort_by(.target)' "$digest_manifest" > "${digest_manifest}.archive-rows"
  cmp "${digest_manifest}.archive-rows" "${m0a3}.archive-rows"
}

open_m0a3() {
  local artifact_id="$1"
  local artifact_digest="$2"
  local digest_manifest="$3"
  local digest_id="$4"
  local digest_sha="$5"
  local digest_metadata="$6"
  local work="$7"
  download_bound_single "$artifact_id" "$artifact_digest" m0a3-evidence.json \
    "$work/m0a3" "$work/m0a3-metadata.json"
  validate_m0a3 "$work/m0a3/m0a3-evidence.json" "$work/m0a3-metadata.json" \
    "$digest_manifest" "$digest_id" "$digest_sha" "$digest_metadata"
}

qualify_fv() {
  local target="$1"
  local digest_id="$2"
  local digest_sha="$3"
  local m0a3_id="$4"
  local m0a3_sha="$5"
  local output="$6"
  local work manifest m0a3 archive_name release_root harness provider_expected
  work="$(mktemp -d)"
  register_cleanup "$work"
  open_digest_manifest "$digest_id" "$digest_sha" "$work"
  manifest="$work/digest/digest-manifest.json"
  open_m0a3 "$m0a3_id" "$m0a3_sha" "$manifest" "$digest_id" "$digest_sha" \
    "$work/digest-metadata.json" "$work"
  m0a3="$work/m0a3/m0a3-evidence.json"
  download_target_artifact "$target" "$manifest" "$work/archive"
  archive_name="$(jq -r --arg target "$target" \
    '.archives[] | select(.target == $target) | .archive_name' "$manifest")"
  extract_release "$work/archive/$archive_name" "$work/release"
  release_root="$work/release/allbert"
  harness="${ALLBERT_V121_FV_HARNESS:-scripts/smoke/v121_tui_qualification.sh}"
  [ -x "$harness" ] || {
    echo "stage-artifacts: bounded v1.2.2 TUI/FV harness is unavailable: $harness" >&2
    exit 1
  }
  "$harness" "$release_root" "$target" "$work/fv-result.json"
  [ -f "$work/fv-result.json" ]
  if [ "$target" = linux-x64 ]; then provider_expected=passed; else provider_expected=not_required; fi
  jq -e --arg target "$target" --arg provider "$provider_expected" \
    '.schema_version == 1 and .target == $target and .protocol_tty == "passed" and
     .provider == $provider and
     (.evidence | keys == ["protocol_tty_sha256", "provider_receipt_sha256"]) and
     (.evidence.protocol_tty_sha256 | test("^[0-9a-f]{64}$")) and
     (if $target == "linux-x64" then
        (.evidence.provider_receipt_sha256 | test("^[0-9a-f]{64}$"))
      else .evidence.provider_receipt_sha256 == null end)' \
    "$work/fv-result.json" >/dev/null
  mkdir -p "$(dirname "$output")"
  jq -S -n --arg target "$target" \
    --slurpfile archive <(jq -S --arg target "$target" \
      '.archives[] | select(.target == $target)' "$manifest") \
    --slurpfile license <(jq -S --arg target "$target" \
      '.archives[] | select(.target == $target)' "$m0a3") \
    --slurpfile fv "$work/fv-result.json" \
    '{schema_version: 1, kind: "allbert-release-m0c3-target-row", target: $target,
      archive: $archive[0],
      qualifications: {license: $license[0].qualifications.license,
        source_availability: $license[0].qualifications.source_availability,
        protocol_tty: $fv[0].protocol_tty, provider: $fv[0].provider},
      fv_evidence: $fv[0].evidence}' > "$output"
}

compose_qualification() {
  local digest_id="$1"
  local digest_sha="$2"
  local m0a3_id="$3"
  local m0a3_sha="$4"
  local output="$5"
  local work manifest m0a3 target row selected digest_name digest_attempt m0a3_name m0a3_attempt
  work="$(mktemp -d)"
  register_cleanup "$work"
  mkdir -p "$work/rows" "$(dirname "$output")"
  open_digest_manifest "$digest_id" "$digest_sha" "$work"
  manifest="$work/digest/digest-manifest.json"
  open_m0a3 "$m0a3_id" "$m0a3_sha" "$manifest" "$digest_id" "$digest_sha" \
    "$work/digest-metadata.json" "$work"
  m0a3="$work/m0a3/m0a3-evidence.json"
  for target in "${TARGETS[@]}"; do
    download_qualified_row m0c3 "$target" "$work/row-$target" "m0c3-${target}.json"
    row="$work/row-$target/m0c3-${target}.json"
    jq -e --arg target "$target" \
      '.schema_version == 1 and .kind == "allbert-release-m0c3-target-row" and
       .target == $target and .archive.target == $target and
       .qualifications.license == "passed" and
       .qualifications.source_availability == "passed" and
       .qualifications.protocol_tty == "passed" and
       (.fv_evidence | keys == ["protocol_tty_sha256", "provider_receipt_sha256"]) and
       (.fv_evidence.protocol_tty_sha256 | test("^[0-9a-f]{64}$"))' "$row" >/dev/null
    if [ "$target" = linux-x64 ]; then
      [ "$(jq -r .qualifications.provider "$row")" = passed ]
    else
      [ "$(jq -r .qualifications.provider "$row")" = not_required ]
    fi
    selected="$work/selected-$target.json"
    jq -S --arg target "$target" '.archives[] | select(.target == $target)' \
      "$manifest" > "$selected"
    jq -S .archive "$row" > "$work/row-archive-$target.json"
    cmp "$selected" "$work/row-archive-$target.json"
    [ "$(jq -c --arg target "$target" '.archives[] | select(.target == $target) | .qualifications' "$m0a3")" = \
      "$(jq -c '{license: .qualifications.license, source_availability: .qualifications.source_availability}' "$row")" ]
    jq -S --argjson m0a3_attempt \
      "$(jq -r --arg target "$target" '.archives[] | select(.target == $target) | .qualification_run_attempt' "$m0a3")" \
      --argjson fv_attempt "$(jq -r .producer_run_attempt "$work/row-$target.artifact.json")" \
      '.archive + {m0a3_qualification_run_attempt: $m0a3_attempt,
        fv_run_attempt: $fv_attempt, qualifications: .qualifications,
        fv_evidence: .fv_evidence}' \
      "$row" > "$work/rows/$target.json"
  done
  digest_name="$(jq -r .name "$work/digest-metadata.json")"
  digest_attempt="$(jq -r .source_run.attempt "$manifest")"
  m0a3_name="$(jq -r .name "$work/m0a3-metadata.json")"
  m0a3_attempt="$(jq -r .source_run.attempt "$m0a3")"
  jq -S -n \
    --slurpfile digest "$manifest" --argjson source_attempt "$GITHUB_RUN_ATTEMPT" \
    --argjson digest_id "$digest_id" --arg digest_name "$digest_name" \
    --arg digest_sha "$digest_sha" --argjson digest_attempt "$digest_attempt" \
    --arg digest_inner_sha "$(sha256_file "$manifest")" \
    --argjson m0a3_id "$m0a3_id" --arg m0a3_name "$m0a3_name" \
    --arg m0a3_sha "$m0a3_sha" --argjson m0a3_attempt "$m0a3_attempt" \
    --arg m0a3_inner_sha "$(sha256_file "$m0a3")" \
    --slurpfile linux_arm64 "$work/rows/linux-arm64.json" \
    --slurpfile linux_x64 "$work/rows/linux-x64.json" \
    --slurpfile macos_arm64 "$work/rows/macos-arm64.json" \
    '$digest[0] as $d | {schema_version: 1, kind: "allbert-release-qualification-manifest",
      repository: $d.repository, workflow: $d.workflow, event: $d.event,
      tag: $d.tag, ref: $d.ref, ref_type: $d.ref_type, ref_name: $d.ref_name,
      source_sha: $d.source_sha, source_run: {id: $d.source_run.id, attempt: $source_attempt},
      digest_manifest: {artifact_id: $digest_id, artifact_name: $digest_name,
        artifact_digest: $digest_sha, producer_run_attempt: $digest_attempt,
        manifest_sha256: $digest_inner_sha},
      m0a3_evidence: {artifact_id: $m0a3_id, artifact_name: $m0a3_name,
        artifact_digest: $m0a3_sha, producer_run_attempt: $m0a3_attempt,
        evidence_sha256: $m0a3_inner_sha},
      archives: [$linux_arm64[0], $linux_x64[0], $macos_arm64[0]]}' > "$output"
  echo "qualification-sha256=$(sha256_file "$output")" >> "$GITHUB_OUTPUT"
}

preflight() {
  local target="$1"
  local artifact status
  if artifact="$(accepted_artifact "$target")"; then
    attempt="$(printf '%s' "$artifact" | jq -r .producer_run_attempt)"
    [ "$attempt" -lt "$GITHUB_RUN_ATTEMPT" ] || {
      echo "stage-artifacts: accepted artifact unexpectedly belongs to current attempt" >&2
      exit 1
    }
    echo "reuse=true" >> "$GITHUB_OUTPUT"
    echo "artifact_id=$(printf '%s' "$artifact" | jq -r .artifact_id)" >> "$GITHUB_OUTPUT"
    echo "artifact_name=$(printf '%s' "$artifact" | jq -r .artifact_name)" >> "$GITHUB_OUTPUT"
  else
    status=$?
    if [ "$status" -eq 4 ]; then
      echo "reuse=false" >> "$GITHUB_OUTPUT"
    else
      return "$status"
    fi
  fi
}

download() {
  local target="$1"
  local destination="$2"
  local artifact
  artifact="$(accepted_artifact "$target")" || {
    echo "stage-artifacts: no successful ${target} archive" >&2
    exit 1
  }
  safe_extract_artifact "$artifact" "$destination"
}

compose_manifest() {
  local output="$1"
  local work run workflow_id workflow repository_id repository_name target artifact root
  local archive_name toolchain_name archive_sha toolchain_sha
  work="$(mktemp -d)"
  register_cleanup "$work"
  mkdir -p "$work/rows" "$(dirname "$output")"

  run="$(api "/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}")"
  [ "$(printf '%s' "$run" | jq -r .event)" = push ]
  [ "$GITHUB_REF" = "refs/tags/${GITHUB_REF_NAME}" ]
  [ "$(printf '%s' "$run" | jq -r .head_sha)" = "$GITHUB_SHA" ]
  [ "$(printf '%s' "$run" | jq -r .run_attempt)" = "$GITHUB_RUN_ATTEMPT" ]
  workflow_id="$(printf '%s' "$run" | jq -r .workflow_id)"
  workflow="$(api "/repos/${GITHUB_REPOSITORY}/actions/workflows/${workflow_id}")"
  [ "$(printf '%s' "$workflow" | jq -r .path)" = "$RELEASE_WORKFLOW_PATH" ]
  [ "$(printf '%s' "$run" | jq -r .repository.full_name)" = "$GITHUB_REPOSITORY" ]

  for target in "${TARGETS[@]}"; do
    artifact="$(accepted_artifact "$target")" || {
      echo "stage-artifacts: no successful ${target} archive" >&2
      exit 1
    }
    root="$work/$target"
    safe_extract_artifact "$artifact" "$root"
    [ "$(find "$root" -type f | wc -l | tr -d ' ')" -eq 2 ]
    archive_name="allbert-${GITHUB_REF_NAME}-${target}.tar.gz"
    toolchain_name="toolchain-${target}.json"
    [ -f "$root/$archive_name" ]
    [ -f "$root/$toolchain_name" ]
    archive_sha="$(sha256_file "$root/$archive_name")"
    toolchain_sha="$(sha256_file "$root/$toolchain_name")"
    validate_toolchain "$target" "$root/$toolchain_name"

    printf '%s' "$artifact" | jq -S \
      --arg target "$target" --arg archive_name "$archive_name" \
      --arg sha256 "$archive_sha" --arg toolchain_name "$toolchain_name" \
      --arg toolchain_sha256 "$toolchain_sha" \
      '. + {target: $target, archive_name: $archive_name, sha256: $sha256,
        toolchain_name: $toolchain_name, toolchain_sha256: $toolchain_sha256}' \
      > "$work/rows/${target}.json"
  done

  repository_id="$(printf '%s' "$run" | jq -r .repository.id)"
  repository_name="$(printf '%s' "$run" | jq -r .repository.full_name)"
  jq -S -n \
    --argjson repository_id "$repository_id" --arg repository_name "$repository_name" \
    --argjson workflow_id "$workflow_id" --arg workflow_path "$RELEASE_WORKFLOW_PATH" \
    --arg tag "$GITHUB_REF_NAME" --arg ref "$GITHUB_REF" --arg source_sha "$GITHUB_SHA" \
    --argjson source_run_id "$GITHUB_RUN_ID" --argjson source_run_attempt "$GITHUB_RUN_ATTEMPT" \
    --slurpfile linux_arm64 "$work/rows/linux-arm64.json" \
    --slurpfile linux_x64 "$work/rows/linux-x64.json" \
    --slurpfile macos_arm64 "$work/rows/macos-arm64.json" \
    '{schema_version: 1, kind: "allbert-release-digest-manifest",
      repository: {id: $repository_id, full_name: $repository_name},
      workflow: {id: $workflow_id, path: $workflow_path}, event: "push",
      tag: $tag, ref: $ref, ref_type: "tag", ref_name: $tag, source_sha: $source_sha,
      source_run: {id: $source_run_id, attempt: $source_run_attempt},
      archives: [$linux_arm64[0], $linux_x64[0], $macos_arm64[0]]}' > "$output"
  echo "manifest-sha256=$(sha256_file "$output")" >> "$GITHUB_OUTPUT"
}

cleanup_probe() {
  local work
  work="$(mktemp -d)"
  register_cleanup "$work"
  printf '%s\n' "$work"
}

case "${1:-}" in
  preflight)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RELEASE_WORKFLOW_PATH \
      GITHUB_OUTPUT
    [ "$#" -eq 2 ]
    preflight "$2"
    ;;
  download)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RELEASE_WORKFLOW_PATH
    [ "$#" -eq 3 ]
    download "$2" "$3"
    ;;
  manifest)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RELEASE_WORKFLOW_PATH \
      GITHUB_SHA GITHUB_REF GITHUB_REF_NAME GITHUB_OUTPUT \
      SETUP_BEAM_SHA OTP_VERSION ELIXIR_VERSION REBAR3_VERSION HEX_VERSION
    [ "$#" -eq 2 ]
    compose_manifest "$2"
    ;;
  validate-toolchain)
    require_env GITHUB_SHA SETUP_BEAM_SHA OTP_VERSION ELIXIR_VERSION REBAR3_VERSION HEX_VERSION
    [ "$#" -eq 3 ]
    validate_toolchain "$2" "$3"
    ;;
  qualify-license)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RELEASE_WORKFLOW_PATH \
      GITHUB_SHA GITHUB_REF GITHUB_REF_NAME SETUP_BEAM_SHA OTP_VERSION ELIXIR_VERSION \
      REBAR3_VERSION HEX_VERSION
    [ "$#" -eq 5 ]
    qualify_license "$2" "$3" "$4" "$5"
    ;;
  collect-m0a3)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RELEASE_WORKFLOW_PATH \
      GITHUB_SHA GITHUB_REF GITHUB_REF_NAME GITHUB_OUTPUT
    [ "$#" -eq 4 ]
    compose_m0a3 "$2" "$3" "$4"
    ;;
  qualify-fv)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RELEASE_WORKFLOW_PATH \
      GITHUB_SHA GITHUB_REF GITHUB_REF_NAME SETUP_BEAM_SHA OTP_VERSION ELIXIR_VERSION \
      REBAR3_VERSION HEX_VERSION
    [ "$#" -eq 7 ]
    qualify_fv "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  collect-qualification)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RELEASE_WORKFLOW_PATH \
      GITHUB_SHA GITHUB_REF GITHUB_REF_NAME GITHUB_OUTPUT
    [ "$#" -eq 6 ]
    compose_qualification "$2" "$3" "$4" "$5" "$6"
    ;;
  select-qualified-row)
    require_env GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
    [ "$#" -eq 3 ]
    qualified_row_artifact "$2" "$3"
    ;;
  validate-release-path)
    [ "$#" -eq 2 ]
    validate_release_path "$2"
    ;;
  validate-release-link)
    [ "$#" -eq 4 ]
    validate_release_link "$2" "$3" "$4"
    ;;
  extract-release)
    [ "$#" -eq 3 ]
    extract_release "$2" "$3"
    ;;
  cleanup-probe)
    [ "$#" -eq 1 ]
    cleanup_probe
    ;;
  *)
    echo "usage: stage_artifacts.sh preflight TARGET | download TARGET DIR | manifest FILE | validate-toolchain TARGET FILE | qualify-license TARGET DIGEST_ID DIGEST_SHA FILE | collect-m0a3 DIGEST_ID DIGEST_SHA FILE | qualify-fv TARGET DIGEST_ID DIGEST_SHA M0A3_ID M0A3_SHA FILE | collect-qualification DIGEST_ID DIGEST_SHA M0A3_ID M0A3_SHA FILE | select-qualified-row PHASE TARGET | validate-release-path PATH | validate-release-link TYPE MEMBER TARGET | extract-release ARCHIVE DIR | cleanup-probe" >&2
    exit 2
    ;;
esac
