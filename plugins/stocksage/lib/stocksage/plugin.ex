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
  def version, do: "0.20.0"

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
      StockSage.Actions.QueueAnalysis
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
      }
    ]
  end

  @impl true
  def child_spec(_opts), do: :ignore
end
