defmodule AllbertAssist.DevGates.PhaseRunner do
  @moduledoc """
  Runs named development-gate phases with timing and diagnostic evidence.

  This module is development tooling only. It does not grant runtime authority
  and does not participate in Security Central decisions.
  """

  alias AllbertAssist.DevGates.OutputTail

  @default_tail_limit 12_000

  def run_gate(gate, phases, opts \\ []) when is_binary(gate) and is_list(phases) do
    started_at = now()
    emit(opts, "==> #{gate} gate started")

    {status, phase_results} = run_phases(gate, phases, opts)
    finished_at = now()

    result = %{
      schema_version: 1,
      gate: gate,
      started_at: started_at,
      finished_at: finished_at,
      duration_ms: duration_ms(started_at, finished_at),
      status: Atom.to_string(status),
      phases: phase_results
    }

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
        Mix.raise("#{gate} gate failed in phase #{failed.id} with status #{failed.exit_status}")
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

    emit(
      opts,
      "==> #{gate} #{phase.id} finished in #{duration_ms(started_at, finished_at)}ms status=#{status}"
    )

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
    evidence_root = evidence_root(phases, opts)
    File.mkdir_p!(evidence_root)

    path =
      Path.join(
        evidence_root,
        "#{result.gate}-#{String.replace(result.started_at, ~r/[^0-9A-Za-z_.-]+/, "_")}.json"
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
