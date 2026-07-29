defmodule AllbertAssist.Release.PromotionWorkflowContractTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.SecurityFixtures.AssertBinding

  @repo_root Path.expand("../../../../../", __DIR__)
  @workflow_path Path.join(@repo_root, ".github/workflows/release-artifacts.yml")
  @stage_script Path.join(@repo_root, "scripts/release/stage_artifacts.sh")
  @promote_script Path.join(@repo_root, "scripts/release/promote_artifacts.sh")
  @setup_beam_sha "54075bcc5e249e4758d363f27d099f55d843f124"
  @cosign_installer_sha "6f9f17788090df1f26f669e9d70d6ae9567deba6"
  @dispatch_inputs ~w(
    digest_manifest_artifact_id
    digest_manifest_sha256
    qualification_manifest_artifact_id
    qualification_manifest_sha256
    source_run_attempt
    source_run_id
    tag
  )

  test "tag build and protected promotion are disjoint event paths" do
    workflow = workflow!()
    triggers = workflow["on"]
    jobs = workflow["jobs"]
    inputs = triggers["workflow_dispatch"]["inputs"]

    assert triggers["push"] == %{"tags" => ["v*"]}
    assert Enum.sort(Map.keys(inputs)) == @dispatch_inputs

    assert Enum.all?(inputs, fn {_name, spec} ->
             spec["required"] == true and spec["type"] == "string"
           end)

    assert jobs["gate"]["if"] =~ "github.event_name == 'push'"
    gate_run = Enum.find(jobs["gate"]["steps"], &(&1["id"] == "decide"))["run"]
    assert gate_run =~ "git cat-file -t"
    assert gate_run =~ ~S|[ "$tag_type" = tag ]|
    assert gate_run =~ "binary tags must be annotated"
    assert jobs["build"]["needs"] == "gate"
    assert jobs["linux-rehearsal"]["if"] == "github.event_name == 'push'"
    assert jobs["stage-digest-manifest"]["if"] == "github.event_name == 'push'"
    assert jobs["m0a3-license"]["needs"] == "stage-digest-manifest"
    assert jobs["m0a3-evidence"]["needs"] == ["stage-digest-manifest", "m0a3-license"]

    assert jobs["m0c3-fv"]["needs"] == ["stage-digest-manifest", "m0a3-evidence"]

    assert jobs["qualification-evidence"]["needs"] == [
             "stage-digest-manifest",
             "m0a3-evidence",
             "m0c3-fv",
             "m0c3-provider-fv"
           ]

    refute Map.has_key?(jobs, "publish")

    for job_name <-
          ~w(m0a3-license m0a3-evidence m0c3-fv m0c3-provider-fv qualification-evidence) do
      job = jobs[job_name]
      assert job["if"] == "github.event_name == 'push'"
      assert job["permissions"] == %{"actions" => "read", "contents" => "read"}
      text = inspect(job, limit: :infinity)
      refute text =~ "setup-beam@"
      refute text =~ "mix release"
      refute text =~ "cosign"
      refute text =~ "release upload"
      refute text =~ "id-token"
    end

    expected_native_runners = %{
      "linux-arm64" => "ubuntu-22.04-arm",
      "linux-x64" => "ubuntu-22.04",
      "macos-arm64" => "macos-15"
    }

    assert matrix_runner_map(jobs["build"]) == expected_native_runners
    assert matrix_runner_map(jobs["m0a3-license"]) == expected_native_runners

    assert matrix_runner_map(jobs["m0c3-fv"]) == %{
             "linux-arm64" => "ubuntu-22.04-arm",
             "macos-arm64" => "macos-15"
           }

    assert jobs["m0c3-provider-fv"]["runs-on"] == "ubuntu-22.04"
    provider_text = inspect(jobs["m0c3-provider-fv"], limit: :infinity)
    assert provider_text =~ "secrets.ALLBERT_V121_PROVIDER_CONFIG"
    assert provider_text =~ "vars.ALLBERT_V121_PROVIDER_MODEL"

    promotion = jobs["promote"]
    assert promotion["if"] == "github.event_name == 'workflow_dispatch'"
    assert promotion["environment"] == "release-promotion"

    assert promotion["permissions"] == %{
             "actions" => "read",
             "contents" => "write",
             "id-token" => "write"
           }

    assert promotion["concurrency"] == %{
             "cancel-in-progress" => false,
             "group" => "release-promotion-${{ inputs.tag }}"
           }

    promotion_text = inspect(promotion, limit: :infinity)
    refute promotion_text =~ "actions/checkout@"
    refute promotion_text =~ "setup-beam@"
    refute promotion_text =~ "mix release"
    assert promotion_text =~ "contents/scripts/release/promote_artifacts.sh?ref=${GITHUB_SHA}"
  end

  test "all actions and BEAM inputs are immutable exact pins" do
    workflow = workflow!()
    env = workflow["env"]
    steps = all_steps(workflow)
    action_refs = for %{"uses" => uses} <- steps, do: uses

    assert action_refs != []
    assert Enum.all?(action_refs, &Regex.match?(~r/@[0-9a-f]{40}$/, &1))
    assert "erlef/setup-beam@#{@setup_beam_sha}" in action_refs
    assert "sigstore/cosign-installer@#{@cosign_installer_sha}" in action_refs

    assert env["OTP_VERSION"] == "29.0.1"
    assert env["ELIXIR_VERSION"] == "1.19.5"
    assert env["REBAR3_VERSION"] == "3.25.1"
    assert env["HEX_VERSION"] == "2.5.1"
    assert env["SETUP_BEAM_SHA"] == @setup_beam_sha
    refute Map.has_key?(env, "ARTIFACT_RETENTION_DAYS")

    setup = Enum.find(steps, &String.starts_with?(&1["uses"] || "", "erlef/setup-beam@"))
    assert setup["with"]["version-type"] == "strict"
    assert setup["with"]["otp-version"] == "${{ env.OTP_VERSION }}"
    assert setup["with"]["elixir-version"] == "${{ env.ELIXIR_VERSION }}"
    assert setup["with"]["rebar3-version"] == "${{ env.REBAR3_VERSION }}"
    assert setup["with"]["install-hex"] == false
    assert setup["with"]["install-rebar"] == false

    body = File.read!(@workflow_path)
    refute body =~ "brew install erlang"
    refute body =~ "mix local.rebar --force"
    assert body =~ ~S|Path.join([:code.root_dir(), "releases", release, "OTP_VERSION"])|
    assert body =~ ~S|String.trim_leading("OTP-")|
    assert body =~ ~S|[ "$REPORTED_SETUP_BEAM_REVISION" = "ea45c80" ]|
    assert body =~ ~S|[ "$RESOLVED_OTP" = "OTP-${OTP_VERSION}" ]|
    assert body =~ ~S|[ "$RESOLVED_ELIXIR" = "v${ELIXIR_VERSION}-otp-${otp_major}" ]|
    assert body =~ ~S(mix hex.info | awk '/^Hex:/ {value=$2} END {print value}')
    assert body =~ ~S(rebar3 --version | awk 'NR == 1 {value=$2} END {print value}')
    refute body =~ ~S(mix hex.info | awk '/^Hex:/ {print $2; exit}')
    refute body =~ ~S(rebar3 --version | awk '{print $2; exit}')

    cosign =
      Enum.find(steps, &String.starts_with?(&1["uses"] || "", "sigstore/cosign-installer@"))

    refute Map.has_key?(cosign, "with")

    verify_cosign = Enum.find(steps, &(&1["name"] == "Verify exact cosign version"))
    assert verify_cosign["run"] =~ ~S|[ "$resolved_cosign" = "v3.0.6" ]|
  end

  test "uploads are immutable, retained, and attempt-qualified" do
    workflow = workflow!()

    uploads =
      workflow
      |> all_steps()
      |> Enum.filter(&String.starts_with?(&1["uses"] || "", "actions/upload-artifact@"))

    assert length(uploads) >= 4

    assert Enum.all?(uploads, fn step ->
             with = step["with"]

             with["retention-days"] == 30 and with["overwrite"] == false and
               with["if-no-files-found"] == "error" and
               with["name"] =~ "${{ github.run_attempt }}"
           end)

    names = Enum.map(uploads, & &1["with"]["name"])
    assert Enum.any?(names, &(&1 =~ "${{ matrix.target }}-smoke"))
    assert Enum.any?(names, &(&1 =~ "${{ matrix.target }}-archive"))
    assert Enum.any?(names, &String.ends_with?(&1, "-linux-rehearsal"))
    assert Enum.any?(names, &String.ends_with?(&1, "-digest-manifest"))
    assert Enum.any?(names, &(&1 =~ "${{ matrix.target }}-m0a3-row"))
    assert Enum.any?(names, &String.ends_with?(&1, "-m0a3-evidence"))
    assert Enum.any?(names, &(&1 =~ "${{ matrix.target }}-m0c3-row"))
    assert Enum.any?(names, &String.ends_with?(&1, "-qualification-evidence"))

    archive = Enum.find(uploads, &(&1["id"] == "upload-archive"))
    assert archive["with"]["name"] =~ "${{ matrix.target }}-archive"

    stage = workflow["jobs"]["stage-digest-manifest"]
    assert stage["outputs"]["artifact-id"] == "${{ steps.upload.outputs.artifact-id }}"
    assert stage["outputs"]["artifact-digest"] == "${{ steps.upload.outputs.artifact-digest }}"
  end

  test "helpers freeze same-run IDs, age, evidence, and no-clobber publication" do
    stage = File.read!(@stage_script)
    promote = File.read!(@promote_script)

    assert {_, 0} = System.cmd("bash", ["-n", @stage_script], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("bash", ["-n", @promote_script], stderr_to_stdout: true)
    assert Bitwise.band(File.stat!(@stage_script).mode, 0o111) != 0
    assert Bitwise.band(File.stat!(@promote_script).mode, 0o111) != 0

    assert stage =~ "/actions/runs/${GITHUB_RUN_ID}/artifacts?per_page=100"
    assert stage =~ "/attempts/${attempt}/jobs?per_page=100"
    assert stage =~ ".conclusion == \"success\""
    assert stage =~ "Upload immutable native archive"
    assert stage =~ "multiple successful ${target} producer attempts"
    assert stage =~ "requires exactly one extant artifact"
    assert stage =~ "artifact_digest"
    assert stage =~ "producer_run_attempt"
    assert stage =~ "allbert-release-digest-manifest"
    assert stage =~ ~S|.setup_beam.reported_action_revision == "ea45c80"|
    assert stage =~ "allbert-release-m0a3-evidence"
    assert stage =~ "allbert-release-qualification-manifest"
    assert stage =~ "Upload immutable M0.a3 target row"
    assert stage =~ "Upload immutable M0.c3 target row"
    assert stage =~ "duplicate ${phase} ${target} producers in attempt"
    assert stage =~ ~S|(cd "$work" && env -i|
    assert stage =~ ~S|cmp "$work/packaged-manifest.json" "$work/viewer-manifest.json"|
    assert stage =~ "provider_receipt_sha256"

    assert promote =~ ".event)\" = push"
    assert promote =~ ".conclusion)\" = success"
    assert promote =~ "/git/ref/tags/${PROMOTION_TAG}"
    assert promote =~ ".created_at"
    assert promote =~ "MAX_NATIVE_ARTIFACT_AGE_DAYS * 86400"
    assert promote =~ "allbert-release-qualification-manifest"
    assert promote =~ "m0a3_evidence"
    assert promote =~ "allbert-release-m0a3-evidence"
    assert promote =~ "m0a3-rows.json"
    assert promote =~ "m0a3-outcomes.json"
    assert promote =~ "qualifications.protocol_tty == \"passed\""
    assert promote =~ "LC_ALL=C sort"
    assert promote =~ "printf '%s  %s\\n'"
    refute promote =~ "cosign-installer"
    assert promote =~ "sign-blob"
    assert promote =~ "verify-blob"
    assert promote =~ "--certificate-identity"
    assert promote =~ "release_cli upload"
    assert promote =~ "--verify-tag"
    refute promote =~ "target_commitish"
    refute promote =~ ~S|--target "$source_sha"|
    refute promote =~ "--clobber"
    refute promote =~ "mix release"
    refute promote =~ "actions/checkout"
  end

  test "fixture selection reuses one successful producer and only builds with none", context do
    root = fixture_root(context.test)
    output = Path.join(root, "github-output")
    fake_gh = fake_gh!(root)

    write_native_job_fixtures!(root, [1])
    write_artifacts!(root, [artifact(101, 1)])
    assert {_, 0} = run_stage_preflight(fake_gh, root, output)
    result = File.read!(output)
    assert result =~ "reuse=true"
    assert result =~ "artifact_id=101"
    assert result =~ "artifact_name=source-77-a1-linux-x64-archive"

    File.rm!(output)
    write_native_job_fixtures!(root, [])
    write_artifacts!(root, [])
    assert {_, 0} = run_stage_preflight(fake_gh, root, output)
    assert File.read!(output) =~ "reuse=false"
  end

  test "fixture selection rejects missing and expired producer artifacts", context do
    root = fixture_root(context.test)
    output = Path.join(root, "github-output")
    fake_gh = fake_gh!(root)
    write_native_job_fixtures!(root, [1])

    write_artifacts!(root, [])
    assert {error, status} = run_stage_preflight(fake_gh, root, output)
    assert status != 0
    assert error =~ "requires exactly one extant artifact; found 0"

    write_artifacts!(root, [artifact(101, 1, expired: true)])
    assert {error, status} = run_stage_preflight(fake_gh, root, output)
    assert status != 0
    assert error =~ "producer artifact is expired"
  end

  test "fixture selection rejects duplicate artifacts and producer attempts", context do
    root = fixture_root(context.test)
    output = Path.join(root, "github-output")
    fake_gh = fake_gh!(root)

    write_native_job_fixtures!(root, [1])
    write_artifacts!(root, [artifact(101, 1), artifact(202, 1)])
    assert {error, status} = run_stage_preflight(fake_gh, root, output)
    assert status != 0
    assert error =~ "requires exactly one extant artifact; found 2"

    write_native_job_fixtures!(root, [1, 2])
    write_artifacts!(root, [artifact(101, 1), artifact(202, 2)])
    assert {error, status} = run_stage_preflight(fake_gh, root, output)
    assert status != 0
    assert error =~ "multiple successful linux-x64 producer attempts"
  end

  test "fixture row selection chooses the latest successful qualification attempt", context do
    root = fixture_root(context.test)
    fake_gh = fake_gh!(root)
    write_qualification_job_fixtures!(root, :m0a3, "linux-x64", [1, 2])

    write_artifacts!(root, [
      qualification_artifact(501, 1, "linux-x64", "m0a3"),
      qualification_artifact(502, 2, "linux-x64", "m0a3")
    ])

    assert {json, 0} = run_row_selection(fake_gh, root)

    assert Jason.decode!(json)["producer_run_attempt"] == 2

    write_qualification_job_fixtures!(root, :m0a3, "linux-x64", [1, 2], [2])
    assert {error, status} = run_row_selection(fake_gh, root)
    assert status != 0
    assert error =~ "duplicate m0a3 linux-x64 producers in attempt 2"

    write_qualification_job_fixtures!(root, :m0a3, "linux-x64", [1, 2])

    write_artifacts!(root, [
      qualification_artifact(501, 1, "linux-x64", "m0a3"),
      qualification_artifact(502, 2, "linux-x64", "m0a3"),
      qualification_artifact(503, 2, "linux-x64", "m0a3")
    ])

    assert {error, status} = run_row_selection(fake_gh, root)
    assert status != 0
    assert error =~ "m0a3 linux-x64 requires one row artifact; found 2"
  end

  test "toolchain fixture distinguishes the immutable action pin from its reported revision",
       context do
    root = fixture_root(context.test)
    fixture = Path.join(root, "toolchain.json")
    sha = String.duplicate("a", 40)

    toolchain = %{
      "schema_version" => 1,
      "target" => "linux-x64",
      "source_sha" => sha,
      "setup_beam" => %{
        "action_sha" => @setup_beam_sha,
        "reported_action_revision" => "ea45c80",
        "version_type" => "strict",
        "otp" => %{"input" => "29.0.1", "resolved" => "OTP-29.0.1"},
        "elixir" => %{"input" => "1.19.5", "resolved" => "v1.19.5-otp-29"},
        "rebar3" => %{"input" => "3.25.1", "resolved" => "3.25.1"}
      },
      "hex" => %{"input" => "2.5.1", "resolved" => "2.5.1"},
      "runtime" => %{"otp" => "29.0.1", "elixir" => "1.19.5", "erts" => "16.0.1"}
    }

    write_json!(fixture, toolchain)
    assert {_, 0} = run_toolchain_validation(fixture, sha)

    write_json!(
      fixture,
      put_in(toolchain, ["setup_beam", "reported_action_revision"], @setup_beam_sha)
    )

    assert {_, status} = run_toolchain_validation(fixture, sha)
    assert status != 0

    write_json!(
      fixture,
      put_in(toolchain, ["setup_beam", "action_sha"], String.duplicate("b", 40))
    )

    assert {_, status} = run_toolchain_validation(fixture, sha)
    assert status != 0

    write_json!(
      fixture,
      put_in(toolchain, ["setup_beam", "otp", "resolved"], "OTP-29.0.10")
    )

    assert {_, status} = run_toolchain_validation(fixture, sha)
    assert status != 0
  end

  test "release tar preflight rejects traversal and unsafe link targets before extraction",
       context do
    root = fixture_root(context.test)

    for member <- ["/absolute", "../escape", "allbert/../escape", "allbert/.."] do
      assert {output, status} =
               System.cmd("bash", [@stage_script, "validate-release-path", member],
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "unsafe release archive entry"
    end

    for {type, member, target} <- [
          {"symlink", "allbert/bin/bad", "/etc/passwd"},
          {"symlink", "allbert/bin/bad", "../../escape"},
          {"hardlink", "allbert/bin/bad", "../escape"}
        ] do
      assert {output, status} =
               System.cmd(
                 "bash",
                 [@stage_script, "validate-release-link", type, member, target],
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "unsafe release archive link"
    end

    tree = Path.join(root, "tree")
    File.mkdir_p!(Path.join(tree, "allbert/bin"))
    File.write!(Path.join(tree, "allbert/bin/allbert"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(tree, "allbert/bin/allbert"), 0o755)
    File.ln_s!("/etc/passwd", Path.join(tree, "allbert/unsafe-link"))
    archive = Path.join(root, "unsafe.tar.gz")
    assert {_, 0} = System.cmd("tar", ["-czf", archive, "-C", tree, "allbert"])
    destination = Path.join(root, "extract")

    assert {output, status} =
             System.cmd("bash", [@stage_script, "extract-release", archive, destination],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "unsafe release archive link"
    refute File.exists?(Path.join(destination, "allbert/unsafe-link"))
  end

  test "stage helper cleanup remains bound after function locals return" do
    assert {output, 0} =
             System.cmd("bash", [@stage_script, "cleanup-probe"], stderr_to_stdout: true)

    work = String.trim(output)
    refute File.exists?(work)

    stage = File.read!(@stage_script)
    refute stage =~ ~S|trap 'rm -rf "$work"' EXIT|
    assert length(Regex.scan(~r/register_cleanup "\$work"/, stage)) == 6
  end

  test "fixture source run with a non-push event fails promotion authentication", context do
    root = fixture_root(context.test)
    fake_gh = fake_gh!(root)
    sha = String.duplicate("a", 40)

    write_json!(Path.join(root, "run.json"), %{
      "workflow_id" => 42,
      "event" => "workflow_dispatch",
      "status" => "completed",
      "conclusion" => "success",
      "run_attempt" => 2,
      "head_sha" => sha,
      "repository" => %{"id" => 9, "full_name" => "lexlapax/allbert-assist"}
    })

    write_json!(Path.join(root, "repository.json"), %{
      "id" => 9,
      "full_name" => "lexlapax/allbert-assist"
    })

    write_json!(Path.join(root, "workflow.json"), %{
      "id" => 42,
      "path" => ".github/workflows/release-artifacts.yml"
    })

    env = [
      {"ALLBERT_RELEASE_GH_BIN", fake_gh},
      {"FIXTURE_ROOT", root},
      {"RUNNER_TEMP", root},
      {"GITHUB_REPOSITORY", "lexlapax/allbert-assist"},
      {"GITHUB_REF", "refs/tags/v1.2.1"},
      {"GITHUB_REF_TYPE", "tag"},
      {"GITHUB_REF_NAME", "v1.2.1"},
      {"GITHUB_SHA", sha},
      {"RELEASE_WORKFLOW_PATH", ".github/workflows/release-artifacts.yml"},
      {"MAX_NATIVE_ARTIFACT_AGE_DAYS", "21"},
      {"PROMOTION_TAG", "v1.2.1"},
      {"SOURCE_RUN_ID", "77"},
      {"SOURCE_RUN_ATTEMPT", "2"},
      {"DIGEST_ARTIFACT_ID", "301"},
      {"DIGEST_ARTIFACT_SHA256", String.duplicate("b", 64)},
      {"QUALIFICATION_ARTIFACT_ID", "302"},
      {"QUALIFICATION_ARTIFACT_SHA256", String.duplicate("c", 64)}
    ]

    assert {_output, status} =
             System.cmd("bash", [@promote_script], env: env, stderr_to_stdout: true)

    assert status != 0
  end

  test "real promotion helper accepts the exact 21-day boundary and resumes asset publication",
       context do
    fixture = promotion_fixture!(fixture_root(context.test))
    boundary = fixture.created_epoch + 21 * 86_400

    assert {output, 0} = run_promotion(fixture, boundary)
    assert output == ""
    assert published_asset_names(fixture.root) == fixture.expected_asset_names
    first_uploads = promotion_upload_count(fixture.root)
    assert first_uploads == length(fixture.expected_asset_names)

    assert {_, 0} = run_promotion(fixture, boundary)
    assert promotion_upload_count(fixture.root) == first_uploads

    missing = "allbert-v1.2.1-linux-x64.tar.gz"
    remove_published_asset!(fixture.root, missing)
    assert {_, 0} = run_promotion(fixture, boundary)
    assert promotion_upload_count(fixture.root) == first_uploads + 1
    assert published_asset_names(fixture.root) == fixture.expected_asset_names

    differing = "allbert-v1.2.1-macos-arm64.tar.gz"
    overwrite_published_asset!(fixture.root, differing, "different release bytes")
    assert {error, status} = run_promotion(fixture, boundary)
    assert status != 0
    assert error =~ "existing asset #{differing} differs; refusing replacement"

    AssertBinding.check!("v121-promotion-evidence-001", [
      :age_boundary_exact,
      :semantic_tamper_rejected,
      :restartable_assets_fail_closed
    ])
  end

  test "real promotion helper rejects one second beyond the age window and semantic tamper",
       context do
    stale = promotion_fixture!(fixture_root("#{context.test}-stale"))
    assert {error, status} = run_promotion(stale, stale.created_epoch + 21 * 86_400 + 1)
    assert status != 0
    assert error =~ "exceeds the 21-day window"

    tampered = promotion_fixture!(fixture_root("#{context.test}-tampered"), tampered?: true)
    assert {_error, status} = run_promotion(tampered, tampered.created_epoch + 21 * 86_400)
    assert status != 0
    assert published_asset_names(tampered.root) == []
  end

  test "real promotion helper rejects unexpected existing assets", context do
    fixture = promotion_fixture!(fixture_root(context.test))
    boundary = fixture.created_epoch + 21 * 86_400
    assert {_, 0} = run_promotion(fixture, boundary)

    add_published_asset!(fixture.root, "unexpected-debug.zip", "debug bytes")
    assert {error, status} = run_promotion(fixture, boundary)
    assert status != 0
    assert error =~ "unexpected existing asset unexpected-debug.zip"
  end

  test "intermediate artifact workflow contains no aggregate source gates" do
    body = File.read!(@workflow_path)

    for forbidden <- [
          "mix precommit",
          "mix allbert.test",
          "mix test",
          "release.v1",
          "release.v12",
          "release.v121",
          "release.v13"
        ] do
      refute body =~ forbidden
    end
  end

  defp workflow! do
    assert {:ok, workflow} = YamlElixir.read_from_file(@workflow_path)
    workflow
  end

  defp all_steps(workflow) do
    workflow["jobs"]
    |> Map.values()
    |> Enum.flat_map(&(&1["steps"] || []))
  end

  defp matrix_runner_map(job) do
    job["strategy"]["matrix"]["include"]
    |> Map.new(&{&1["target"], &1["os"]})
  end

  defp fixture_root(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-promotion-contract-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp fake_gh!(root) do
    path = Path.join(root, "gh")

    File.write!(
      path,
      ~S"""
      #!/usr/bin/env bash
      set -euo pipefail
      args="$*"
      printf '%s\n' "$args" >> "$FIXTURE_ROOT/gh-calls.log"
      case "$args" in
        "release create "*)
          printf '%s' '{"id":700,"tag_name":"v1.2.1","prerelease":false,"draft":true}' \
            > "$FIXTURE_ROOT/release.json"
          ;;
        "release upload "*)
          source_path="$4"
          name="$(basename "$source_path")"
          id="$(cat "$FIXTURE_ROOT/next-asset-id")"
          printf '%s' "$((id + 1))" > "$FIXTURE_ROOT/next-asset-id"
          cp "$source_path" "$FIXTURE_ROOT/release-asset-${id}.bin"
          jq --arg name "$name" --argjson id "$id" \
            '. + [{id: $id, name: $name}]' "$FIXTURE_ROOT/assets.json" \
            > "$FIXTURE_ROOT/assets.next.json"
          mv "$FIXTURE_ROOT/assets.next.json" "$FIXTURE_ROOT/assets.json"
          printf 'upload:%s\n' "$name" >> "$FIXTURE_ROOT/release-events.log"
          ;;
        "release edit "*)
          jq '.draft = false' "$FIXTURE_ROOT/release.json" \
            > "$FIXTURE_ROOT/release.next.json"
          mv "$FIXTURE_ROOT/release.next.json" "$FIXTURE_ROOT/release.json"
          ;;
        *"/actions/runs/77/artifacts?per_page=100"*) cat "$FIXTURE_ROOT/artifacts.json" ;;
        *"/attempts/1/jobs?per_page=100"*) cat "$FIXTURE_ROOT/jobs-1.json" ;;
        *"/attempts/2/jobs?per_page=100"*) cat "$FIXTURE_ROOT/jobs-2.json" ;;
        *"/attempts/3/jobs?per_page=100"*) cat "$FIXTURE_ROOT/jobs-3.json" ;;
        *"/actions/runs/77") cat "$FIXTURE_ROOT/run.json" ;;
        *"/actions/workflows/42") cat "$FIXTURE_ROOT/workflow.json" ;;
        *"/git/ref/tags/v1.2.1") cat "$FIXTURE_ROOT/tag-ref.json" ;;
        *"/git/tags/"*) cat "$FIXTURE_ROOT/tag-object.json" ;;
        *"/actions/artifacts/"*"/zip")
          endpoint="${!#}"
          id="${endpoint%/zip}"
          id="${id##*/}"
          cat "$FIXTURE_ROOT/artifact-${id}.zip"
          ;;
        *"/actions/artifacts/"*)
          endpoint="${!#}"
          id="${endpoint##*/}"
          cat "$FIXTURE_ROOT/artifact-${id}.json"
          ;;
        *"/releases/tags/v1.2.1")
          test -f "$FIXTURE_ROOT/release.json"
          cat "$FIXTURE_ROOT/release.json"
          ;;
        *"/releases/700/assets?per_page=100")
          jq -c '[.]' "$FIXTURE_ROOT/assets.json"
          ;;
        *"/releases/assets/"*)
          endpoint="${!#}"
          id="${endpoint##*/}"
          cat "$FIXTURE_ROOT/release-asset-${id}.bin"
          ;;
        *"api /repos/lexlapax/allbert-assist") cat "$FIXTURE_ROOT/repository.json" ;;
        *) echo "unexpected fake gh call: $args" >&2; exit 91 ;;
      esac
      """
    )

    File.chmod!(path, 0o755)
    path
  end

  defp run_stage_preflight(fake_gh, root, output) do
    env = [
      {"ALLBERT_RELEASE_GH_BIN", fake_gh},
      {"FIXTURE_ROOT", root},
      {"GITHUB_REPOSITORY", "lexlapax/allbert-assist"},
      {"GITHUB_RUN_ID", "77"},
      {"GITHUB_RUN_ATTEMPT", "3"},
      {"GITHUB_OUTPUT", output},
      {"RELEASE_WORKFLOW_PATH", ".github/workflows/release-artifacts.yml"}
    ]

    System.cmd("bash", [@stage_script, "preflight", "linux-x64"],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp run_toolchain_validation(fixture, sha) do
    env = [
      {"GITHUB_SHA", sha},
      {"SETUP_BEAM_SHA", @setup_beam_sha},
      {"OTP_VERSION", "29.0.1"},
      {"ELIXIR_VERSION", "1.19.5"},
      {"REBAR3_VERSION", "3.25.1"},
      {"HEX_VERSION", "2.5.1"}
    ]

    System.cmd("bash", [@stage_script, "validate-toolchain", "linux-x64", fixture],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp run_row_selection(fake_gh, root) do
    env = [
      {"ALLBERT_RELEASE_GH_BIN", fake_gh},
      {"FIXTURE_ROOT", root},
      {"GITHUB_REPOSITORY", "lexlapax/allbert-assist"},
      {"GITHUB_RUN_ID", "77"},
      {"GITHUB_RUN_ATTEMPT", "3"}
    ]

    System.cmd("bash", [@stage_script, "select-qualified-row", "m0a3", "linux-x64"],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp promotion_fixture!(root, opts \\ []) do
    sha = String.duplicate("a", 40)
    tag_object_sha = String.duplicate("b", 40)
    created_at = "2026-07-01T00:00:00Z"
    {:ok, created, 0} = DateTime.from_iso8601(created_at)
    created_epoch = DateTime.to_unix(created)
    fake_gh = fake_gh!(root)
    fake_cosign = fake_cosign!(root)
    install_fake_date!(root, created_at, created_epoch)

    write_json!(Path.join(root, "run.json"), %{
      "workflow_id" => 42,
      "event" => "push",
      "status" => "completed",
      "conclusion" => "success",
      "run_attempt" => 2,
      "head_sha" => sha,
      "repository" => %{"id" => 9, "full_name" => "lexlapax/allbert-assist"}
    })

    write_json!(Path.join(root, "repository.json"), %{
      "id" => 9,
      "full_name" => "lexlapax/allbert-assist"
    })

    write_json!(Path.join(root, "workflow.json"), %{
      "id" => 42,
      "path" => ".github/workflows/release-artifacts.yml"
    })

    write_json!(Path.join(root, "tag-ref.json"), %{
      "object" => %{"type" => "tag", "sha" => tag_object_sha}
    })

    write_json!(Path.join(root, "tag-object.json"), %{
      "object" => %{"type" => "commit", "sha" => sha}
    })

    rows =
      [
        {"linux-arm64", 401},
        {"linux-x64", 402},
        {"macos-arm64", 403}
      ]
      |> Enum.map(fn {target, id} ->
        archive_name = "allbert-v1.2.1-#{target}.tar.gz"
        toolchain_name = "toolchain-#{target}.json"
        archive = Path.join(root, archive_name)
        toolchain = Path.join(root, toolchain_name)
        File.write!(archive, "immutable #{target} archive\n")
        File.write!(toolchain, Jason.encode!(%{"target" => target, "source_sha" => sha}))
        zip = Path.join(root, "artifact-#{id}.zip")
        zip_files!(zip, [archive, toolchain])
        zip_digest = sha256_file(zip)

        write_artifact_metadata!(root, id, "source-77-a1-#{target}-archive", zip_digest)

        %{
          "artifact_id" => id,
          "artifact_name" => "source-77-a1-#{target}-archive",
          "artifact_digest" => zip_digest,
          "producer_run_attempt" => 1,
          "target" => target,
          "archive_name" => archive_name,
          "sha256" => sha256_file(archive),
          "artifact_created_at" => created_at,
          "toolchain_name" => toolchain_name,
          "toolchain_sha256" => sha256_file(toolchain)
        }
      end)

    jobs =
      Enum.map(rows, fn row ->
        %{
          "name" => "build-#{row["target"]}",
          "conclusion" => "success",
          "steps" => [
            %{"name" => "Upload immutable native archive", "conclusion" => "success"}
          ]
        }
      end)

    write_json!(Path.join(root, "jobs-1.json"), [%{"jobs" => jobs}])
    write_json!(Path.join(root, "jobs-2.json"), [%{"jobs" => []}])
    write_json!(Path.join(root, "jobs-3.json"), [%{"jobs" => []}])

    digest_manifest = %{
      "schema_version" => 1,
      "kind" => "allbert-release-digest-manifest",
      "repository" => %{"id" => 9, "full_name" => "lexlapax/allbert-assist"},
      "workflow" => %{"id" => 42, "path" => ".github/workflows/release-artifacts.yml"},
      "event" => "push",
      "tag" => "v1.2.1",
      "ref" => "refs/tags/v1.2.1",
      "ref_type" => "tag",
      "ref_name" => "v1.2.1",
      "source_sha" => sha,
      "source_run" => %{"id" => 77, "attempt" => 1},
      "archives" => rows
    }

    digest_inner = Path.join(root, "digest-manifest.json")
    write_json!(digest_inner, digest_manifest)

    digest_zip_digest =
      write_single_artifact!(root, 301, "source-77-a1-digest-manifest", digest_inner)

    m0a3_rows =
      Enum.map(rows, fn row ->
        Map.merge(row, %{
          "qualification_run_attempt" => 2,
          "qualifications" => %{"license" => "passed", "source_availability" => "passed"},
          "license_evidence" => %{
            "packaged_manifest_sha256" => String.duplicate("1", 64),
            "source" => %{"sha256" => String.duplicate("2", 64)},
            "converter" => %{"sha256" => String.duplicate("3", 64)}
          }
        })
      end)

    digest_binding = %{
      "artifact_id" => 301,
      "artifact_name" => "source-77-a1-digest-manifest",
      "artifact_digest" => digest_zip_digest,
      "producer_run_attempt" => 1,
      "manifest_sha256" => sha256_file(digest_inner)
    }

    m0a3 = %{
      "schema_version" => 1,
      "kind" => "allbert-release-m0a3-evidence",
      "repository" => %{"id" => 9, "full_name" => "lexlapax/allbert-assist"},
      "workflow" => %{"id" => 42, "path" => ".github/workflows/release-artifacts.yml"},
      "event" => "push",
      "tag" => "v1.2.1",
      "ref" => "refs/tags/v1.2.1",
      "ref_type" => "tag",
      "ref_name" => "v1.2.1",
      "source_sha" => sha,
      "source_run" => %{"id" => 77, "attempt" => 2},
      "digest_manifest" => digest_binding,
      "archives" => m0a3_rows
    }

    m0a3_inner = Path.join(root, "m0a3-evidence.json")
    write_json!(m0a3_inner, m0a3)
    m0a3_zip_digest = write_single_artifact!(root, 303, "source-77-a2-m0a3-evidence", m0a3_inner)

    qualification_rows =
      Enum.map(rows, fn row ->
        provider = if row["target"] == "linux-x64", do: "passed", else: "not_required"

        provider =
          if Keyword.get(opts, :tampered?, false) and row["target"] == "linux-x64",
            do: "failed",
            else: provider

        Map.merge(row, %{
          "m0a3_qualification_run_attempt" => 2,
          "fv_run_attempt" => 2,
          "qualifications" => %{
            "license" => "passed",
            "source_availability" => "passed",
            "protocol_tty" => "passed",
            "provider" => provider
          },
          "fv_evidence" => %{
            "protocol_tty_sha256" => String.duplicate("4", 64),
            "provider_receipt_sha256" =>
              if(row["target"] == "linux-x64", do: String.duplicate("5", 64), else: nil)
          }
        })
      end)

    qualification = %{
      "schema_version" => 1,
      "kind" => "allbert-release-qualification-manifest",
      "repository" => %{"id" => 9, "full_name" => "lexlapax/allbert-assist"},
      "workflow" => %{"id" => 42, "path" => ".github/workflows/release-artifacts.yml"},
      "event" => "push",
      "tag" => "v1.2.1",
      "ref" => "refs/tags/v1.2.1",
      "ref_type" => "tag",
      "ref_name" => "v1.2.1",
      "source_sha" => sha,
      "source_run" => %{"id" => 77, "attempt" => 2},
      "digest_manifest" => digest_binding,
      "m0a3_evidence" => %{
        "artifact_id" => 303,
        "artifact_name" => "source-77-a2-m0a3-evidence",
        "artifact_digest" => m0a3_zip_digest,
        "producer_run_attempt" => 2,
        "evidence_sha256" => sha256_file(m0a3_inner)
      },
      "archives" => qualification_rows
    }

    qualification_inner = Path.join(root, "qualification-evidence-manifest.json")
    write_json!(qualification_inner, qualification)

    qualification_zip_digest =
      write_single_artifact!(
        root,
        302,
        "source-77-a2-qualification-evidence",
        qualification_inner
      )

    write_json!(Path.join(root, "artifacts.json"), %{"total_count" => 0, "artifacts" => []})
    write_json!(Path.join(root, "assets.json"), [])
    File.write!(Path.join(root, "next-asset-id"), "800")
    File.write!(Path.join(root, "release-events.log"), "")

    expected_asset_names =
      (["SHA256SUMS", "SHA256SUMS.cosign.bundle"] ++
         Enum.flat_map(~w(linux-arm64 linux-x64 macos-arm64), fn target ->
           ["allbert-v1.2.1-#{target}.tar.gz", "allbert-#{target}.tar.gz"]
         end))
      |> Enum.sort()

    %{
      root: root,
      fake_gh: fake_gh,
      fake_cosign: fake_cosign,
      source_sha: sha,
      created_epoch: created_epoch,
      digest_zip_digest: digest_zip_digest,
      qualification_zip_digest: qualification_zip_digest,
      expected_asset_names: expected_asset_names
    }
  end

  defp run_promotion(fixture, now_epoch) do
    env = [
      {"ALLBERT_RELEASE_GH_BIN", fixture.fake_gh},
      {"ALLBERT_RELEASE_COSIGN_BIN", fixture.fake_cosign},
      {"ALLBERT_RELEASE_NOW_EPOCH", Integer.to_string(now_epoch)},
      {"FIXTURE_ROOT", fixture.root},
      {"RUNNER_TEMP", fixture.root},
      {"PATH", Path.join(fixture.root, "bin") <> ":" <> System.fetch_env!("PATH")},
      {"GITHUB_REPOSITORY", "lexlapax/allbert-assist"},
      {"GITHUB_REF", "refs/tags/v1.2.1"},
      {"GITHUB_REF_TYPE", "tag"},
      {"GITHUB_REF_NAME", "v1.2.1"},
      {"GITHUB_SHA", fixture.source_sha},
      {"RELEASE_WORKFLOW_PATH", ".github/workflows/release-artifacts.yml"},
      {"MAX_NATIVE_ARTIFACT_AGE_DAYS", "21"},
      {"PROMOTION_TAG", "v1.2.1"},
      {"SOURCE_RUN_ID", "77"},
      {"SOURCE_RUN_ATTEMPT", "2"},
      {"DIGEST_ARTIFACT_ID", "301"},
      {"DIGEST_ARTIFACT_SHA256", fixture.digest_zip_digest},
      {"QUALIFICATION_ARTIFACT_ID", "302"},
      {"QUALIFICATION_ARTIFACT_SHA256", fixture.qualification_zip_digest}
    ]

    System.cmd("bash", [@promote_script], env: env, stderr_to_stdout: true)
  end

  defp fake_cosign!(root) do
    path = Path.join(root, "cosign")

    File.write!(
      path,
      ~S"""
      #!/usr/bin/env bash
      set -euo pipefail
      case "${1:-}" in
        sign-blob)
          while [ "$#" -gt 0 ]; do
            if [ "$1" = --bundle ]; then
              shift
              printf 'deterministic fake cosign bundle\n' > "$1"
              exit 0
            fi
            shift
          done
          exit 2
          ;;
        verify-blob) exit 0 ;;
        *) exit 2 ;;
      esac
      """
    )

    File.chmod!(path, 0o755)
    path
  end

  defp install_fake_date!(root, created_at, created_epoch) do
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    path = Path.join(bin, "date")

    File.write!(
      path,
      "#!/usr/bin/env bash\n" <>
        "if [ \"$*\" = '-u -d #{created_at} +%s' ]; then printf '%s\\n' '#{created_epoch}'; else exec /bin/date \"$@\"; fi\n"
    )

    File.chmod!(path, 0o755)
  end

  defp write_single_artifact!(root, id, name, inner_path) do
    zip = Path.join(root, "artifact-#{id}.zip")
    zip_files!(zip, [inner_path])
    digest = sha256_file(zip)
    write_artifact_metadata!(root, id, name, digest)
    digest
  end

  defp write_artifact_metadata!(root, id, name, digest) do
    write_json!(Path.join(root, "artifact-#{id}.json"), %{
      "id" => id,
      "name" => name,
      "digest" => "sha256:#{digest}",
      "created_at" => "2026-07-01T00:00:00Z",
      "expired" => false,
      "workflow_run" => %{"id" => 77}
    })
  end

  defp zip_files!(zip, files) do
    File.rm(zip)
    assert {_, 0} = System.cmd("zip", ["-q", "-j", zip | files], stderr_to_stdout: true)
  end

  defp sha256_file(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp published_asset_names(root) do
    root
    |> Path.join("assets.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  defp promotion_upload_count(root) do
    root
    |> Path.join("release-events.log")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.count(&String.starts_with?(&1, "upload:"))
  end

  defp remove_published_asset!(root, name) do
    {asset, rest} = pop_asset!(root, name)
    write_json!(Path.join(root, "assets.json"), rest)
    File.rm!(Path.join(root, "release-asset-#{asset["id"]}.bin"))
  end

  defp overwrite_published_asset!(root, name, bytes) do
    asset = find_asset!(root, name)
    File.write!(Path.join(root, "release-asset-#{asset["id"]}.bin"), bytes)
  end

  defp add_published_asset!(root, name, bytes) do
    id = root |> Path.join("next-asset-id") |> File.read!() |> String.to_integer()
    assets = read_assets!(root) ++ [%{"id" => id, "name" => name}]
    write_json!(Path.join(root, "assets.json"), assets)
    File.write!(Path.join(root, "release-asset-#{id}.bin"), bytes)
    File.write!(Path.join(root, "next-asset-id"), Integer.to_string(id + 1))
  end

  defp pop_asset!(root, name) do
    assets = read_assets!(root)
    asset = Enum.find(assets, &(&1["name"] == name)) || flunk("missing asset #{name}")
    {asset, Enum.reject(assets, &(&1["id"] == asset["id"]))}
  end

  defp find_asset!(root, name) do
    Enum.find(read_assets!(root), &(&1["name"] == name)) || flunk("missing asset #{name}")
  end

  defp read_assets!(root), do: root |> Path.join("assets.json") |> File.read!() |> Jason.decode!()

  defp artifact(id, attempt, opts \\ []) do
    %{
      "id" => id,
      "name" => "source-77-a#{attempt}-linux-x64-archive",
      "digest" => "sha256:" <> String.duplicate(Integer.to_string(attempt), 64),
      "created_at" => "2026-07-28T00:00:00Z",
      "expired" => Keyword.get(opts, :expired, false)
    }
  end

  defp qualification_artifact(id, attempt, target, phase) do
    %{
      "id" => id,
      "name" => "source-77-a#{attempt}-#{target}-#{phase}-row",
      "digest" => "sha256:" <> String.duplicate("d", 64),
      "created_at" => "2026-07-28T00:00:00Z",
      "expired" => false
    }
  end

  defp write_native_job_fixtures!(root, producer_attempts) do
    for attempt <- 1..3 do
      produced? = attempt in producer_attempts

      write_json!(Path.join(root, "jobs-#{attempt}.json"), [
        %{
          "jobs" => [
            %{
              "name" => "build-linux-x64",
              "conclusion" => if(produced?, do: "success", else: "skipped"),
              "steps" => [
                %{
                  "name" => "Upload immutable native archive",
                  "conclusion" => if(produced?, do: "success", else: "skipped")
                }
              ]
            }
          ]
        }
      ])
    end
  end

  defp write_qualification_job_fixtures!(
         root,
         phase,
         target,
         producer_attempts,
         duplicate_attempts \\ []
       ) do
    {job_name, step_name} =
      case phase do
        :m0a3 -> {"m0a3-license-#{target}", "Upload immutable M0.a3 target row"}
        :m0c3 -> {"m0c3-fv-#{target}", "Upload immutable M0.c3 target row"}
      end

    for attempt <- 1..3 do
      produced? = attempt in producer_attempts

      job = %{
        "name" => job_name,
        "conclusion" => if(produced?, do: "success", else: "skipped"),
        "steps" => [
          %{
            "name" => step_name,
            "conclusion" => if(produced?, do: "success", else: "skipped")
          }
        ]
      }

      jobs = if attempt in duplicate_attempts, do: [job, job], else: [job]

      write_json!(Path.join(root, "jobs-#{attempt}.json"), [
        %{
          "jobs" => jobs
        }
      ])
    end
  end

  defp write_artifacts!(root, artifacts) do
    write_json!(Path.join(root, "artifacts.json"), [
      %{"total_count" => length(artifacts), "artifacts" => artifacts}
    ])
  end

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value))
end
