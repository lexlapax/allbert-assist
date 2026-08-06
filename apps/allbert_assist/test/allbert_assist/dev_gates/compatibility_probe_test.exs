defmodule AllbertAssist.DevGates.CompatibilityProbeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.DevGates.CompatibilityProbe

  @image "elixir:1.20.2-otp-29@sha256:7ee41a9a8a8427dbd40c9133ee5b9047f585b58db4968fd675fbcd9498e3b22e"

  test "Docker command pins the image and isolates all writable build state" do
    root = Path.join(System.tmp_dir!(), "source with spaces")
    work = Path.join(System.tmp_dir!(), "compat with spaces")
    args = CompatibilityProbe.docker_args(root, work, uid_gid: {501, 20})

    assert Enum.take(args, 5) == ["run", "--rm", "--pull=always", "--user", "501:20"]
    assert @image in args
    assert "type=bind,source=#{Path.expand(root)},target=/source,readonly" in args
    assert "type=bind,source=#{Path.expand(work)},target=/compat" in args
    assert Enum.chunk_every(args, 2, 1) |> Enum.any?(&(&1 == ["--workdir", "/compat/source"]))

    assert "MIX_BUILD_PATH=/compat/_build" in args
    assert "MIX_DEPS_PATH=/compat/deps" in args
    assert "MIX_HOME=/compat/mix" in args
    assert "HEX_HOME=/compat/hex" in args

    script = List.last(args)
    assert script =~ "mix local.hex 2.5.1 --force"
    assert script =~ "releases/download/3.25.1/rebar3"
    assert script =~ "--sha512 69073f6a"

    assert script =~
             "tar --null --verbatim-files-from --no-recursion -C /source -cf /compat/source.tar -T /compat/source-files.zlist"

    assert script =~ "ln -s /compat/deps /compat/source/deps"
    assert script =~ "ln -s /compat/_build /compat/source/_build"
    assert script =~ "mix deps.get --only test"
    assert script =~ "mix compile --force --warnings-as-errors"
    refute script =~ "cp -a /source/deps"
  end

  test "observed tuple is complete and exact" do
    observed = CompatibilityProbe.parse_observed!(passing_output())

    assert :ok = CompatibilityProbe.validate_observed!(observed)
    assert observed["otp_version"] == "29.0.1"
    assert observed["arch"] == "aarch64"

    assert_raise Mix.Error, ~r/elixir=.*expected "1.20.2"/, fn ->
      observed |> Map.put("elixir", "1.20.1") |> CompatibilityProbe.validate_observed!()
    end

    assert_raise Mix.Error, ~r/missing ALLBERT_COMPAT_REBAR3/, fn ->
      passing_output()
      |> String.replace("ALLBERT_COMPAT_REBAR3=3.25.1\n", "")
      |> CompatibilityProbe.parse_observed!()
    end
  end

  test "successful run writes exact-state evidence and checks state before and after" do
    root = temporary_dir!("root")
    work = temporary_dir!("work")
    evidence = Path.join(root, "compatibility.json")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(work)
    end)

    parent = self()
    attestation = attestation()

    verifier = fn seen_root ->
      send(parent, {:verified, seen_root})
      attestation
    end

    runner = fn "docker", args, opts ->
      send(parent, {:command, args, opts})
      {passing_output(), 0}
    end

    artifact =
      CompatibilityProbe.run!(root,
        work_root: work,
        path: evidence,
        uid_gid: {501, 20},
        attestation_verifier: verifier,
        command_runner: runner,
        source_manifest_writer: fn _, _ -> :ok end,
        metrics_recorder: fn _ -> :ok end
      )

    assert_received {:verified, _}
    assert_received {:verified, _}
    assert_received {:command, args, [stderr_to_stdout: true]}
    assert @image in args
    assert artifact["head_sha"] == attestation["head_sha"]
    assert artifact["observed"]["elixir"] == "1.20.2"
    assert Jason.decode!(File.read!(evidence))["image_digest"] =~ ~r/^sha256:/
    assert Path.wildcard(evidence <> ".tmp-*") == []
  end

  test "source manifest includes Git-visible files and excludes ignored host tooling" do
    root = temporary_dir!("git-root")
    work = temporary_dir!("git-work")
    evidence = Path.join(root, "compatibility.json")
    parent = self()

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(work)
    end)

    File.write!(Path.join(root, ".gitignore"), "ignored-tooling/\n")
    File.write!(Path.join(root, "tracked.ex"), "tracked")
    File.write!(Path.join(root, "untracked\nsource.ex"), "untracked")
    File.mkdir_p!(Path.join(root, "ignored-tooling"))
    File.write!(Path.join(root, "ignored-tooling/cache"), "ignored")
    {_output, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    {_output, 0} = System.cmd("git", ["add", ".gitignore", "tracked.ex"], cd: root)

    runner = fn "docker", _args, _opts ->
      paths =
        work
        |> Path.join("source-files.zlist")
        |> File.read!()
        |> String.split(<<0>>, trim: true)

      send(parent, {:source_paths, paths})
      {passing_output(), 0}
    end

    CompatibilityProbe.run!(root,
      work_root: work,
      path: evidence,
      uid_gid: {501, 20},
      attestation_verifier: fn _ -> attestation() end,
      command_runner: runner,
      metrics_recorder: fn _ -> :ok end
    )

    assert_received {:source_paths, paths}
    assert ".gitignore" in paths
    assert "tracked.ex" in paths
    assert "untracked\nsource.ex" in paths
    refute "ignored-tooling/cache" in paths
  end

  test "failed command leaves no stale compatibility attestation" do
    root = temporary_dir!("root")
    work = temporary_dir!("work")
    evidence = Path.join(root, "compatibility.json")
    File.write!(evidence, "stale")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(work)
    end)

    assert_raise Mix.Error, ~r/failed with status 17/, fn ->
      CompatibilityProbe.run!(root,
        work_root: work,
        path: evidence,
        uid_gid: {501, 20},
        attestation_verifier: fn _ -> attestation() end,
        command_runner: fn _, _, _ -> {"compiler warning", 17} end,
        source_manifest_writer: fn _, _ -> :ok end,
        metrics_recorder: fn _ -> :ok end
      )
    end

    refute File.exists?(evidence)
  end

  defp passing_output do
    """
    Compiling 12 files (.ex)
    ALLBERT_COMPAT_ELIXIR=1.20.2
    ALLBERT_COMPAT_OTP_RELEASE=29
    ALLBERT_COMPAT_OTP_VERSION=29.0.1
    ALLBERT_COMPAT_HEX=2.5.1
    ALLBERT_COMPAT_REBAR3=3.25.1
    ALLBERT_COMPAT_OS=Linux
    ALLBERT_COMPAT_ARCH=aarch64
    """
  end

  defp attestation do
    %{
      "head_sha" => String.duplicate("a", 40),
      "worktree_content_digest" => String.duplicate("b", 64),
      "mix_lock_digest" => String.duplicate("c", 64),
      "gate_definition_digest" => String.duplicate("d", 64)
    }
  end

  defp temporary_dir!(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "allbert-compatibility-test-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end
end
