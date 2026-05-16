defmodule StockSage.Actions.RunAnalysis do
  @moduledoc """
  StockSage analysis execution through the supervised Python bridge.

  v0.22 M1 contributes the registered capability metadata and inert schema.
  M2 wires `StockSage.TraderBridge`. M3 fills in the confirmation creation,
  approved resume path, and result persistence.
  """

  use Jido.Action,
    name: "run_analysis",
    description: "Run a StockSage analysis for a ticker through the Python bridge.",
    category: "stocksage",
    tags: ["stocksage", "analysis", "confirmation"],
    schema: [
      ticker: [type: :string, required: true],
      analysis_date: [type: :string, required: true],
      engine: [type: :string, required: false],
      user_id: [type: :string, required: false],
      queue_entry_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias StockSage.Actions

  def capability do
    Actions.capability(:stocksage_analyze, %{
      confirmation: :required,
      exposure: :agent,
      execution_mode: :python_bridge,
      risk_tier: :high
    })
  end

  @impl true
  def run(_params, context) do
    permission_decision = Actions.authorize(:stocksage_analyze, context)

    {:ok,
     %{
       message: "StockSage RunAnalysis execution is not yet wired (v0.22 M1 scaffold).",
       status: :error,
       error: :not_implemented,
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           :error,
           :stocksage_analyze,
           permission_decision,
           %{error: :not_implemented, milestone: "v0.22-m1"}
         )
       ]
     }}
  end
end
