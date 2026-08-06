defmodule AllbertAssist.Release.PromotionWorkflowContractTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.SecurityFixtures.AssertBinding

  @repo_root Path.expand("../../../../../", __DIR__)
  @workflow_path Path.join(@repo_root, ".github/workflows/release-artifacts.yml")
  @build_script Path.join(@repo_root, "scripts/release/build_candidate.sh")
  @prod_config Path.join(@repo_root, "config/prod.exs")
  @stage_script Path.join(@repo_root, "scripts/release/stage_artifacts.sh")
  @promote_script Path.join(@repo_root, "scripts/release/promote_artifacts.sh")
  @checkout_sha "3d3c42e5aac5ba805825da76410c181273ba90b1"
  @upload_sha "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
  @cosign_sha "6f9f17788090df1f26f669e9d70d6ae9567deba6"

  @dispatch_inputs ~w(
    candidate_generation
    candidate_manifest_asset_digest
    candidate_manifest_asset_id
    configured_provider_validation
    operation
    operator_tui_validation
    qualification_artifact_digest
    qualification_artifact_id
    qualification_run_id
    release_id
    source_sha
    tag
  )

  test "operator-built drafts have disjoint no-build qualification and protected promotion paths" do
    workflow = workflow!()
    triggers = workflow["on"]
    jobs = workflow["jobs"]
    inputs = triggers["workflow_dispatch"]["inputs"]

    assert Map.keys(triggers) == ["workflow_dispatch"]
    assert Enum.sort(Map.keys(inputs)) == @dispatch_inputs
    assert inputs["operation"]["type"] == "choice"
    assert inputs["operation"]["options"] == ["qualification", "promotion"]
    assert Map.keys(jobs) |> Enum.sort() == ~w(promote qualification-evidence qualify)
    refute Map.has_key?(jobs, "build")
    refute Map.has_key?(jobs, "gate")

    assert jobs["qualify"]["if"] == "inputs.operation == 'qualification'"
    assert jobs["qualification-evidence"]["needs"] == "qualify"
    assert jobs["promote"]["if"] == "inputs.operation == 'promotion'"
    assert jobs["promote"]["environment"] == "release-promotion"

    assert jobs["promote"]["permissions"] == %{
             "actions" => "read",
             "contents" => "write",
             "id-token" => "write"
           }

    assert jobs["qualify"]["permissions"] == %{"contents" => "write"}

    assert jobs["qualification-evidence"]["permissions"] == %{
             "actions" => "read",
             "contents" => "write"
           }

    expected_runners = %{
      "linux-arm64" => "ubuntu-24.04-arm",
      "linux-x64" => "ubuntu-24.04",
      "macos-arm64" => "macos-15"
    }

    assert matrix_runner_map(jobs["qualify"]) == expected_runners

    workflow_text = File.read!(@workflow_path)
    refute workflow_text =~ "mix release"
    refute workflow_text =~ "setup-beam@"
    refute workflow_text =~ "push:\n    tags:"
    refute workflow_text =~ "--clobber"
    assert workflow_text =~ "qualify-target"
    assert workflow_text =~ "collect-qualification"
    assert workflow_text =~ "release-promotion"
    assert workflow_text =~ "Draft releases are visible only to identities with push access"
  end

  test "workflow actions are exact pins and qualification uploads are attempt-qualified" do
    workflow = workflow!()
    steps = all_steps(workflow)
    refs = for %{"uses" => uses} <- steps, do: uses

    assert refs != []
    assert Enum.all?(refs, &Regex.match?(~r/@[0-9a-f]{40}$/, &1))
    assert "actions/checkout@#{@checkout_sha}" in refs
    assert "actions/upload-artifact@#{@upload_sha}" in refs
    assert "sigstore/cosign-installer@#{@cosign_sha}" in refs

    uploads =
      Enum.filter(steps, &String.starts_with?(&1["uses"] || "", "actions/upload-artifact@"))

    assert length(uploads) == 2

    assert Enum.all?(uploads, fn step ->
             with = step["with"]

             with["if-no-files-found"] == "error" and with["retention-days"] == 30 and
               with["overwrite"] == false and with["name"] =~ "${{ github.run_attempt }}"
           end)

    promotion_text = inspect(workflow["jobs"]["promote"], limit: :infinity)
    refute promotion_text =~ "actions/checkout@"
    refute promotion_text =~ "mix release"
    assert promotion_text =~ "promote_artifacts.sh?ref=${SOURCE_SHA}"
    assert promotion_text =~ "OPERATOR_TUI_VALIDATION"
    assert promotion_text =~ "CONFIGURED_PROVIDER_VALIDATION"
  end

  test "one thin builder emits an exact four-file target set and package-stable macOS evidence" do
    body = File.read!(@build_script)

    assert body =~ "ALLBERT_EXPECTED_SHA"
    assert body =~ "ALLBERT_CANDIDATE_GENERATION"
    assert body =~ "ALLBERT_BUILDER_CLASS"
    assert body =~ "export MIX_ENV=prod"
    assert body =~ "export LC_ALL=C.UTF-8"
    assert body =~ ~S|mix release allbert --overwrite --path "$RELEASE_ROOT"|
    assert body =~ "operator-macos"
    assert body =~ "docker-linux"
    assert body =~ "hexpm/erlang"
    assert body =~ "d8c7836b5b2b3b90918fb504b9eac563814503957875658528d9ab4581bf1e6b"
    assert body =~ "glibc $LINUX_GLIBC_VERSION"
    assert body =~ "libcrypto.so.3"
    assert body =~ "OpenSSL 3."
    assert body =~ "libsctp1"
    assert body =~ "1.0.19+dfsg-2"
    assert body =~ "ALLBERT_RELEASE_LIBSCTP_PATH"
    assert body =~ "ALLBERT_RELEASE_FORCE_EXQLITE_BUILD=1"
    assert body =~ "NATIVE_NIFS=source"
    prod_config = File.read!(@prod_config)
    assert prod_config =~ ~s|System.get_env("ALLBERT_RELEASE_FORCE_EXQLITE_BUILD") == "1"|
    assert prod_config =~ "config :exqlite, force_build: true"
    assert body =~ "Linux/aarch64"
    assert body =~ "candidate build and smoke must run as a non-root user"
    assert body =~ "mix release allbert --overwrite"
    assert body =~ "artifact_smoke.sh"
    assert body =~ ~S|cat "$WORK/smoke.log" >&2|
    assert body =~ ~S|fail "target smoke exited non-zero"|
    assert body =~ "29.0.1"
    assert body =~ "1.19.5"
    assert body =~ "2.5.1"
    assert body =~ "3.25.1"
    assert body =~ "NODE_VERSION"
    assert body =~ "BROWSER_VERSION"
    assert body =~ ~S|openssl: (if $openssl == "" then null else $openssl end)|
    assert body =~ "external_runtime: {node: $node, playwright: $playwright, browser: $browser}"
    assert body =~ "@loader_path/sqlite3_nif.so"
    assert body =~ ~S|mv "$WORK/$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE"|
    assert body =~ ~S|mv "$WORK/$TOOLCHAIN" "$OUTPUT_DIR/$TOOLCHAIN"|
    assert body =~ ~S|mv "$WORK/$SMOKE" "$OUTPUT_DIR/$SMOKE"|
    assert body =~ ~S|mv "$WORK/$DIGEST" "$OUTPUT_DIR/$DIGEST"|
    refute body =~ "gh api"
    refute body =~ "ssh "
    refute body =~ "docker run"
  end

  test "staging binds one empty draft to a complete no-clobber generation" do
    stage = File.read!(@stage_script)

    assert stage =~ "draft must have zero assets before complete-generation staging"
    assert stage =~ "candidate directory has missing, duplicate, or unexpected files"
    assert stage =~ "allbert-release-candidate-manifest"
    assert stage =~ "release_id"
    assert stage =~ "source_sha"
    assert stage =~ "generation"
    assert stage =~ "asset_id"
    assert stage =~ "asset_digest"
    assert stage =~ "GitHub digest differs"
    assert stage =~ "exactly 13 candidate assets"
    assert stage =~ "libcrypto.so.3"
    assert stage =~ "OpenSSL 3."
    assert stage =~ "libsctp1"
    assert stage =~ "linux_sctp"
    assert stage =~ "qualify-target"
    assert stage =~ ".[].artifacts[]"
    assert stage =~ "Linux qualifier host requires glibc >= 2.36"
    assert stage =~ "licenses --json"
    assert stage =~ "smoke/tui_qualification.sh"
    refute stage =~ "--clobber"
    refute stage =~ "actions/runs/${GITHUB_RUN_ID}/attempts"
    refute stage =~ "successful producer"
  end

  @tag :preflight_fixture_historical_contracts
  test "promotion revalidates operator evidence, immutable releases, and the exact draft" do
    promoter = File.read!(@promote_script)

    assert promoter =~ "/immutable-releases"
    assert promoter =~ "GitHub immutable releases are not enabled"
    assert promoter =~ "operator TUI validation is not confirmed"
    assert promoter =~ "configured-provider validation is not confirmed"
    assert promoter =~ "provisional tag does not peel to source SHA"
    assert promoter =~ "candidate manifest binding is invalid"
    assert promoter =~ "qualification manifest binding is invalid"
    assert promoter =~ "draft contains missing, duplicate, or unexpected pre-promotion assets"
    assert promoter =~ "SHA256SUMS"
    assert promoter =~ "sign-blob"
    assert promoter =~ "https://token.actions.githubusercontent.com"
    assert promoter =~ "exact final 18-asset set"
    assert promoter =~ "published release did not become immutable"
    assert promoter =~ ~S|allbert-${target}.tar.gz|
    refute promoter =~ "release create"
    refute promoter =~ "--clobber"
    refute promoter =~ "mix release"
    refute promoter =~ "setup-beam"

    AssertBinding.check!("v121-promotion-evidence-001", [
      :age_boundary_exact,
      :semantic_tamper_rejected,
      :restartable_assets_fail_closed
    ])
  end

  test "release tar preflight rejects traversal and unsafe links before extraction" do
    assert {_, 0} = run_stage(["validate-release-path", "allbert/lib/app.beam"])

    for unsafe <- ["../escape", "allbert/../../escape", "/absolute", "other/file"] do
      assert {output, status} = run_stage(["validate-release-path", unsafe])
      assert status != 0
      assert output =~ "unsafe release archive entry"
    end

    assert {_, 0} =
             run_stage([
               "validate-release-link",
               "symlink",
               "allbert/bin/link",
               "../libexec/tool"
             ])

    for {type, member, target} <- [
          {"symlink", "allbert/bin/link", "../../escape"},
          {"symlink", "allbert/bin/link", "/absolute"},
          {"hardlink", "allbert/bin/link", "../escape"}
        ] do
      assert {output, status} =
               run_stage(["validate-release-link", type, member, target])

      assert status != 0
      assert output =~ "unsafe release archive link"
    end
  end

  test "operator extraction mode preflights and extracts one release root" do
    root =
      Path.join(System.tmp_dir!(), "allbert-stage-extract-#{System.unique_integer([:positive])}")

    source = Path.join(root, "source")
    destination = Path.join(root, "destination")
    archive = Path.join(root, "allbert.tar.gz")
    executable = Path.join([source, "allbert", "bin", "allbert"])
    manifest = Path.join([source, "allbert", "THIRD-PARTY-MANIFEST.json"])
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)
    File.write!(manifest, "{}\n")
    File.chmod!(manifest, 0o644)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_, 0} = System.cmd("tar", ["-czf", archive, "-C", source, "allbert"])
    assert {_, 0} = run_stage(["extract-release", archive, destination])
    assert File.stat!(Path.join([destination, "allbert", "bin", "allbert"])).type == :regular

    assert Bitwise.band(
             File.stat!(Path.join([destination, "allbert", "bin", "allbert"])).mode,
             0o777
           ) ==
             0o755

    assert Bitwise.band(
             File.stat!(Path.join([destination, "allbert", "THIRD-PARTY-MANIFEST.json"])).mode,
             0o777
           ) ==
             0o644
  end

  test "release helpers are executable, warning-free shell, and contain no aggregate gates" do
    for script <- [@build_script, @stage_script, @promote_script] do
      assert Bitwise.band(File.stat!(script).mode, 0o111) != 0
      assert {output, 0} = System.cmd("bash", ["-n", script], stderr_to_stdout: true)
      assert output == ""
    end

    combined =
      Enum.map_join(
        [@workflow_path, @build_script, @stage_script, @promote_script],
        "\n",
        &File.read!/1
      )

    for forbidden <- [
          "mix precommit",
          "mix allbert.test",
          "release.v1",
          "release.v12",
          "release.v121",
          "release.v13"
        ] do
      refute combined =~ forbidden
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

  defp run_stage(args), do: System.cmd("bash", [@stage_script | args], stderr_to_stdout: true)
end
