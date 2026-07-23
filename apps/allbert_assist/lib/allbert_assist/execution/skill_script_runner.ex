defmodule AllbertAssist.Execution.SkillScriptRunner do
  @moduledoc """
  Bounded host-process runner for already-authorized skill script specs.

  The runner does not make policy decisions. Callers must pass a
  `SkillScriptSpec` whose policy decision is `:allowed`.
  """

  alias AllbertAssist.Execution.OutputBuffer
  alias AllbertAssist.Execution.ProcessOwner
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

  @spec run(SkillScriptSpec.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(spec, opts \\ [])

  def run(%SkillScriptSpec{policy_decision: :allowed} = spec, opts) do
    with :ok <- ensure_cwd(spec) do
      run_owned(spec, opts)
    else
      {:error, reason} -> {:ok, denied_result(spec, reason)}
    end
  end

  def run(%SkillScriptSpec{} = spec, _opts) do
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

  defp run_owned(spec, opts) do
    with {:ok, owned} <-
           ProcessOwner.run(spec.resolved_executable, spec.args,
             cd: spec.resolved_cwd,
             env: runner_env(spec.env),
             timeout_ms: spec.timeout_ms,
             max_output_bytes: spec.max_output_bytes,
             execution_id: Keyword.get(opts, :execution_id, Ecto.UUID.generate())
           ) do
      {:ok,
       %{
         status:
           if(owned.timed_out?, do: :timed_out, else: exit_status_to_status(owned.exit_status)),
         exit_status: owned.exit_status,
         timed_out?: owned.timed_out?,
         truncated?: owned.truncated?,
         stdout: owned.output,
         stderr: "",
         stderr_merged?: true,
         output_bytes: owned.output_bytes,
         diagnostics:
           if(owned.timed_out?,
             do: [%{reason: :timeout, timeout_ms: spec.timeout_ms}],
             else:
               diagnostics(%OutputBuffer{
                 limit: spec.max_output_bytes,
                 truncated?: owned.truncated?
               })
           ),
         script: SkillScriptSpec.summary(spec)
       }}
    end
  rescue
    exception ->
      {:ok, denied_result(spec, {exception.__struct__, Exception.message(exception)})}
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
