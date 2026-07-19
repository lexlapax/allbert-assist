defmodule AllbertAssist.DevGates.PhaseRunner do
  @moduledoc """
  Runs named development-gate phases with timing and diagnostic evidence.

  This module is development tooling only. It does not grant runtime authority
  and does not participate in Security Central decisions.
  """

  alias AllbertAssist.DevGates.OutputTail
  alias AllbertAssist.DevGates.TestMetrics

  @default_tail_limit 12_000

  def run_gate(gate, phases, opts \\ []) when is_binary(gate) and is_list(phases) do
    started_at = now()
    artifact_basename = artifact_basename(gate, started_at)

    evidence_root = Keyword.get(opts, :evidence_root_resolved) || evidence_root(phases, opts)

    opts =
      opts
      |> Keyword.put_new(:evidence_root_resolved, evidence_root)
      |> Keyword.put_new(:artifact_root, Path.join(evidence_root, artifact_basename))
      |> Keyword.put_new(:artifact_basename, artifact_basename)

    emit(opts, "==> #{gate} gate started")

    {status, phase_results} = run_phases(gate, phases, opts)
    finished_at = now()

    result =
      %{
        schema_version: 1,
        gate: gate,
        started_at: started_at,
        finished_at: finished_at,
        duration_ms: duration_ms(started_at, finished_at),
        status: Atom.to_string(status),
        phases: phase_results
      }
      |> maybe_put_artifact_root(opts)

    result =
      if Keyword.get(opts, :evidence?, false) do
        Map.put(result, :evidence_path, write_evidence!(result, phases, opts))
      else
        result
      end

    print_summary(result, opts)

    case status do
      :passed -> {:ok, result}
      :failed -> {:error, result}
    end
  end

  def run_gate!(gate, phases, opts \\ []) do
    case run_gate(gate, phases, opts) do
      {:ok, result} ->
        result

      {:error, %{phases: phases}} ->
        failed = Enum.find(phases, &(&1.status == "failed"))

        message =
          "#{gate} gate failed in phase #{failed.id} with status #{failed.exit_status}"

        case Map.get(failed, :redacted_output_log_path) do
          nil -> Mix.raise(message)
          path -> Mix.raise("#{message}; full redacted log: #{path}")
        end
    end
  end

  def run_system_cmd(%{executable: executable, args: args, cwd: cwd, env: env} = phase) do
    tail_limit = Map.get(phase, :tail_limit, @default_tail_limit)
    stream? = Map.get(phase, :stream?, true)

    System.cmd(executable, args,
      cd: cwd,
      env: env,
      stderr_to_stdout: true,
      into: OutputTail.new(limit: tail_limit, stream?: stream?)
    )
  end

  def redact(text) when is_binary(text) do
    text
    |> String.replace(~r/(api[_-]?key|token|secret|password)=([^\s]+)/i, "\\1=[REDACTED]")
    |> String.replace(~r/(sk-[A-Za-z0-9_-]{12,})/, "sk-[REDACTED]")
    |> String.replace(~r/(ghp_[A-Za-z0-9_]{12,})/, "ghp_[REDACTED]")
  end

  def summarize_output(output) when is_binary(output) do
    summary =
      Regex.scan(~r/(\d+) tests?, (\d+) failures?(?:, (\d+) skipped)?/, output)
      |> List.last()

    case summary do
      [_match, tests, failures] ->
        %{tests: String.to_integer(tests), failures: String.to_integer(failures), skipped: 0}

      [_match, tests, failures, skipped] ->
        %{
          tests: String.to_integer(tests),
          failures: String.to_integer(failures),
          skipped: String.to_integer(skipped)
        }

      _other ->
        %{}
    end
  end

  defp run_phases(gate, phases, opts) do
    Enum.reduce_while(phases, {:passed, []}, fn phase, {_status, results} ->
      result = run_phase(gate, normalize_phase(phase), opts)
      results = results ++ [result]

      if result.status == "passed" do
        {:cont, {:passed, results}}
      else
        {:halt, {:failed, results}}
      end
    end)
  end

  defp run_phase(gate, phase, opts) do
    started_at = now()
    emit(opts, "==> #{gate} #{phase.id} started")
    emit(opts, "cwd=#{phase.cwd} command=#{redacted_command(phase)}")

    {output, exit_status} = command_runner(opts).(phase)

    finished_at = now()
    output = redact(to_string(output || ""))
    status = if exit_status == 0, do: "passed", else: "failed"
    artifacts = persist_phase_artifacts(gate, phase, status, output, opts)
    test_seeds = extract_test_seeds(output)

    emit(
      opts,
      "==> #{gate} #{phase.id} finished in #{duration_ms(started_at, finished_at)}ms status=#{status}"
    )

    # M8.10 provenance: `:command` is the operator-visible gate invocation
    # threaded by the caller (nil when run outside `mix allbert.test`);
    # `cwd` is the phase's actual working directory.
    TestMetrics.record(%{
      gate: gate,
      command: Keyword.get(opts, :command),
      cwd: relative_cwd(phase.cwd),
      phase_or_step: phase.id,
      status: status,
      wall_ms: duration_ms(started_at, finished_at),
      output: output
    })

    %{
      id: phase.id,
      cwd: relative_cwd(phase.cwd),
      args: [phase.executable | phase.args],
      started_at: started_at,
      finished_at: finished_at,
      duration_ms: duration_ms(started_at, finished_at),
      status: status,
      exit_status: exit_status,
      summary: summarize_output(output),
      redacted_output_tail:
        OutputTail.trim(output, Map.get(phase, :tail_limit, @default_tail_limit))
    }
    |> maybe_put(:test_seeds, test_seeds, &(&1 != []))
    |> Map.merge(artifacts)
  end

  defp normalize_phase(phase) do
    phase
    |> Map.new()
    |> Map.put_new(:args, [])
    |> Map.put_new(:env, [])
    |> Map.put_new(:tail_limit, @default_tail_limit)
    |> Map.put_new(:stream?, true)
  end

  defp command_runner(opts) do
    Keyword.get(opts, :command_runner) ||
      Application.get_env(:allbert_assist, :gate_command_runner) ||
      (&run_system_cmd/1)
  end

  defp write_evidence!(result, phases, opts) do
    evidence_root = Keyword.get(opts, :evidence_root_resolved) || evidence_root(phases, opts)
    File.mkdir_p!(evidence_root)

    path =
      Path.join(
        evidence_root,
        "#{Keyword.get(opts, :artifact_basename, artifact_basename(result.gate, result.started_at))}.json"
      )

    File.write!(path, Jason.encode!(result, pretty: true))
    emit(opts, "evidence=#{path}")
    path
  end

  defp evidence_root(_phases, opts) do
    cond do
      Keyword.get(opts, :evidence_root) ->
        Keyword.fetch!(opts, :evidence_root)

      Application.get_env(:allbert_assist, :gate_evidence_root) ->
        Application.fetch_env!(:allbert_assist, :gate_evidence_root)

      home = first_home(opts) ->
        Path.join(home, "release_evidence/gates")

      true ->
        Path.join(System.tmp_dir!(), "allbert_release_evidence/gates")
    end
  end

  defp first_home(opts) do
    opts
    |> Keyword.get(:env, [])
    |> Enum.find_value(fn
      {"ALLBERT_HOME", value} -> value
      {"ALLBERT_HOME_DIR", value} -> value
      _other -> nil
    end)
  end

  defp maybe_put_artifact_root(result, opts) do
    if Keyword.get(opts, :evidence?, false) or
         Enum.any?(result.phases, &Map.has_key?(&1, :redacted_output_log_path)) do
      Map.put(result, :artifact_root, Keyword.fetch!(opts, :artifact_root))
    else
      result
    end
  end

  defp persist_phase_artifacts(gate, phase, status, output, opts) do
    if persist_phase_artifacts?(status, opts) do
      artifact_root = Keyword.fetch!(opts, :artifact_root)
      File.mkdir_p!(artifact_root)

      output_log_path =
        Path.join(artifact_root, "#{safe_component(gate)}-#{safe_component(phase.id)}.log")

      File.write!(output_log_path, output)

      %{
        redacted_output_log_path: output_log_path
      }
      |> maybe_put(
        :failure_manifest_paths,
        failure_manifest_paths(phase, status, artifact_root),
        &(&1 != [])
      )
    else
      %{}
    end
  end

  defp persist_phase_artifacts?(status, opts) do
    Keyword.get(opts, :evidence?, false) or status == "failed"
  end

  defp failure_manifest_paths(phase, "failed", artifact_root) do
    if mix_test_phase?(phase) do
      copy_failure_manifests(phase, artifact_root)
    else
      []
    end
  end

  defp failure_manifest_paths(_phase, _status, _artifact_root), do: []

  defp mix_test_phase?(%{executable: executable, args: args}) do
    executable == "mix" and Enum.any?(args, &String.contains?(&1, "test"))
  end

  defp copy_failure_manifests(phase, artifact_root) do
    destination_dir = Path.join(artifact_root, "failure-manifests")

    phase
    |> failure_manifest_candidates()
    |> Enum.uniq()
    |> Enum.filter(&regular_file?/1)
    |> Enum.map(fn source ->
      File.mkdir_p!(destination_dir)
      destination = Path.join(destination_dir, failure_manifest_name(source))
      File.cp!(source, destination)
      %{source_path: source, artifact_path: destination, bytes: File.stat!(destination).size}
    end)
  end

  defp failure_manifest_candidates(%{cwd: cwd}) do
    root = File.cwd!()
    app_name = Path.basename(cwd)

    candidates = [
      Path.join(cwd, "_build/test/.mix/.mix_test_failures"),
      Path.join(cwd, ".mix/.mix_test_failures"),
      Path.join(root, "_build/test/.mix/.mix_test_failures"),
      Path.join(root, "_build/test/lib/#{app_name}/.mix/.mix_test_failures")
    ]

    if cwd == root do
      candidates ++ Path.wildcard(Path.join(root, "_build/test/lib/*/.mix/.mix_test_failures"))
    else
      candidates
    end
  end

  defp failure_manifest_name(source) do
    source
    |> Path.relative_to(File.cwd!())
    |> safe_component()
    |> Kernel.<>(".bin")
  end

  defp regular_file?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 -> true
      _other -> false
    end
  end

  defp extract_test_seeds(output) do
    ~r/Running ExUnit with seed:\s+(\d+)/
    |> Regex.scan(output)
    |> Enum.map(fn [_match, seed] -> String.to_integer(seed) end)
  end

  defp artifact_basename(gate, started_at) do
    "#{safe_component(gate)}-#{safe_component(started_at)}"
  end

  defp maybe_put(map, key, value, predicate) when is_function(predicate, 1) do
    if predicate.(value), do: Map.put(map, key, value), else: map
  end

  defp print_summary(result, opts) do
    emit(opts, "==> #{result.gate} gate #{result.status} in #{result.duration_ms}ms")

    Enum.each(result.phases, fn phase ->
      emit(opts, "#{phase.id}: #{phase.status} #{phase.duration_ms}ms")
    end)
  end

  defp redacted_command(phase) do
    [phase.executable | phase.args]
    |> Enum.map_join(" ", &redact/1)
  end

  defp safe_component(value) do
    value
    |> to_string()
    |> String.replace(~r/[^0-9A-Za-z_.-]+/, "_")
  end

  defp relative_cwd(cwd) do
    root = File.cwd!()

    if String.starts_with?(cwd, root) do
      Path.relative_to(cwd, root)
    else
      cwd
    end
  end

  defp emit(opts, message) do
    case Keyword.get(opts, :emit) do
      nil -> Mix.shell().info(message)
      emit -> emit.(message)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp duration_ms(started_at, finished_at) do
    {:ok, started, _offset} = DateTime.from_iso8601(started_at)
    {:ok, finished, _offset} = DateTime.from_iso8601(finished_at)
    DateTime.diff(finished, started, :millisecond)
  end
end
