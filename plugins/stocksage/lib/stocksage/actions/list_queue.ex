defmodule StockSage.Actions.ListQueue do
  @moduledoc false

  use Jido.Action,
    name: "list_queue",
    description: "List bounded local StockSage queue entries for the current user.",
    category: "stocksage",
    tags: ["stocksage", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      status: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias StockSage.{Actions, Queue}

  def capability, do: Actions.capability(:read_only, %{exposure: :internal, skill_backed?: false})

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:read_only, context)

    with {:ok, user_id} <- Actions.user_id(params, context) do
      if Actions.allowed?(permission_decision) do
        entries =
          Queue.list_entries(user_id,
            status: Actions.field(params, :status),
            limit: Actions.positive_limit(Actions.field(params, :limit), 50)
          )

        summaries = Enum.map(entries, &summary/1)

        {:ok,
         %{
           message: "Found #{length(summaries)} StockSage queue entries for #{user_id}.",
           status: :completed,
           user_id: user_id,
           queue_entries: summaries,
           actions: [
             Actions.action("list_queue", :completed, :read_only, permission_decision, %{
               returned: length(summaries)
             })
           ]
         }}
      else
        status = Actions.status_from_decision(permission_decision)

        {:ok,
         %{
           message: "StockSage queue entries are not available to this request.",
           status: status,
           error: :permission_denied,
           actions: [Actions.action("list_queue", status, :read_only, permission_decision)]
         }}
      end
    else
      {:error, :missing_user_id} ->
        Actions.missing_user("list_queue", :read_only, permission_decision)
    end
  end

  defp summary(entry) do
    %{
      id: entry.id,
      user_id: entry.user_id,
      symbol: entry.symbol,
      status: entry.status,
      priority: entry.priority,
      requested_for: entry.requested_for,
      analysis_id: entry.analysis_id,
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end
end
