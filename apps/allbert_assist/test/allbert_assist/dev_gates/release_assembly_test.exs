defmodule AllbertAssist.DevGates.ReleaseAssemblyTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.ReleaseAssembly
  alias AllbertAssist.Licenses

  @sha_a String.duplicate("a", 64)
  @sha_b String.duplicate("b", 64)
  @sha_c String.duplicate("c", 64)
  @sha_d String.duplicate("d", 64)
  @marker "ALLBERT_RELEASE_ASSEMBLY_V1="

  test "builds and verifies from a disposable Home, records digests, and removes it on PASS" do
    temp_root = temp_path("pass")
    release_root = Path.join(temp_root, "release")
    stale_path = Path.join([release_root, "lib", "allbert_assist-1.2.6", "ebin", "stale.beam"])
    metrics_store = Path.join(temp_path("metrics"), "runs.jsonl")
    parent = self()

    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale release byte")

    result_line =
      "ALLBERT_RELEASE_ASSEMBLY_V1=" <>
        Jason.encode!(%{
          "schema_version" => 1,
          "status" => "PASS",
          "checkpoint" => "v14-m1a1",
          "rel_sha256" => @sha_a,
          "app_sha256" => %{
            "allbert_kernel" => @sha_b,
            "allbert_assist" => @sha_c
          },
          "pack_projection_sha256" => @sha_d
        }) <>
        "\n"

    runner = fn command ->
      send(parent, {:command, command})

      case command.id do
        "build_release" ->
          refute File.exists?(stale_path)
          write_verifier_executable!(release_root)
          {"release built\n", 0}

        "verify_projection" ->
          {result_line, 0}
      end
    end

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(Path.dirname(metrics_store))
    end)

    assert %{
             status: "passed",
             checkpoint: "v14-m1a1",
             rel_sha256: @sha_a,
             kernel_app_sha256: @sha_b,
             residual_app_sha256: @sha_c,
             pack_projection_sha256: @sha_d
           } =
             ReleaseAssembly.run!("v14-m1a1",
               root: repo_root(),
               temp_root_factory: fn ->
                 File.mkdir_p!(temp_root)
                 temp_root
               end,
               release_root: release_root,
               command_runner: runner,
               metrics_store: metrics_store,
               emit: fn message -> send(parent, {:emit, message}) end
             )

    refute File.exists?(temp_root)

    assert_received {:command,
                     %{
                       id: "build_release",
                       cwd: cwd,
                       executable: "mix",
                       args: ["release", "allbert", "--overwrite"],
                       env: build_env
                     }}

    assert cwd == repo_root()
    assert Map.new(build_env)["MIX_ENV"] == "prod"
    assert Map.new(build_env)["ALLBERT_HOME"] == Path.join(temp_root, "home")
    assert Map.new(build_env)["ALLBERT_SETTINGS_ROOT"] == nil

    assert_received {:command,
                     %{
                       id: "verify_projection",
                       cwd: ^cwd,
                       executable: verifier_executable,
                       args: ["eval", verifier_eval],
                       env: verify_env
                     }}

    assert verifier_executable == Path.join(release_root, "bin/allbert")
    assert verifier_eval =~ "AllbertAssist.Pack.ReleaseAssemblyVerifier.verify!"
    assert Map.new(verify_env)["MIX_ENV"] == "prod"
    assert Map.new(verify_env)["ALLBERT_RELEASE_ASSEMBLY_CHECKPOINT"] == "v14-m1a1"

    assert Map.new(verify_env)["ALLBERT_RELEASE_ROOT"] == release_root

    assert [record] = read_metrics(metrics_store)
    assert record["gate"] == "release-assembly"
    assert record["checkpoint"] == "v14-m1a1"
    assert record["status"] == "passed"
    assert record["rel_sha256"] == @sha_a
    assert record["kernel_app_sha256"] == @sha_b
    assert record["residual_app_sha256"] == @sha_c
    assert record["pack_projection_sha256"] == @sha_d
    assert is_integer(record["wall_ms"])
  end

  test "retains the disposable root and records one failed row when verification fails" do
    temp_root = temp_path("fail")
    release_root = Path.join(temp_root, "release")
    metrics_store = Path.join(temp_path("failed-metrics"), "runs.jsonl")
    parent = self()

    runner = fn
      %{id: "build_release"} ->
        write_verifier_executable!(release_root)
        {"release built\n", 0}

      %{id: "verify_projection"} ->
        {"projection mismatch token=secret-token\n", 9}
    end

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(Path.dirname(metrics_store))
    end)

    error =
      assert_raise Mix.Error,
                   ~r/release-assembly verify_projection failed with status 9; retained temp root: #{Regex.escape(temp_root)}/,
                   fn ->
                     ReleaseAssembly.run!("v14-m1a1",
                       root: repo_root(),
                       temp_root_factory: fn ->
                         File.mkdir_p!(temp_root)
                         temp_root
                       end,
                       release_root: release_root,
                       command_runner: runner,
                       metrics_store: metrics_store,
                       emit: fn message -> send(parent, {:emit, message}) end
                     )
                   end

    refute error.message =~ "projection mismatch"

    assert File.dir?(temp_root)

    assert_received {:emit, "release-assembly v14-m1a1 FAIL; retained temp root: " <> ^temp_root}

    log_path = Path.join(temp_root, "verify_projection.log")
    assert File.read!(log_path) =~ "projection mismatch"
    refute File.read!(log_path) =~ "secret-token"
    assert File.read!(log_path) =~ "token=[REDACTED]"

    assert [record] = read_metrics(metrics_store)
    assert record["gate"] == "release-assembly"
    assert record["checkpoint"] == "v14-m1a1"
    assert record["status"] == "failed"
    assert record["rel_sha256"] == nil
    assert record["kernel_app_sha256"] == nil
    assert record["residual_app_sha256"] == nil
    assert record["pack_projection_sha256"] == nil
    assert is_integer(record["wall_ms"])
  end

  test "rejects a symlinked verifier ancestor before dispatch" do
    temp_root = temp_path("symlinked-verifier-ancestor")
    release_root = Path.join(temp_root, "release")
    outside_root = temp_path("symlinked-verifier-target")
    outside_executable = Path.join(outside_root, "allbert")

    File.mkdir_p!(outside_root)
    File.write!(outside_executable, "outside packaged release executable")
    File.chmod!(outside_executable, 0o755)

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(outside_root)
    end)

    assert_raise Mix.Error, ~r/release-assembly release root crosses a symlink/, fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: repo_root(),
        temp_root_factory: fn ->
          File.mkdir_p!(temp_root)
          temp_root
        end,
        release_root: release_root,
        command_runner: fn
          %{id: "build_release"} ->
            File.mkdir_p!(release_root)
            File.ln_s!(outside_root, Path.join(release_root, "bin"))
            {"release built\n", 0}

          %{id: "verify_projection"} ->
            flunk("symlinked verifier must not be dispatched")
        end,
        metrics_store: :disabled,
        emit: fn _message -> :ok end
      )
    end

    assert File.read!(outside_executable) == "outside packaged release executable"
    assert File.dir?(temp_root)
  end

  test "records failure instead of PASS when disposable-root cleanup fails" do
    temp_root = temp_path("cleanup-failure")
    release_root = Path.join(temp_root, "release")
    metrics_store = Path.join(temp_path("cleanup-failure-metrics"), "runs.jsonl")

    result_line = @marker <> canonical_payload() <> "\n"

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(Path.dirname(metrics_store))
    end)

    assert_raise RuntimeError, "cleanup failed", fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: repo_root(),
        temp_root_factory: fn ->
          File.mkdir_p!(temp_root)
          temp_root
        end,
        release_root: release_root,
        command_runner: fn
          %{id: "build_release"} ->
            write_verifier_executable!(release_root)
            {"release built\n", 0}

          %{id: "verify_projection"} ->
            {result_line, 0}
        end,
        temp_root_cleanup: fn _path -> raise "cleanup failed" end,
        metrics_store: metrics_store,
        emit: fn _message -> :ok end
      )
    end

    assert File.dir?(temp_root)
    assert [%{"status" => "failed", "checkpoint" => "v14-m1a1"}] = read_metrics(metrics_store)
  end

  test "cleans the exact generated release root before invoking the build" do
    owner_root = temp_path("default-release-root")
    temp_root = Path.join(owner_root, "assembly")
    root = Path.join(owner_root, "repo")
    release_root = Path.join(root, "_build/prod/rel/allbert")
    stale_path = Path.join([release_root, "lib", "allbert_assist-1.2.6", "stale.beam"])

    File.mkdir_p!(temp_root)
    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale release byte")

    on_exit(fn -> File.rm_rf!(owner_root) end)

    assert_raise Mix.Error, ~r/release-assembly build_release failed with status 9/, fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: root,
        temp_root_factory: fn -> temp_root end,
        command_runner: fn %{id: "build_release"} ->
          refute File.exists?(stale_path)
          {"stop after cleanup\n", 9}
        end,
        metrics_store: :disabled,
        emit: fn _message -> :ok end
      )
    end

    refute File.exists?(release_root)
    assert File.dir?(temp_root)
  end

  test "rejects a verifier result whose required digest has the wrong shape" do
    temp_root = temp_path("invalid-result")
    release_root = Path.join(temp_root, "release")
    metrics_store = Path.join(temp_path("invalid-result-metrics"), "runs.jsonl")

    invalid_line =
      "ALLBERT_RELEASE_ASSEMBLY_V1=" <>
        Jason.encode!(%{
          "schema_version" => 1,
          "status" => "PASS",
          "checkpoint" => "v14-m1a1",
          "rel_sha256" => nil,
          "app_sha256" => %{
            "allbert_kernel" => @sha_b,
            "allbert_assist" => @sha_c
          },
          "pack_projection_sha256" => @sha_d
        }) <>
        "\n"

    runner = fn
      %{id: "build_release"} ->
        write_verifier_executable!(release_root)
        {"release built\n", 0}

      %{id: "verify_projection"} ->
        {invalid_line, 0}
    end

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(Path.dirname(metrics_store))
    end)

    assert_raise Mix.Error,
                 "release-assembly verifier rel_sha256 must be a lowercase SHA-256",
                 fn ->
                   ReleaseAssembly.run!("v14-m1a1",
                     root: repo_root(),
                     temp_root_factory: fn ->
                       File.mkdir_p!(temp_root)
                       temp_root
                     end,
                     release_root: release_root,
                     command_runner: runner,
                     metrics_store: metrics_store,
                     emit: fn _message -> :ok end
                   )
                 end

    assert File.dir?(temp_root)
    assert [%{"status" => "failed", "checkpoint" => "v14-m1a1"}] = read_metrics(metrics_store)
  end

  test "rejects fields outside the checkpoint evidence schema" do
    temp_root = temp_path("unexpected-result-field")
    release_root = Path.join(temp_root, "release")

    line =
      "ALLBERT_RELEASE_ASSEMBLY_V1=" <>
        Jason.encode!(%{
          "schema_version" => 1,
          "status" => "PASS",
          "checkpoint" => "v14-m1a1",
          "rel_sha256" => @sha_a,
          "app_sha256" => %{
            "allbert_kernel" => @sha_b,
            "allbert_assist" => @sha_c
          },
          "pack_projection_sha256" => @sha_d,
          "unbound_evidence" => @sha_a
        }) <>
        "\n"

    runner = fn
      %{id: "build_release"} ->
        write_verifier_executable!(release_root)
        {"release built\n", 0}

      %{id: "verify_projection"} ->
        {line, 0}
    end

    on_exit(fn -> File.rm_rf!(temp_root) end)

    assert_raise Mix.Error, ~r/result keys must be exactly/, fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: repo_root(),
        temp_root_factory: fn ->
          File.mkdir_p!(temp_root)
          temp_root
        end,
        release_root: release_root,
        command_runner: runner,
        metrics_store: :disabled,
        emit: fn _message -> :ok end
      )
    end

    assert File.dir?(temp_root)
  end

  test "rejects a verifier result whose JSON object keys are not in canonical order" do
    payload =
      ~s({"status":"PASS","schema_version":1,"rel_sha256":"#{@sha_a}","pack_projection_sha256":"#{@sha_d}","checkpoint":"v14-m1a1","app_sha256":{"allbert_kernel":"#{@sha_b}","allbert_assist":"#{@sha_c}"}})

    assert_result_payload_rejected(
      payload,
      "release-assembly verifier result must use canonical JSON encoding"
    )
  end

  test "rejects a verifier result with non-canonical JSON whitespace" do
    payload =
      canonical_payload()
      |> String.replace(~S("checkpoint":"v14-m1a1"), ~S("checkpoint": "v14-m1a1"))

    assert_result_payload_rejected(
      payload,
      "release-assembly verifier result must use canonical JSON encoding"
    )
  end

  test "rejects a verifier result with a non-canonical JSON escape" do
    payload = String.replace(canonical_payload(), ~S("PASS"), ~S("\u0050ASS"))

    assert_result_payload_rejected(
      payload,
      "release-assembly verifier result must use canonical JSON encoding"
    )
  end

  test "rejects a verifier result with duplicate JSON object keys" do
    payload =
      canonical_payload()
      |> String.replace(~S("status":"PASS"), ~S("status":"PASS","status":"PASS"))

    assert_result_payload_rejected(
      payload,
      "release-assembly verifier result must use canonical JSON encoding"
    )
  end

  test "rejects a non-integer schema version even when it is numerically equal" do
    assert_result_payload_rejected(
      canonical_payload(1.0),
      "release-assembly verifier schema_version must equal 1"
    )
  end

  test "rejects duplicate machine-readable verifier result lines" do
    temp_root = temp_path("duplicate-result")
    release_root = Path.join(temp_root, "release")
    metrics_store = Path.join(temp_path("duplicate-result-metrics"), "runs.jsonl")

    line =
      "ALLBERT_RELEASE_ASSEMBLY_V1=" <>
        Jason.encode!(%{
          "schema_version" => 1,
          "status" => "PASS",
          "checkpoint" => "v14-m1a1",
          "rel_sha256" => @sha_a,
          "app_sha256" => %{
            "allbert_kernel" => @sha_b,
            "allbert_assist" => @sha_c
          },
          "pack_projection_sha256" => @sha_d
        }) <>
        "\n"

    runner = fn
      %{id: "build_release"} ->
        write_verifier_executable!(release_root)
        {"release built\n", 0}

      %{id: "verify_projection"} ->
        {line <> line, 0}
    end

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(Path.dirname(metrics_store))
    end)

    assert_raise Mix.Error,
                 "release-assembly verifier emitted duplicate ALLBERT_RELEASE_ASSEMBLY_V1= results",
                 fn ->
                   ReleaseAssembly.run!("v14-m1a1",
                     root: repo_root(),
                     temp_root_factory: fn ->
                       File.mkdir_p!(temp_root)
                       temp_root
                     end,
                     release_root: release_root,
                     command_runner: runner,
                     metrics_store: metrics_store,
                     emit: fn _message -> :ok end
                   )
                 end

    assert [%{"status" => "failed"}] = read_metrics(metrics_store)
    assert File.dir?(temp_root)
  end

  test "refuses to treat the system temp root itself as disposable" do
    assert_raise Mix.Error,
                 ~r/release-assembly temp root must be an existing directory under/,
                 fn ->
                   ReleaseAssembly.run!("v14-m1a1",
                     temp_root_factory: fn -> System.tmp_dir!() end,
                     command_runner: fn _command -> flunk("command must not run") end
                   )
                 end
  end

  test "refuses an arbitrary release root outside its generated or disposable boundaries" do
    temp_root = temp_path("unsafe-root")
    outside_root = temp_path("outside-root")

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(outside_root)
    end)

    assert_raise Mix.Error, ~r/release-assembly release root must be the generated default/, fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: repo_root(),
        temp_root_factory: fn ->
          File.mkdir_p!(temp_root)
          temp_root
        end,
        release_root: outside_root,
        command_runner: fn _command -> flunk("command must not run") end,
        metrics_store: :disabled,
        emit: fn _message -> :ok end
      )
    end

    assert File.dir?(temp_root)
  end

  test "refuses a symlinked release root without touching its target" do
    temp_root = temp_path("symlink-root")
    outside_root = temp_path("symlink-target")
    release_root = Path.join(temp_root, "release")
    sentinel = Path.join(outside_root, "keep.txt")

    File.mkdir_p!(temp_root)
    File.mkdir_p!(outside_root)
    File.write!(sentinel, "keep")
    File.ln_s!(outside_root, release_root)

    on_exit(fn ->
      File.rm_rf!(temp_root)
      File.rm_rf!(outside_root)
    end)

    assert_raise Mix.Error, ~r/release-assembly release root crosses a symlink/, fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: repo_root(),
        temp_root_factory: fn -> temp_root end,
        release_root: release_root,
        command_runner: fn _command -> flunk("command must not run") end,
        metrics_store: :disabled,
        emit: fn _message -> :ok end
      )
    end

    assert File.read!(sentinel) == "keep"
  end

  test "rejects a non-executable packaged verifier before dispatch" do
    temp_root = temp_path("non-executable-verifier")
    release_root = Path.join(temp_root, "release")

    on_exit(fn -> File.rm_rf!(temp_root) end)

    assert_raise Mix.Error, ~r/release-assembly packaged verifier is not executable/, fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: repo_root(),
        temp_root_factory: fn ->
          File.mkdir_p!(temp_root)
          temp_root
        end,
        release_root: release_root,
        command_runner: fn
          %{id: "build_release"} ->
            path = Path.join([release_root, "bin", "allbert"])
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, "not executable")
            {"release built\n", 0}

          %{id: "verify_projection"} ->
            flunk("non-executable verifier must not be dispatched")
        end,
        metrics_store: :disabled,
        emit: fn _message -> :ok end
      )
    end

    assert File.dir?(temp_root)
  end

  test "reserves the M1.a3 composition, overlay, and entrypoint digest contract" do
    temp_root = temp_path("m1a3")
    release_root = Path.join(temp_root, "release")

    line =
      "ALLBERT_RELEASE_ASSEMBLY_V1=" <>
        Jason.encode!(%{
          "schema_version" => 1,
          "status" => "PASS",
          "checkpoint" => "v14-m1a3",
          "rel_sha256" => @sha_a,
          "app_sha256" => %{
            "allbert_kernel" => @sha_b,
            "allbert_assist" => @sha_c,
            "allbert_composition" => @sha_d
          },
          "pack_projection_sha256" => @sha_a,
          "overlay_sha256" => @sha_b,
          "entrypoint_sha256" => @sha_c
        }) <>
        "\n"

    runner = fn
      %{id: "build_release"} ->
        write_verifier_executable!(release_root)
        {"release built\n", 0}

      %{id: "verify_projection"} ->
        {line, 0}
    end

    on_exit(fn -> File.rm_rf!(temp_root) end)

    assert %{
             status: "passed",
             composition_app_sha256: @sha_d,
             overlay_sha256: @sha_b,
             entrypoint_sha256: @sha_c
           } =
             ReleaseAssembly.run!("v14-m1a3",
               root: repo_root(),
               temp_root_factory: fn ->
                 File.mkdir_p!(temp_root)
                 temp_root
               end,
               release_root: release_root,
               command_runner: runner,
               metrics_store: :disabled,
               emit: fn _message -> :ok end
             )

    refute File.exists?(temp_root)
  end

  test "rejects unknown checkpoints before allocating a disposable root" do
    parent = self()

    assert_raise Mix.Error,
                 "unknown release-assembly checkpoint v14-m2; expected one of v14-m1a1, v14-m1a3",
                 fn ->
                   ReleaseAssembly.run!("v14-m2",
                     temp_root_factory: fn ->
                       send(parent, :allocated)
                       temp_path("must-not-exist")
                     end
                   )
                 end

    refute_received :allocated
  end

  defp repo_root, do: Path.expand("../../../../..", __DIR__)

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "allbert-release-assembly-test-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  defp read_metrics(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp canonical_payload(schema_version \\ 1) do
    %{
      "schema_version" => schema_version,
      "status" => "PASS",
      "checkpoint" => "v14-m1a1",
      "rel_sha256" => @sha_a,
      "app_sha256" => %{
        "allbert_kernel" => @sha_b,
        "allbert_assist" => @sha_c
      },
      "pack_projection_sha256" => @sha_d
    }
    |> Licenses.canonical_json()
    |> String.trim_trailing("\n")
  end

  defp assert_result_payload_rejected(payload, expected_message) do
    temp_root = temp_path("rejected-payload")
    release_root = Path.join(temp_root, "release")

    runner = fn
      %{id: "build_release"} ->
        write_verifier_executable!(release_root)
        {"release built\n", 0}

      %{id: "verify_projection"} ->
        {@marker <> payload <> "\n", 0}
    end

    on_exit(fn -> File.rm_rf!(temp_root) end)

    assert_raise Mix.Error, expected_message, fn ->
      ReleaseAssembly.run!("v14-m1a1",
        root: repo_root(),
        temp_root_factory: fn ->
          File.mkdir_p!(temp_root)
          temp_root
        end,
        release_root: release_root,
        command_runner: runner,
        metrics_store: :disabled,
        emit: fn _message -> :ok end
      )
    end

    assert File.dir?(temp_root)
  end

  defp write_verifier_executable!(release_root) do
    path = Path.join([release_root, "bin", "allbert"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "packaged release executable")
    File.chmod!(path, 0o755)
  end
end
