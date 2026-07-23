defmodule AllbertAssist.Execution.LocalRunner do
  @moduledoc """
  Level 1 local process runner for already-authorized command specs.

  The runner does not perform policy decisions. Callers must pass a
  `CommandSpec` whose policy decision is `:allowed`.
  """

  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.OutputBuffer
  alias AllbertAssist.Execution.ProcessOwner

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

  @spec run(CommandSpec.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(spec, opts \\ [])

  def run(%CommandSpec{policy_decision: :allowed} = spec, opts), do: run_owned(spec, opts)

  def run(%CommandSpec{} = spec, _opts) do
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

  defp run_owned(spec, opts) do
    command =
      spec.resolved_executable || System.find_executable(spec.executable) || spec.executable

    with {:ok, owned} <-
           ProcessOwner.run(command, spec.args,
             cd: spec.resolved_cwd,
             env: Enum.to_list(spec.env),
             timeout_ms: spec.timeout_ms,
             max_output_bytes: spec.max_output_bytes,
             execution_id: Keyword.get(opts, :execution_id, Ecto.UUID.generate())
           ) do
      buffer = %OutputBuffer{
        limit: spec.max_output_bytes,
        bytes: owned.output_bytes,
        chunks: [owned.output],
        truncated?: owned.truncated?
      }

      {:ok,
       %{
         status: if(owned.timed_out?, do: :timed_out, else: :completed),
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
             else: diagnostics(buffer)
           ),
         command: CommandSpec.summary(spec)
       }}
    end
  end

  defp diagnostics(%OutputBuffer{truncated?: true, limit: limit}) do
    [%{reason: :output_truncated, max_output_bytes: limit}]
  end

  defp diagnostics(_buffer), do: []
end
