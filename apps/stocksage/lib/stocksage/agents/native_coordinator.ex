defmodule StockSage.Agents.NativeCoordinator do
  @moduledoc """
  JidoBacked coordinator for the StockSage native agent graph.

  v0.25 coordinates bounded, stage-local parallelism for independent
  specialist calls while keeping dependency-bearing stages ordered. Analysts
  run in parallel, bull/bear rounds remain sequential so each side can respond
  to the prior stance, risk perspectives run in parallel per round, and
  explicit parity mode runs native and Python comparison concurrently. Every
  specialist turn is still recorded as a durable objective step and executes
  through the monitored AgentRegistry dispatch boundary.
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
    dispatch(server, @analyze, params, :analyze)
  end

  @spec parity_run(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def parity_run(server \\ __MODULE__, params) when is_map(params) do
    dispatch(server, @parity_run, params, :parity_run)
  end

  defp dispatch(server, signal_type, params, expected_command) do
    JidoBacked.dispatch(server, signal_type, params,
      source: "/stocksage/native_coordinator",
      timeout: :infinity,
      expected_command: expected_command
    )
  end
end
