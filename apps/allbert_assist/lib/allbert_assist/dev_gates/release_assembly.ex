defmodule AllbertAssist.DevGates.ReleaseAssembly do
  @moduledoc """
  Builds and verifies a bounded release assembly checkpoint from a disposable Home.

  This is release tooling, not runtime authority. The verifier owns the Pack
  projection semantics and reports one machine-readable result line; this
  wrapper owns isolation, command lifecycle, cleanup, and test metrics.
  """

  alias AllbertAssist.DevGates.PhaseRunner
  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.Licenses
  alias AllbertAssist.Pack.ReleaseAssemblyVerifier

  # v1.4 M13.4. `v14-m13` was reachable from the verifier and from nowhere
  # else: M13.3 built the seventeen-application release closure and proved it by
  # hand, but this wrapper -- the only `mix allbert.test release-assembly` entry
  # point -- declared two checkpoints and hard-coded the marker's expected keys
  # to two or three applications, so a fifteen-key marker was rejected even if
  # the name had been accepted. A closure nothing re-runs is a closure that
  # rots, which is the shape R3's own lesson warns about.
  @checkpoints ~w[v14-m1a1 v14-m1a3 v14-m13]
  @marker "ALLBERT_RELEASE_ASSEMBLY_V1="
  @hash ~r/\A[0-9a-f]{64}\z/
  @verifier_eval ~S|AllbertAssist.Pack.ReleaseAssemblyVerifier.verify!(System.fetch_env!("ALLBERT_RELEASE_ROOT"), System.fetch_env!("ALLBERT_RELEASE_ASSEMBLY_CHECKPOINT"))|

  @doc """
  Runs a supported checkpoint and returns its normalized digest result.

  Options are intentionally injectable so this wrapper can be tested without
  assembling a release: `:command_runner`, `:temp_root_factory`,
  `:temp_root_cleanup`, `:verifier_args`, `:metrics_store`, and `:emit`.
  """
  def run!(checkpoint, opts \\ [])

  def run!(checkpoint, opts) when is_binary(checkpoint) do
    validate_checkpoint!(checkpoint)

    root = opts |> Keyword.get(:root, TestMetrics.repo_root()) |> Path.expand()
    temp_root = allocate_temp_root!(opts)
    home = Path.join(temp_root, "home")
    File.mkdir_p!(home)

    release_root = release_root(opts, root)
    env = owned_env(home, temp_root, release_root, checkpoint)
    runner = command_runner(opts)
    emit = Keyword.get(opts, :emit) || fn message -> Mix.shell().info(message) end
    started = System.monotonic_time(:millisecond)

    metrics_opts = [
      checkpoint: checkpoint,
      store: Keyword.get(opts, :metrics_store),
      command: Keyword.get(opts, :command, "release-assembly --checkpoint #{checkpoint}")
    ]

    try do
      release_boundary = prepare_release_root!(release_root, root, temp_root)

      build = %{
        id: "build_release",
        cwd: root,
        executable: "mix",
        args: ["release", "allbert", "--overwrite"],
        env: env
      }

      {_build_output, 0} = run_command!(runner, build, temp_root)

      verify = %{
        id: "verify_projection",
        cwd: root,
        executable: verifier_executable!(release_root, release_boundary),
        args: verifier_args(opts),
        env: env
      }

      {verify_output, 0} = run_command!(runner, verify, temp_root)
      result = parse_result!(verify_output, checkpoint)

      if checkpoint == "v14-m1a3" do
        run_runtime_free_launcher_checks!(runner, verify.executable, root, env, home, temp_root)
      end

      cleanup_temp_root!(temp_root, opts)
      wall_ms = System.monotonic_time(:millisecond) - started

      record_metrics(
        result,
        Keyword.merge(metrics_opts, wall_ms: wall_ms, status: "passed")
      )

      emit.("release-assembly #{checkpoint} PASS")

      result
      |> Map.put(:status, "passed")
      |> Map.put(:wall_ms, wall_ms)
    rescue
      error ->
        wall_ms = System.monotonic_time(:millisecond) - started

        record_metrics(
          empty_result(checkpoint),
          Keyword.merge(metrics_opts, wall_ms: wall_ms, status: "failed")
        )

        emit.("release-assembly #{checkpoint} FAIL; retained temp root: #{temp_root}")
        reraise(error, __STACKTRACE__)
    end
  end

  def run!(checkpoint, _opts),
    do: Mix.raise("invalid release-assembly checkpoint: #{inspect(checkpoint)}")

  defp validate_checkpoint!(checkpoint) do
    unless checkpoint in @checkpoints do
      Mix.raise(
        "unknown release-assembly checkpoint #{checkpoint}; expected one of #{Enum.join(@checkpoints, ", ")}"
      )
    end
  end

  defp allocate_temp_root!(opts) do
    factory =
      Keyword.get(opts, :temp_root_factory) ||
        Application.get_env(:allbert_assist, :release_assembly_temp_root_factory) ||
        (&mktemp_root!/0)

    path = factory.() |> Path.expand()
    system_tmp = System.tmp_dir!() |> Path.expand()

    unless File.dir?(path) and inside?(path, system_tmp) do
      Mix.raise("release-assembly temp root must be an existing directory under #{system_tmp}")
    end

    path
  end

  defp release_root(opts, root) do
    opts
    |> Keyword.get(:release_root)
    |> Kernel.||(Application.get_env(:allbert_assist, :release_assembly_release_root))
    |> Kernel.||(default_release_root(root))
    |> Path.expand()
  end

  defp default_release_root(root), do: Path.join(root, "_build/prod/rel/allbert") |> Path.expand()

  defp prepare_release_root!(release_root, root, temp_root) do
    default_root = default_release_root(root)

    boundary =
      cond do
        release_root == default_root ->
          root

        inside?(release_root, temp_root) ->
          temp_root

        true ->
          Mix.raise(
            "release-assembly release root must be the generated default #{default_root} " <>
              "or a strict descendant of #{temp_root}"
          )
      end

    reject_symlink_ancestry!(release_root, boundary)

    case File.lstat(release_root) do
      {:ok, %File.Stat{type: :directory}} ->
        File.rm_rf!(release_root)

      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        Mix.raise(
          "release-assembly release root must be a directory, got #{type}: #{release_root}"
        )

      {:error, reason} ->
        Mix.raise(
          "release-assembly could not inspect release root #{release_root}: #{:file.format_error(reason)}"
        )
    end

    boundary
  end

  defp reject_symlink_ancestry!(path, boundary) do
    _resolved_path =
      path
      |> Path.relative_to(boundary)
      |> Path.split()
      |> Enum.reduce_while(Path.expand(boundary), fn segment, parent ->
        candidate = Path.join(parent, segment)

        case File.lstat(candidate) do
          {:ok, %File.Stat{type: :symlink}} ->
            Mix.raise("release-assembly release root crosses a symlink: #{candidate}")

          {:ok, _stat} ->
            {:cont, candidate}

          {:error, :enoent} ->
            {:halt, candidate}

          {:error, reason} ->
            Mix.raise(
              "release-assembly could not inspect release root path #{candidate}: #{:file.format_error(reason)}"
            )
        end
      end)

    :ok
  end

  defp mktemp_root! do
    template = Path.join(System.tmp_dir!(), "allbert-release-assembly.XXXXXX")

    case System.cmd("mktemp", ["-d", template], stderr_to_stdout: true) do
      {path, 0} ->
        String.trim(path)

      {output, status} ->
        Mix.raise("mktemp -d failed with status #{status}: #{String.trim(output)}")
    end
  end

  defp inside?(path, root) do
    relative = Path.relative_to(path, root)

    Path.type(relative) == :relative and relative not in ["", "."] and
      not String.starts_with?(relative, "..")
  end

  defp command_runner(opts) do
    Keyword.get(opts, :command_runner) ||
      Application.get_env(:allbert_assist, :release_assembly_command_runner, &run_system_cmd/1)
  end

  defp run_system_cmd(command) do
    System.cmd(command.executable, command.args,
      cd: command.cwd,
      env: command.env,
      stderr_to_stdout: true
    )
  end

  defp run_command!(runner, command, temp_root) do
    case runner.(command) do
      {output, status} when is_binary(output) and is_integer(status) ->
        log_path = persist_command_log!(command.id, output, temp_root)

        if status == 0 do
          {output, 0}
        else
          Mix.raise(
            "release-assembly #{command.id} failed with status #{status}; " <>
              "retained temp root: #{temp_root}; redacted log: #{log_path}"
          )
        end

      _other ->
        Mix.raise(
          "release-assembly #{command.id} runner returned an invalid result; retained temp root: #{temp_root}"
        )
    end
  end

  defp persist_command_log!(id, output, temp_root) do
    path = Path.join(temp_root, "#{id}.log")
    File.write!(path, PhaseRunner.redact(output))
    path
  end

  defp verifier_args(opts) do
    Keyword.get(opts, :verifier_args) ||
      Application.get_env(
        :allbert_assist,
        :release_assembly_verifier_args,
        ["eval", @verifier_eval]
      )
  end

  defp verifier_executable!(release_root, release_boundary) do
    path = Path.join([release_root, "bin", "allbert"])
    reject_symlink_ancestry!(path, release_boundary)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) == 0 do
          Mix.raise("release-assembly packaged verifier is not executable: #{path}")
        end

        path

      {:ok, %File.Stat{type: type}} ->
        Mix.raise("release-assembly verifier is #{type}: #{path}")

      {:error, reason} ->
        Mix.raise(
          "release-assembly could not inspect packaged verifier #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  defp run_runtime_free_launcher_checks!(runner, executable, root, env, home, temp_root) do
    Enum.each(["--help", "--version"], fn argument ->
      command = %{
        id: "verify_#{String.trim_leading(argument, "--")}",
        cwd: root,
        executable: executable,
        args: [argument],
        env: env
      }

      {_output, 0} = run_command!(runner, command, temp_root)
    end)

    case File.ls(home) do
      {:ok, []} ->
        :ok

      {:ok, entries} ->
        Mix.raise(
          "release-assembly runtime-free launcher created Home state: #{inspect(Enum.sort(entries))}"
        )

      {:error, reason} ->
        Mix.raise(
          "release-assembly could not inspect disposable Home: #{:file.format_error(reason)}"
        )
    end
  end

  defp cleanup_temp_root!(temp_root, opts) do
    cleanup = Keyword.get(opts, :temp_root_cleanup, &File.rm_rf!/1)
    cleanup.(temp_root)

    case File.lstat(temp_root) do
      {:error, :enoent} -> :ok
      _other -> Mix.raise("release-assembly failed to remove temp root: #{temp_root}")
    end
  end

  defp parse_result!(output, checkpoint) do
    payloads =
      output
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.filter(&String.starts_with?(&1, @marker))
      |> Enum.map(&String.replace_prefix(&1, @marker, ""))

    payload =
      case payloads do
        [payload] -> payload
        [] -> Mix.raise("release-assembly verifier omitted #{@marker} result")
        _multiple -> Mix.raise("release-assembly verifier emitted duplicate #{@marker} results")
      end

    decoded = Jason.decode!(payload)
    canonical_payload = decoded |> Licenses.canonical_json() |> String.trim_trailing("\n")

    unless payload == canonical_payload do
      Mix.raise("release-assembly verifier result must use canonical JSON encoding")
    end

    validate_result!(decoded, checkpoint)

    apps = Map.fetch!(decoded, "app_sha256")

    %{
      checkpoint: checkpoint,
      rel_sha256: Map.fetch!(decoded, "rel_sha256"),
      kernel_app_sha256: Map.fetch!(apps, "allbert_kernel"),
      residual_app_sha256: Map.fetch!(apps, "allbert_assist"),
      composition_app_sha256: Map.get(apps, "allbert_composition"),
      pack_projection_sha256: Map.fetch!(decoded, "pack_projection_sha256"),
      overlay_sha256: Map.get(decoded, "overlay_sha256"),
      entrypoint_sha256: Map.get(decoded, "entrypoint_sha256")
    }
  rescue
    error in Jason.DecodeError ->
      Mix.raise("release-assembly verifier result is not valid JSON: #{Exception.message(error)}")
  end

  defp validate_result!(result, checkpoint) when is_map(result) do
    expected_result_keys =
      if checkpoint == "v14-m1a3" do
        ~w[app_sha256 checkpoint entrypoint_sha256 overlay_sha256 pack_projection_sha256 rel_sha256 schema_version status]
      else
        ~w[app_sha256 checkpoint pack_projection_sha256 rel_sha256 schema_version status]
      end

    unless Enum.sort(Map.keys(result)) == expected_result_keys do
      Mix.raise(
        "release-assembly verifier result keys must be exactly " <>
          Enum.join(expected_result_keys, ", ")
      )
    end

    require_equal!(result, "schema_version", 1)
    require_equal!(result, "status", "PASS")
    require_equal!(result, "checkpoint", checkpoint)
    require_hash!(result, "rel_sha256")
    require_hash!(result, "pack_projection_sha256")

    apps = Map.get(result, "app_sha256")

    unless is_map(apps) do
      Mix.raise("release-assembly verifier app_sha256 must be an object")
    end

    # Ask the verifier which applications its closure expects rather than
    # keeping a second copy here; a duplicated list is what M13.3 deleted.
    expected_apps =
      checkpoint
      |> ReleaseAssemblyVerifier.marker_applications()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    unless Enum.sort(Map.keys(apps)) == expected_apps do
      Mix.raise(
        "release-assembly verifier app_sha256 keys must be exactly #{Enum.join(expected_apps, ", ")}"
      )
    end

    Enum.each(expected_apps, &require_hash!(apps, &1))

    if checkpoint == "v14-m1a3" do
      require_hash!(result, "overlay_sha256")
      require_hash!(result, "entrypoint_sha256")
    end
  end

  defp validate_result!(_result, _checkpoint),
    do: Mix.raise("release-assembly verifier result must be a JSON object")

  defp require_equal!(map, key, expected) do
    unless Map.get(map, key) === expected do
      Mix.raise("release-assembly verifier #{key} must equal #{inspect(expected)}")
    end
  end

  defp require_hash!(map, key) do
    value = Map.get(map, key)

    unless is_binary(value) and Regex.match?(@hash, value) do
      Mix.raise("release-assembly verifier #{key} must be a lowercase SHA-256")
    end
  end

  defp record_metrics(result, opts) do
    TestMetrics.record(%{
      store: Keyword.get(opts, :store),
      gate: "release-assembly",
      command: Keyword.fetch!(opts, :command),
      phase_or_step: Keyword.fetch!(opts, :checkpoint),
      checkpoint: Keyword.fetch!(opts, :checkpoint),
      status: Keyword.fetch!(opts, :status),
      wall_ms: Keyword.fetch!(opts, :wall_ms),
      rel_sha256: result.rel_sha256,
      kernel_app_sha256: result.kernel_app_sha256,
      residual_app_sha256: result.residual_app_sha256,
      composition_app_sha256: result.composition_app_sha256,
      pack_projection_sha256: result.pack_projection_sha256,
      overlay_sha256: result.overlay_sha256,
      entrypoint_sha256: result.entrypoint_sha256
    })
  end

  defp empty_result(checkpoint) do
    %{
      checkpoint: checkpoint,
      rel_sha256: nil,
      kernel_app_sha256: nil,
      residual_app_sha256: nil,
      composition_app_sha256: nil,
      pack_projection_sha256: nil,
      overlay_sha256: nil,
      entrypoint_sha256: nil
    }
  end

  defp owned_env(home, temp_root, release_root, checkpoint) do
    [
      {"MIX_ENV", "prod"},
      {"ALLBERT_HOME", home},
      {"ALLBERT_HOME_DIR", home},
      {"ALLBERT_SETTINGS_ROOT", nil},
      {"ALLBERT_MEMORY_ROOT", nil},
      {"ALLBERT_ARTIFACTS_ROOT", nil},
      {"ALLBERT_PLUGINS_ROOT", nil},
      {"ALLBERT_VAULT_BACKEND", nil},
      {"DATABASE_PATH", Path.join([home, "db", "allbert.db"])},
      {"XDG_CONFIG_HOME", Path.join([home, "xdg", "config"])},
      {"XDG_DATA_HOME", Path.join([home, "xdg", "data"])},
      {"XDG_STATE_HOME", Path.join([home, "xdg", "state"])},
      {"XDG_CACHE_HOME", Path.join([home, "xdg", "cache"])},
      {"XDG_RUNTIME_DIR", Path.join([home, "xdg", "runtime"])},
      {"ALLBERT_RELEASE_ASSEMBLY_ROOT", temp_root},
      {"ALLBERT_RELEASE_ROOT", release_root},
      {"ALLBERT_RELEASE_ASSEMBLY_CHECKPOINT", checkpoint}
    ]
  end
end
