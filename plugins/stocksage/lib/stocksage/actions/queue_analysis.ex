defmodule StockSage.Actions.QueueAnalysis do
  @moduledoc false

  use Jido.Action,
    name: "queue_analysis",
    description: "Create a local StockSage queue row without running analysis.",
    category: "stocksage",
    tags: ["stocksage", "write"],
    schema: [
      user_id: [type: :string, required: false],
      symbol: [type: :string, required: true],
      thread_id: [type: :string, required: false],
      session_id: [type: :string, required: false],
      requested_for: [type: :string, required: false],
      priority: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias StockSage.{Actions, Queue}

  def capability, do: Actions.capability(:stocksage_write)

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:stocksage_write, context)
    user_id = Actions.user_id(params, context)

    if Actions.allowed?(permission_decision) do
      attrs = %{
        user_id: user_id,
        symbol: Actions.field(params, :symbol),
        thread_id: Actions.field(params, :thread_id) || Actions.field(context, :thread_id),
        session_id: Actions.field(params, :session_id) || Actions.field(context, :session_id),
        requested_for: parse_date(Actions.field(params, :requested_for)),
        priority: Actions.field(params, :priority, "normal"),
        request: %{
          "source" => "queue_analysis_action",
          "app_id" => "stocksage"
        },
        input_signal_id: Actions.field(context, :input_signal_id),
        trace_id: Actions.field(context, :trace_id)
      }

      case Queue.create_entry(attrs) do
        {:ok, entry} ->
          {:ok, completed(entry, permission_decision)}

        {:error, changeset} ->
          {:ok, invalid(changeset, permission_decision)}
      end
    else
      status = Actions.status_from_decision(permission_decision)

      {:ok,
       %{
         message: "StockSage queue writes are not available to this request.",
         status: status,
         error: :permission_denied,
         actions: [
           Actions.action("queue_analysis", status, :stocksage_write, permission_decision, %{
             error: :permission_denied
           })
         ]
       }}
    end
  end

  defp completed(entry, permission_decision) do
    %{
      message: "Queued StockSage analysis for #{entry.symbol}.",
      status: :completed,
      queue_entry: %{
        id: entry.id,
        user_id: entry.user_id,
        symbol: entry.symbol,
        status: entry.status,
        priority: entry.priority,
        requested_for: entry.requested_for,
        inserted_at: entry.inserted_at
      },
      actions: [
        Actions.action("queue_analysis", :completed, :stocksage_write, permission_decision, %{
          queue_id: entry.id,
          symbol: entry.symbol,
          status: entry.status
        })
      ]
    }
  end

  defp invalid(changeset, permission_decision) do
    %{
      message: "Could not queue StockSage analysis: #{inspect(errors_on(changeset))}",
      status: :error,
      error: {:invalid_queue_entry, errors_on(changeset)},
      actions: [
        Actions.action("queue_analysis", :error, :stocksage_write, permission_decision, %{
          error: :invalid_queue_entry
        })
      ]
    }
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(_value), do: nil

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
