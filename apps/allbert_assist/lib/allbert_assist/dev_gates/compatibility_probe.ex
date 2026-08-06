defmodule AllbertAssist.DevGates.CompatibilityProbe do
  @moduledoc """
  Runs the bounded Elixir/OTP compatibility compile in an immutable container.

  The repository is mounted read-only and all Linux dependency/build output is
  written below a disposable host directory. This is development tooling only;
  the resulting attestation grants no runtime authority.
  """

  alias AllbertAssist.DevGates.OutputTail
  alias AllbertAssist.DevGates.Preflight
  alias AllbertAssist.DevGates.PreflightAttestation
  alias AllbertAssist.DevGates.TestMetrics

  @schema_version 1
  @relative_path ".test_metrics/compatibility-attestation.json"
  @image_name "elixir:1.20.2-otp-29"
  @image_digest "sha256:7ee41a9a8a8427dbd40c9133ee5b9047f585b58db4968fd675fbcd9498e3b22e"
  @hex_version "2.5.1"
  @rebar_version "3.25.1"
  @rebar_url "https://github.com/erlang/rebar3/releases/download/3.25.1/rebar3"
  @rebar_sha512 "69073f6ad163f74971545015238614c327893960c1b3f26df5377df135c773a0716b48b65c2a48cef878f185dd92805abc69894adfa3fd27a90c62a64ba371e2"
  @tail_limit 24_000

  def image_ref, do: @image_name <> "@" <> @image_digest
  def relative_path, do: @relative_path

  def run!(root, opts \\ []) do
    root = canonical_root!(root)
    verifier = Keyword.get(opts, :attestation_verifier, &default_verify/1)
    command_runner = Keyword.get(opts, :command_runner, &run_command/3)
    metrics_recorder = Keyword.get(opts, :metrics_recorder, &TestMetrics.record/1)
    manifest_writer = Keyword.get(opts, :source_manifest_writer, &write_source_manifest!/2)
    {work_root, owned_work_root?} = work_root!(opts)
    prepare_work_root!(work_root)
    artifact_path = path(root, opts)
    invalidate!(artifact_path)

    try do
      before = verifier.(root)
      manifest_writer.(root, work_root)
      args = docker_args(root, work_root, opts)
      started_at = System.monotonic_time(:millisecond)

      Mix.shell().info("==> compatibility probe started image=#{image_ref()}")
      {output, status} = command_runner.("docker", args, stderr_to_stdout: true)
      wall_ms = System.monotonic_time(:millisecond) - started_at
      output = to_string(output || "")

      metrics_recorder.(%{
        gate: "compatibility",
        command: "compatibility",
        cwd: ".",
        phase_or_step: "elixir_1_20_2_otp_29_compile",
        status: if(status == 0, do: "passed", else: "failed"),
        wall_ms: wall_ms,
        output: output
      })

      if status != 0 do
        Mix.raise("compatibility probe failed with status #{status}")
      end

      observed = parse_observed!(output)
      validate_observed!(observed)
      after_run = verifier.(root)
      validate_same_state!(before, after_run)

      artifact = %{
        "schema_version" => @schema_version,
        "status" => "passed",
        "head_sha" => before["head_sha"],
        "worktree_content_digest" => before["worktree_content_digest"],
        "gate_definition_digest" => before["gate_definition_digest"],
        "image" => @image_name,
        "image_digest" => @image_digest,
        "observed" => observed,
        "wall_ms" => wall_ms,
        "completed_at" => now_iso8601()
      }

      write_atomic!(artifact_path, artifact)

      Mix.shell().info(
        "==> compatibility probe passed in #{wall_ms}ms " <>
          "Elixir=#{observed["elixir"]} OTP=#{observed["otp_version"]} " <>
          "arch=#{observed["arch"]}"
      )

      Mix.shell().info("compatibility attestation: #{relative_path()}")
      artifact
    after
      if owned_work_root?, do: remove_owned_work_root!(work_root)
    end
  end

  def docker_args(root, work_root, opts \\ []) do
    {uid, gid} = Keyword.get_lazy(opts, :uid_gid, &host_uid_gid!/0)

    [
      "run",
      "--rm",
      "--pull=always",
      "--user",
      "#{uid}:#{gid}",
      "--mount",
      "type=bind,source=#{root},target=/source,readonly",
      "--mount",
      "type=bind,source=#{work_root},target=/compat",
      "--workdir",
      "/compat/source",
      "--env",
      "HOME=/compat/home",
      "--env",
      "MIX_ENV=test",
      "--env",
      "MIX_BUILD_PATH=/compat/_build",
      "--env",
      "MIX_DEPS_PATH=/compat/deps",
      "--env",
      "MIX_HOME=/compat/mix",
      "--env",
      "HEX_HOME=/compat/hex",
      "--env",
      "REBAR_CACHE_DIR=/compat/rebar-cache",
      image_ref(),
      "sh",
      "-lc",
      container_script()
    ]
  end

  def parse_observed!(output) when is_binary(output) do
    fields = [
      {"elixir", "ALLBERT_COMPAT_ELIXIR"},
      {"otp_release", "ALLBERT_COMPAT_OTP_RELEASE"},
      {"otp_version", "ALLBERT_COMPAT_OTP_VERSION"},
      {"hex", "ALLBERT_COMPAT_HEX"},
      {"rebar3", "ALLBERT_COMPAT_REBAR3"},
      {"os", "ALLBERT_COMPAT_OS"},
      {"arch", "ALLBERT_COMPAT_ARCH"}
    ]

    Map.new(fields, fn {field, marker} ->
      case Regex.run(~r/^#{marker}=(.+)$/m, output, capture: :all_but_first) do
        [value] -> {field, String.trim(value)}
        _ -> Mix.raise("compatibility probe output is missing #{marker}")
      end
    end)
  end

  def validate_observed!(observed) when is_map(observed) do
    expected = %{
      "elixir" => "1.20.2",
      "otp_release" => "29",
      "hex" => @hex_version,
      "rebar3" => @rebar_version,
      "os" => "Linux"
    }

    errors =
      Enum.flat_map(expected, fn {field, value} ->
        if observed[field] == value,
          do: [],
          else: ["#{field}=#{inspect(observed[field])}, expected #{inspect(value)}"]
      end)

    errors =
      if observed["otp_version"] in [nil, ""] do
        errors ++ ["otp_version was not reported"]
      else
        errors
      end

    errors =
      if observed["arch"] in [nil, ""] do
        errors ++ ["arch was not reported"]
      else
        errors
      end

    if errors != [], do: Mix.raise("compatibility tuple mismatch: " <> Enum.join(errors, "; "))
    :ok
  end

  defp container_script do
    """
    set -eu
    mkdir -p /compat/home /compat/mix /compat/hex /compat/rebar-cache /compat/deps /compat/_build /compat/source
    tar --null --verbatim-files-from --no-recursion -C /source -cf /compat/source.tar -T /compat/source-files.zlist
    tar -C /compat/source -xf /compat/source.tar
    ln -s /compat/deps /compat/source/deps
    ln -s /compat/_build /compat/source/_build
    cd /compat/source
    mix local.hex #{@hex_version} --force
    mix local.rebar rebar3 #{@rebar_url} --sha512 #{@rebar_sha512} --force
    mix deps.get --only test
    mix compile --force --warnings-as-errors
    ELIXIR_VERSION=$(elixir -e 'IO.write(System.version())')
    OTP_RELEASE=$(elixir -e 'IO.write(System.otp_release())')
    OTP_VERSION=$(elixir -e 'release = System.otp_release(); path = Path.join([:code.root_dir(), "releases", release, "OTP_VERSION"]); IO.write(File.read!(path) |> String.trim() |> String.trim_leading("OTP-"))')
    HEX_VERSION=$(mix hex.info | awk '/^Hex:/ {value=$2} END {print value}')
    REBAR3_BIN=$(find /compat/mix/elixir -type f -name rebar3 -print -quit)
    test -n "$REBAR3_BIN"
    REBAR3_VERSION=$($REBAR3_BIN --version | awk 'NR == 1 {print $2}')
    printf 'ALLBERT_COMPAT_ELIXIR=%s\n' "$ELIXIR_VERSION"
    printf 'ALLBERT_COMPAT_OTP_RELEASE=%s\n' "$OTP_RELEASE"
    printf 'ALLBERT_COMPAT_OTP_VERSION=%s\n' "$OTP_VERSION"
    printf 'ALLBERT_COMPAT_HEX=%s\n' "$HEX_VERSION"
    printf 'ALLBERT_COMPAT_REBAR3=%s\n' "$REBAR3_VERSION"
    printf 'ALLBERT_COMPAT_OS=%s\n' "$(uname -s)"
    printf 'ALLBERT_COMPAT_ARCH=%s\n' "$(uname -m)"
    """
  end

  defp default_verify(root) do
    PreflightAttestation.verify!(root, Preflight.contract_digest())
  end

  defp validate_same_state!(before, after_run) do
    fields = ~w[head_sha worktree_content_digest mix_lock_digest gate_definition_digest]

    unless Enum.all?(fields, &(before[&1] == after_run[&1])) do
      Mix.raise("compatibility probe changed or outlived its preflight-attested repository state")
    end
  end

  defp work_root!(opts) do
    case Keyword.get(opts, :work_root) do
      nil -> {mktemp!(), true}
      root -> {Path.expand(root), false}
    end
  end

  defp prepare_work_root!(work_root) do
    File.mkdir_p!(Path.join(work_root, "deps"))
    File.mkdir_p!(Path.join(work_root, "_build"))
  end

  defp write_source_manifest!(root, work_root) do
    case System.cmd(
           "git",
           ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {paths, 0} when paths != "" ->
        File.write!(Path.join(work_root, "source-files.zlist"), paths, [:binary])

      {"", 0} ->
        Mix.raise("compatibility source manifest is empty")

      {output, status} ->
        Mix.raise("unable to enumerate compatibility source (#{status}): #{output}")
    end
  end

  defp mktemp! do
    template = Path.join(System.tmp_dir!(), "allbert-v132-compat.XXXXXX")

    case System.cmd("mktemp", ["-d", template], stderr_to_stdout: true) do
      {path, 0} ->
        String.trim(path)

      {output, status} ->
        Mix.raise("unable to create compatibility work root (#{status}): #{output}")
    end
  end

  defp remove_owned_work_root!(work_root) do
    tmp = Path.expand(System.tmp_dir!())
    work_root = Path.expand(work_root)

    unless String.starts_with?(work_root, tmp <> "/allbert-v132-compat.") do
      Mix.raise("refusing to remove unexpected compatibility work root: #{work_root}")
    end

    File.rm_rf!(work_root)
  end

  defp host_uid_gid! do
    {integer_command!("id", ["-u"]), integer_command!("id", ["-g"])}
  end

  defp integer_command!(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {value, 0} ->
        value |> String.trim() |> String.to_integer()

      {output, status} ->
        Mix.raise("#{executable} #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp run_command(executable, args, opts) do
    System.cmd(
      executable,
      args,
      Keyword.merge(opts,
        into: OutputTail.new(limit: @tail_limit, stream?: true)
      )
    )
  end

  defp canonical_root!(root) do
    case System.cmd("pwd", ["-P"], cd: Path.expand(root), stderr_to_stdout: true) do
      {path, 0} -> String.trim(path)
      {output, status} -> Mix.raise("unable to resolve repository root (#{status}): #{output}")
    end
  end

  defp path(root, opts) do
    Keyword.get(opts, :path) ||
      Application.get_env(:allbert_assist, :compatibility_attestation_path) ||
      Path.join(root, @relative_path)
  end

  defp invalidate!(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "remove", path: path
    end
  end

  defp write_atomic!(path, artifact) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(temporary, Jason.encode!(artifact, pretty: true) <> "\n", [:binary])
    File.rename!(temporary, path)
  end

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
