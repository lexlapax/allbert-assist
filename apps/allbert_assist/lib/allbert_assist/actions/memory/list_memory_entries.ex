defmodule AllbertAssist.Actions.Memory.ListMemoryEntries do
  @moduledoc "Lists markdown-backed memory entries through the action boundary."

  use Jido.Action,
    name: "list_memory_entries",
    description: "List markdown memory entries for one local user.",
    category: "memory",
    tags: ["memory", "read_only", "review"],
    schema: [
      user_id: [type: :string, required: false],
      category: [type: :string, required: false],
      review_status: [type: :string, required: false],
      limit: [type: :integer, required: false],
      since: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      entries: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, entries} <- Memory.list_entries(list_opts(params, user_id)) do
      entry_maps = Enum.map(entries, &Entry.to_map(&1, include_body: false))

      {:ok,
       %{
         message: message(entry_maps),
         status: :completed,
         permission_decision: permission_decision,
         entries: entry_maps,
         actions: [
           %{
             name: "list_memory_entries",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             user_id: user_id,
             entry_count: length(entry_maps)
           }
         ]
       }}
    else
      {:allowed, false} ->
        denied(permission_decision)

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp list_opts(params, user_id) do
    [
      user_id: user_id,
      category: value(params, :category),
      review_status: value(params, :review_status),
      limit: limit(value(params, :limit)),
      since: value(params, :since)
    ]
  end

  defp message([]), do: "No memory entries found."

  defp message(entries) do
    "Found #{length(entries)} memory entr#{if length(entries) == 1, do: "y", else: "ies"}."
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       entries: [],
       actions: [
         %{
           name: "list_memory_entries",
           status: PermissionGate.response_status(permission_decision),
           permission: :read_only,
           permission_decision: permission_decision
         }
       ]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to list memory entries: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       entries: [],
       actions: [
         %{
           name: "list_memory_entries",
           status: :error,
           permission: :read_only,
           permission_decision: permission_decision,
           error: reason
         }
       ]
     }}
  end

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp limit(nil), do: 50
  defp limit(limit) when is_integer(limit), do: min(max(limit, 1), 200)

  defp limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {integer, ""} -> limit(integer)
      _other -> 50
    end
  end

  defp limit(_limit), do: 50
end
