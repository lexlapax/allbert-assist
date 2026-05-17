defmodule StockSage.Agents.NativeCoordinator.Commands.ParityRun do
  @moduledoc "M2 stub parity-run command for the StockSage native coordinator."

  use Jido.Action,
    name: "stocksage_native_coordinator_parity_run",
    description: "Return a bounded native/python parity stub packet."

  @impl true
  def run(params, _context) do
    report = %{
      status: :ok,
      engine: "both",
      request_id: field(params, :request_id) || "parity-#{System.unique_integer([:positive])}",
      ticker: field(params, :ticker, "UNKNOWN"),
      analysis_date: field(params, :analysis_date),
      native_report: %{
        status: :stub,
        final_trade_decision: "Hold",
        confidence: 0.5
      },
      python_report: %{
        status: :not_run,
        reason: "v0.25 M2 parity stub does not call Python"
      },
      parity_diff: %{
        "rating_agreement" => 1.0,
        "native_rating" => "Hold",
        "python_rating" => "Hold",
        "native_confidence" => 0.5,
        "python_confidence" => 0.5,
        "confidence_delta" => 0.0,
        "within_variance" => true,
        "parity_pass" => true,
        "computed_at" => DateTime.utc_now()
      },
      warnings: ["parity skeleton only; no native LLM or Python call executed"]
    }

    {:ok,
     %{
       active_runs: %{},
       last_command: :parity_run,
       last_result: {:ok, report},
       last_error: nil,
       last_summary: Map.take(report, [:ticker, :analysis_date, :engine, :status])
     }}
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
