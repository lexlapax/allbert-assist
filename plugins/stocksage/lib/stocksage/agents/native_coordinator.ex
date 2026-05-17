defmodule StockSage.Agents.NativeCoordinator do
  @moduledoc """
  JidoBacked coordinator for the StockSage native agent graph.

  v0.25 M2 keeps the coordinator inert: it validates the request shape and
  returns bounded stub packets. Later milestones replace these stubs with the
  evidence-action and debate/synthesis loop while keeping this supervised
  boundary stable for RunAnalysis and cross-app delegation.
  """

  alias AllbertAssist.JidoBacked
  alias StockSage.Agents.NativeCoordinator.Commands

  @analyze "allbert.stocksage.native.analyze"
  @parity_run "allbert.stocksage.native.parity_run"

  use JidoBacked,
    name: "stocksage_native_coordinator",
    description: "Coordinates StockSage native financial specialist agents.",
    schema: [
      active_runs: [type: :map, default: %{}],
      last_command: [type: :atom, default: nil],
      last_result: [type: :any, default: nil],
      last_error: [type: :string, default: nil],
      last_summary: [type: :any, default: nil]
    ],
    signal_routes: [
      {@analyze, Commands.Analyze},
      {@parity_run, Commands.ParityRun}
    ]

  @impl true
  def rebuild_state(_opts) do
    {:ok,
     %{
       active_runs: %{},
       last_command: :rebuild,
       last_result: {:ok, %{active_runs: 0}},
       last_error: nil,
       last_summary: %{active_runs: 0}
     }}
  end

  @impl true
  def command_modules, do: [Commands.Analyze, Commands.ParityRun]

  @spec analyze(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def analyze(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @analyze, params)
  end

  @spec parity_run(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def parity_run(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @parity_run, params)
  end

  defp dispatch(server, signal_type, params) do
    JidoBacked.dispatch(server, signal_type, params,
      source: "/stocksage/native_coordinator",
      timeout: :infinity
    )
  end
end
