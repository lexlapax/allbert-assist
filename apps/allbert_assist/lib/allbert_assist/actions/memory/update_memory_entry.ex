defmodule AllbertAssist.Actions.Memory.UpdateMemoryEntry do
  @moduledoc "Corrects a markdown memory entry in place."

  use Jido.Action,
    name: "update_memory_entry",
    description: "Update the summary or body for one markdown memory entry.",
    category: "memory",
    tags: ["memory", "review", "write"],
    schema: [
      path: [type: :string, required: true],
      summary: [type: :string, required: false],
      body: [type: :string, required: false],
      note: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      entry: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{path: path} = params, context) do
    permission_decision = PermissionGate.authorize(:memory_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, entry} <- Memory.update_entry(path, params, user_id: user_id) do
      entry_map = Entry.to_map(entry)

      {:ok,
       %{
         message: "Updated memory entry: #{entry.summary}",
         status: :completed,
         permission_decision: permission_decision,
         entry: entry_map,
         actions: [
           %{
             name: "update_memory_entry",
             status: :completed,
             permission: :memory_write,
             permission_decision: permission_decision,
             memory_path: entry.path,
             user_id: user_id
           }
         ]
       }}
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  def run(_params, context),
    do: error(PermissionGate.authorize(:memory_write, context), :missing_path)

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to update memory entry: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "update_memory_entry",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
