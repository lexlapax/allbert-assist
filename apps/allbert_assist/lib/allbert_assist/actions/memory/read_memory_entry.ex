defmodule AllbertAssist.Actions.Memory.ReadMemoryEntry do
  @moduledoc "Reads one markdown-backed memory entry through the action boundary."

  use Jido.Action,
    name: "read_memory_entry",
    description: "Read one markdown memory entry for one local user.",
    category: "memory",
    tags: ["memory", "read_only", "review"],
    schema: [
      path: [type: :string, required: true],
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
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, entry} <- Memory.read_entry(path, user_id: user_id) do
      entry_map = Entry.to_map(entry)

      {:ok,
       %{
         message: "Read memory entry: #{entry.summary}",
         status: :completed,
         permission_decision: permission_decision,
         entry: entry_map,
         actions: [
           %{
             name: "read_memory_entry",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             user_id: user_id,
             memory_path: entry.path,
             memory_category: entry.category
           }
         ]
       }}
    else
      {:allowed, false} ->
        denied(permission_decision)

      {:error, :not_found} ->
        not_found(permission_decision)

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    error(permission_decision, :missing_path)
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "read_memory_entry",
           status: PermissionGate.response_status(permission_decision),
           permission: :read_only,
           permission_decision: permission_decision
         }
       ]
     }}
  end

  defp not_found(permission_decision) do
    {:ok,
     %{
       message: "Memory entry not found.",
       status: :not_found,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "read_memory_entry",
           status: :not_found,
           permission: :read_only,
           permission_decision: permission_decision
         }
       ]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to read memory entry: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "read_memory_entry",
           status: :error,
           permission: :read_only,
           permission_decision: permission_decision,
           error: reason
         }
       ]
     }}
  end
end
