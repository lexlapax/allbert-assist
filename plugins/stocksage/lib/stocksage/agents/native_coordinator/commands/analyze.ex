defmodule StockSage.Agents.NativeCoordinator.Commands.Analyze do
  @moduledoc "M2 stub analyze command for the StockSage native coordinator."

  use Jido.Action,
    name: "stocksage_native_coordinator_analyze",
    description: "Return a bounded native-analysis stub packet."

  alias StockSage.Agents

  @impl true
  def run(params, _context) do
    report = report(params, "native")

    {:ok,
     %{
       active_runs: %{},
       last_command: :analyze,
       last_result: {:ok, report},
       last_error: nil,
       last_summary: Map.take(report, [:ticker, :analysis_date, :engine, :status])
     }}
  end

  defp report(params, engine) do
    %{
      status: :ok,
      engine: engine,
      request_id: field(params, :request_id) || "native-#{System.unique_integer([:positive])}",
      ticker: field(params, :ticker, "UNKNOWN"),
      analysis_date: field(params, :analysis_date),
      agent_ids: Agents.ids(),
      agent_reports: %{},
      final_trade_decision: "Hold",
      recommendation: "Hold",
      confidence: 0.5,
      summary: "v0.25 M2 native coordinator stub; no LLM or provider call executed.",
      warnings: ["native coordinator skeleton only"],
      generated_at: DateTime.utc_now()
    }
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
