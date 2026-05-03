defmodule AllbertAssist.Execution.SkillScriptRunner do
  @moduledoc """
  Bounded host-process runner for already-authorized skill script specs.

  The runner does not make policy decisions. Callers must pass a
  `SkillScriptSpec` whose policy decision is `:allowed`.
  """

  alias AllbertAssist.Execution.OutputBuffer
  alias AllbertAssist.Execution.SkillScriptSpec

  @type result :: %{
          status: :completed | :failed | :timed_out | :denied,
          exit_status: non_neg_integer() | nil,
          timed_out?: boolean(),
          truncated?: boolean(),
          stdout: binary(),
          stderr: binary(),
          stderr_merged?: boolean(),
          output_bytes: non_neg_integer(),
          diagnostics: [map()],
          script: map()
        }

  @spec run(SkillScriptSpec.t()) :: {:ok, result()}
  def run(%SkillScriptSpec{policy_decision: :allowed} = spec) do
    with :ok <- ensure_cwd(spec) do
      spec
      |> run_task()
      |> await_result(spec)
    else
      {:error, reason} -> {:ok, denied_result(spec, reason)}
    end
  end

  def run(%SkillScriptSpec{} = spec) do
    {:ok, denied_result(spec, spec.denial_reason || :policy_not_allowed)}
  end

  defp ensure_cwd(%SkillScriptSpec{cwd_source: :internal, resolved_cwd: cwd}) do
    case File.mkdir_p(cwd) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cwd_create_failed, reason}}
    end
  end

  defp ensure_cwd(%SkillScriptSpec{resolved_cwd: cwd}) do
    if File.dir?(cwd), do: :ok, else: {:error, {:cwd_missing, cwd}}
  end

  defp run_task(spec) do
    Task.async(fn -> run_system_cmd(spec) end)
  end

  defp await_result(task, spec) do
    case Task.yield(task, spec.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:ok, timeout_result(spec)}
    end
  end

  defp run_system_cmd(spec) do
    output_buffer = OutputBuffer.new(spec.max_output_bytes)

    {buffer, exit_status} =
      System.cmd(spec.resolved_executable, spec.args,
        cd: spec.resolved_cwd,
        env: runner_env(spec.env),
        stderr_to_stdout: true,
        into: output_buffer
      )

    output = OutputBuffer.output(buffer)

    %{
      status: exit_status_to_status(exit_status),
      exit_status: exit_status,
      timed_out?: false,
      truncated?: buffer.truncated?,
      stdout: output,
      stderr: "",
      stderr_merged?: true,
      output_bytes: byte_size(output),
      diagnostics: diagnostics(buffer),
      script: SkillScriptSpec.summary(spec)
    }
  rescue
    exception ->
      denied_result(spec, {exception.__struct__, Exception.message(exception)})
  end

  defp runner_env(env) do
    env = Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
    allowed = MapSet.new(Map.keys(env))

    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.map(&{&1, nil})

    cleared ++ Enum.to_list(env)
  end

  defp timeout_result(spec) do
    %{
      status: :timed_out,
      exit_status: nil,
      timed_out?: true,
      truncated?: false,
      stdout: "",
      stderr: "",
      stderr_merged?: true,
      output_bytes: 0,
      diagnostics: [%{reason: :timeout, timeout_ms: spec.timeout_ms}],
      script: SkillScriptSpec.summary(spec)
    }
  end

  defp denied_result(spec, reason) do
    %{
      status: :denied,
      exit_status: nil,
      timed_out?: false,
      truncated?: false,
      stdout: "",
      stderr: "",
      stderr_merged?: true,
      output_bytes: 0,
      diagnostics: [%{reason: reason}],
      script: SkillScriptSpec.summary(spec)
    }
  end

  defp diagnostics(%OutputBuffer{truncated?: true, limit: limit}) do
    [%{reason: :output_truncated, max_output_bytes: limit}]
  end

  defp diagnostics(_buffer), do: []

  defp exit_status_to_status(0), do: :completed
  defp exit_status_to_status(_status), do: :failed
end
