defmodule AllbertAssist.Sandbox.Backends.ContainerRunner do
  @moduledoc false

  alias AllbertAssist.Sandbox.Backends.Command
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Sandbox.ReportWriter
  alias AllbertAssist.Sandbox.SourcePolicy

  @spec run(atom(), String.t(), [String.t()], Bundle.t(), CommandSpec.t()) ::
          {:ok, Report.t()} | {:error, term()}
  def run(backend_id, engine, argv, %Bundle{} = bundle, %CommandSpec{} = spec) do
    started_at = System.monotonic_time(:millisecond)

    with {:source_policy, {:ok, source_report}} <- {:source_policy, SourcePolicy.scan(bundle)},
         {:engine, {:ok, result}} <-
           {:engine,
            Command.run(engine, argv,
              timeout_ms: spec.timeout_ms,
              max_output_bytes: spec.output_bytes
            )} do
      backend_id
      |> report_from_result(spec, argv, result, started_at, source_report)
      |> write(bundle)
    else
      {:source_policy, {:error, source_report}} ->
        backend_id
        |> denied_report(spec, argv, started_at, source_report.diagnostics)
        |> write(bundle)

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

  defp report_from_result(backend_id, spec, argv, result, started_at, source_report) do
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
      diagnostics: source_report.diagnostics,
      metadata: %{engine_argv: argv, stderr_merged?: true, output_bytes: result.output_bytes}
    }
  end

  defp denied_report(backend_id, spec, argv, started_at, diagnostics) do
    %Report{
      status: :denied,
      backend: backend_id,
      command: CommandSpec.summary(spec),
      duration_ms: duration_ms(started_at),
      diagnostics: diagnostics,
      metadata: %{engine_argv: argv}
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
end
