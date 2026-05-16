defmodule StockSage.Plugin do
  @moduledoc """
  StockSage plugin entrypoint.

  The plugin contributes contract data only. Registration does not grant
  permissions, start analysis execution, or load code dynamically.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "stocksage"

  @impl true
  def display_name, do: "StockSage"

  @impl true
  def version, do: "0.22.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def apps, do: [StockSage.App]

  @impl true
  def actions do
    [
      StockSage.Actions.ListAnalyses,
      StockSage.Actions.ShowAnalysis,
      StockSage.Actions.GetTrends,
      StockSage.Actions.QueueAnalysis,
      StockSage.Actions.ListQueue,
      StockSage.Actions.ImportSqlite,
      StockSage.Actions.RunAnalysis
    ]
  end

  @impl true
  def skill_paths do
    [Path.expand("../../skills", __DIR__)]
  end

  @impl true
  def settings_schema do
    [
      %{
        key: "stocksage.import.default_user",
        type: :string,
        default: "local",
        description: "Default local user id for StockSage import tasks."
      },
      %{
        key: "stocksage.import.batch_size",
        type: :positive_integer,
        default: 500,
        description: "Maximum rows per insert batch during StockSage import."
      },
      %{
        key: "stocksage.import.unknown_tables_as_warnings",
        type: :boolean,
        default: true,
        description: "Treat unknown legacy StockSage tables as warnings."
      },
      %{
        key: "stocksage.list.max_results",
        type: :positive_integer,
        default: 50,
        description: "Maximum rows returned by StockSage list operations."
      },
      %{
        key: "stocksage.queue.default_priority",
        type: :enum,
        default: "normal",
        allowed_values: ["low", "normal", "high"],
        description: "Default priority for new StockSage queue entries."
      },
      %{
        key: "stocksage.bridge_enabled",
        type: :boolean,
        default: true,
        description: "When false, the StockSage Python bridge does not open a Port."
      },
      %{
        key: "stocksage.python_path",
        type: :string,
        default: "python3",
        description: "Path or name of the Python 3 interpreter the bridge spawns."
      },
      %{
        key: "stocksage.bridge_timeout_ms",
        type: :positive_integer,
        default: 300_000,
        description: "Per-request timeout for StockSage bridge analyses (milliseconds)."
      },
      %{
        key: "stocksage.bridge_max_output_bytes",
        type: :positive_integer,
        default: 1_048_576,
        description: "Maximum bridge response body retained before truncation (bytes)."
      },
      %{
        key: "stocksage.analysis_engine",
        type: :enum,
        default: "tradingagents",
        allowed_values: ["tradingagents"],
        description: "Default analysis engine for StockSage RunAnalysis."
      }
    ]
  end

  @impl true
  def child_spec(_opts), do: :ignore
end
