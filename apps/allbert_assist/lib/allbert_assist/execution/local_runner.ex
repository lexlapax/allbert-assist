defmodule AllbertAssist.Execution.LocalRunner do
  @moduledoc """
  Level 1 local process runner for already-authorized command specs.

  The runner does not perform policy decisions. Callers must pass a
  `CommandSpec` whose policy decision is `:allowed`.
  """

  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.OutputBuffer

  @type result :: %{
          status: :completed | :timed_out | :denied,
          exit_status: non_neg_integer() | nil,
          timed_out?: boolean(),
          truncated?: boolean(),
          stdout: binary(),
          stderr: binary(),
          stderr_merged?: boolean(),
          output_bytes: non_neg_integer(),
          diagnostics: [map()],
          command: map()
        }

  @spec run(CommandSpec.t()) :: {:ok, result()}
  def run(%CommandSpec{policy_decision: :allowed} = spec) do
    spec
    |> run_task()
    |> await_result(spec)
  end

  def run(%CommandSpec{} = spec) do
    {:ok,
     %{
       status: :denied,
       exit_status: nil,
       timed_out?: false,
       truncated?: false,
       stdout: "",
       stderr: "",
       stderr_merged?: true,
       output_bytes: 0,
       diagnostics: [%{reason: spec.denial_reason || :policy_not_allowed}],
       command: CommandSpec.summary(spec)
     }}
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
    command = spec.resolved_executable || spec.executable
    output_buffer = OutputBuffer.new(spec.max_output_bytes)

    {buffer, exit_status} =
      System.cmd(command, spec.args,
        cd: spec.resolved_cwd,
        env: Enum.to_list(spec.env),
        stderr_to_stdout: true,
        into: output_buffer
      )

    output = OutputBuffer.output(buffer)

    %{
      status: :completed,
      exit_status: exit_status,
      timed_out?: false,
      truncated?: buffer.truncated?,
      stdout: output,
      stderr: "",
      stderr_merged?: true,
      output_bytes: byte_size(output),
      diagnostics: diagnostics(buffer),
      command: CommandSpec.summary(spec)
    }
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
      command: CommandSpec.summary(spec)
    }
  end

  defp diagnostics(%OutputBuffer{truncated?: true, limit: limit}) do
    [%{reason: :output_truncated, max_output_bytes: limit}]
  end

  defp diagnostics(_buffer), do: []
end
