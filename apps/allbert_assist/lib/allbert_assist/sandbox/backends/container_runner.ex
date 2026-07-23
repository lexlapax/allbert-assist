defmodule AllbertAssist.Sandbox.Backends.ContainerRunner do
  @moduledoc false

  alias AllbertAssist.Sandbox.Backends.Command
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Sandbox.ReportWriter

  @spec run(atom(), String.t(), [String.t()], Bundle.t(), CommandSpec.t()) ::
          {:ok, Report.t()} | {:error, term()}
  def run(backend_id, engine, argv, %Bundle{} = bundle, %CommandSpec{} = spec) do
    started_at = System.monotonic_time(:millisecond)

    with {:engine, {:ok, result}} <-
           {:engine,
            Command.run(engine, argv,
              timeout_ms: spec.timeout_ms,
              max_output_bytes: spec.output_bytes,
              execution_id: spec.execution_id || Ecto.UUID.generate(),
              on_timeout: fn -> cleanup_timed_out_container(engine, argv) end
            )} do
      backend_id
      |> report_from_result(spec, argv, result, started_at)
      |> write(bundle)
    else
      {:engine, {:error, :timeout}} ->
        backend_id
        |> timeout_report(spec, argv, started_at)
        |> write(bundle)

      {:engine, {:error, reason}} ->
        backend_id
        |> unavailable_report(spec, argv, started_at, reason)
        |> write(bundle)
    end
  end

  defp report_from_result(backend_id, spec, argv, result, started_at) do
    exit_status = result.exit_status

    %Report{
      status: if(exit_status == 0, do: :completed, else: :failed),
      backend: backend_id,
      command: CommandSpec.summary(spec),
      exit_status: exit_status,
      duration_ms: duration_ms(started_at),
      timed_out?: false,
      truncated?: result.truncated?,
      stdout: result.output,
      stderr: "",
      diagnostics: [],
      metadata: %{engine_argv: argv, stderr_merged?: true, output_bytes: result.output_bytes}
    }
  end

  defp timeout_report(backend_id, spec, argv, started_at) do
    %Report{
      status: :timed_out,
      backend: backend_id,
      command: CommandSpec.summary(spec),
      duration_ms: duration_ms(started_at),
      timed_out?: true,
      diagnostics: [%{reason: :timeout, timeout_ms: spec.timeout_ms}],
      metadata: %{engine_argv: argv}
    }
  end

  defp unavailable_report(backend_id, spec, argv, started_at, reason) do
    %Report{
      status: :unavailable,
      backend: backend_id,
      command: CommandSpec.summary(spec),
      duration_ms: duration_ms(started_at),
      diagnostics: [%{reason: reason}],
      metadata: %{engine_argv: argv}
    }
  end

  defp write(report, bundle), do: ReportWriter.write(bundle, report)

  defp duration_ms(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp cleanup_timed_out_container(engine, argv) do
    with {:ok, name} <- container_name(argv) do
      _cleanup = System.cmd(engine, ["rm", "-f", name], stderr_to_stdout: true)
      :ok
    else
      _other -> :ok
    end
  rescue
    _exception -> :ok
  end

  defp container_name(argv) do
    case Enum.find_index(argv, &(&1 == "--name")) do
      nil -> {:error, :missing_container_name}
      index -> Enum.fetch(argv, index + 1)
    end
  end
end
