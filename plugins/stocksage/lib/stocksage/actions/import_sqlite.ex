defmodule StockSage.Actions.ImportSqlite do
  @moduledoc false

  use Jido.Action,
    name: "import_stocksage_sqlite",
    description: "Import a reviewed local legacy StockSage SQLite database.",
    category: "stocksage",
    tags: ["stocksage", "write", "import"],
    schema: [
      path: [type: :string, required: true],
      user_id: [type: :string, required: false],
      dry_run: [type: :boolean, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias StockSage.Actions
  alias StockSage.Import.SqliteImporter

  def capability,
    do: Actions.capability(:stocksage_write, %{exposure: :internal, skill_backed?: false})

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:stocksage_write, context)

    with {:ok, user_id} <- Actions.user_id(params, context) do
      if Actions.allowed?(permission_decision) do
        params
        |> Actions.field(:path)
        |> SqliteImporter.import(
          user_id: user_id,
          dry_run: truthy?(Actions.field(params, :dry_run, false)),
          limit: Actions.field(params, :limit)
        )
        |> case do
          {:ok, result} -> {:ok, completed(result, permission_decision)}
          {:error, reason} -> {:ok, failed(reason, permission_decision)}
        end
      else
        status = Actions.status_from_decision(permission_decision)

        {:ok,
         %{
           message: "StockSage imports are not available to this request.",
           status: status,
           error: :permission_denied,
           actions: [
             Actions.action(
               "import_stocksage_sqlite",
               status,
               :stocksage_write,
               permission_decision,
               %{
                 error: :permission_denied
               }
             )
           ]
         }}
      end
    else
      {:error, :missing_user_id} ->
        Actions.missing_user("import_stocksage_sqlite", :stocksage_write, permission_decision)
    end
  end

  defp completed(result, permission_decision) do
    %{
      message: "Imported StockSage SQLite source for #{result.user_id}.",
      status: :completed,
      import: result,
      actions: [
        Actions.action(
          "import_stocksage_sqlite",
          :completed,
          :stocksage_write,
          permission_decision,
          %{
            dry_run: result.dry_run,
            warnings: length(result.warnings),
            analyses_inserted: result.counts["analyses"].inserted,
            analyses_updated: result.counts["analyses"].updated
          }
        )
      ]
    }
  end

  defp failed(reason, permission_decision) do
    %{
      message: "StockSage import failed: #{inspect(reason)}",
      status: :error,
      error: reason,
      actions: [
        Actions.action(
          "import_stocksage_sqlite",
          :error,
          :stocksage_write,
          permission_decision,
          %{
            error: :import_failed
          }
        )
      ]
    }
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_value), do: false
end
