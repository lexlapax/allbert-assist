defmodule AllbertAssist.Actions.Memory.ReviewMemoryEntry do
  @moduledoc "Reviews a markdown memory entry without deleting it."

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_review,
    skill_backed?: false,
    confirmation: :not_required,
    name: "review_memory_entry",
    description: "Set the review status for one markdown memory entry.",
    category: "memory",
    tags: ["memory", "review", "write"],
    schema: [
      path: [type: :string, required: true],
      status: [type: :string, required: true],
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
         {:ok, status} <- Memory.Review.normalize_status(value(params, :status)),
         {:ok, entry} <-
           Memory.review_entry(
             path,
             %{status: status, reviewed_by: user_id, note: value(params, :note)},
             user_id: user_id
           ) do
      entry_map = Entry.to_map(entry)

      {:ok,
       %{
         message: "Reviewed memory entry as #{entry.review_status}: #{entry.summary}",
         status: :completed,
         permission_decision: permission_decision,
         entry: entry_map,
         actions: [
           %{
             name: "review_memory_entry",
             status: :completed,
             permission: :memory_write,
             permission_decision: permission_decision,
             memory_path: entry.path,
             review_status: entry.review_status,
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
       message: "Unable to review memory entry: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "review_memory_entry",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))
end
