defmodule AllbertAssist.Sandbox.Report do
  @moduledoc """
  Typed v0.36 sandbox command report.

  M1 defines the shared shape. Later milestones fill it from bundle, backend,
  command, and gate runner execution.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor

  defstruct status: :not_started,
            backend: nil,
            command: nil,
            exit_status: nil,
            duration_ms: 0,
            timed_out?: false,
            truncated?: false,
            stdout: "",
            stderr: "",
            report_path: nil,
            diagnostics: [],
            metadata: %{}

  @type t :: %__MODULE__{
          status: :completed | :failed | :denied | :timed_out | :not_started | :unavailable,
          backend: atom() | nil,
          command: map() | nil,
          exit_status: non_neg_integer() | nil,
          duration_ms: non_neg_integer(),
          timed_out?: boolean(),
          truncated?: boolean(),
          stdout: String.t(),
          stderr: String.t(),
          report_path: String.t() | nil,
          diagnostics: [map()],
          metadata: map()
        }

  @doc "Return the report as a redacted map safe for action responses and persisted reports."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = report) do
    report
    |> raw_map()
    |> redact_paths()
    |> Redactor.redact(:sandbox_trial)
  end

  @doc "Return the internal report shape without redaction."
  @spec raw_map(t()) :: map()
  def raw_map(%__MODULE__{} = report) do
    %{
      status: report.status,
      backend: report.backend,
      command: report.command,
      exit_status: report.exit_status,
      duration_ms: report.duration_ms,
      timed_out?: report.timed_out?,
      truncated?: report.truncated?,
      stdout: report.stdout,
      stderr: report.stderr,
      report_path: report.report_path,
      diagnostics: report.diagnostics,
      metadata: report.metadata
    }
  end

  defp redact_paths(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {key, redact_paths(val)} end)
    |> Map.new()
  end

  defp redact_paths(value) when is_list(value), do: Enum.map(value, &redact_paths/1)

  defp redact_paths(value) when is_binary(value) do
    String.replace(value, Paths.home(), "<ALLBERT_HOME>")
  end

  defp redact_paths(value), do: value
end
