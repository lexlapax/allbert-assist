defmodule AllbertAssist.Actions.Memory.DeleteMemoryEntry do
  @moduledoc "Archives a markdown memory entry, usually after confirmation."

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_archive,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "delete_memory_entry",
    description: "Archive one markdown memory entry through the confirmation workflow.",
    category: "memory",
    tags: ["memory", "delete", "confirmation"],
    schema: [
      path: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      archived: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:memory_write, context)
    path = value(params, :path)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, path} <- required_path(path),
         {:ok, user_id} <- Context.user_id(params, context) do
      cond do
        approval_resume?(context) ->
          archive_now(path, user_id, permission_decision, :approval)

        confirmation_required?("memory.delete_requires_confirmation") ->
          create_confirmation(path, user_id, context, permission_decision)

        true ->
          archive_now(path, user_id, permission_decision, :immediate)
      end
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  def run(_params, context),
    do: error(PermissionGate.authorize(:memory_write, context), :missing_path)

  defp archive_now(path, user_id, permission_decision, execution) do
    case Memory.archive_entry(path, user_id: user_id) do
      {:ok, archived} ->
        {:ok,
         %{
           message: "Archived memory entry: #{archived.summary}",
           status: :completed,
           permission_decision: permission_decision,
           archived: archived,
           actions: [
             %{
               name: "delete_memory_entry",
               status: :completed,
               permission: :memory_write,
               permission_decision: permission_decision,
               execution: execution,
               memory_path: archived.path,
               archived_path: archived.archived_path,
               user_id: user_id
             }
           ]
         }}

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp create_confirmation(path, user_id, context, permission_decision) do
    with {:ok, entry} <- Memory.read_entry(path, user_id: user_id),
         {:ok, confirmation} <-
           Confirmations.create(%{
             origin: origin(context, user_id),
             target_action: %{name: "delete_memory_entry", module: inspect(__MODULE__)},
             target_permission: :memory_write,
             target_execution_mode: :memory_archive,
             security_decision: permission_decision,
             params_summary: %{
               path: entry.path,
               category: entry.category,
               summary: entry.summary,
               user_id: user_id
             },
             resume_params_ref: %{path: entry.path, user_id: user_id}
           }) do
      {:ok,
       %{
         message:
           "Memory deletion is ready for approval. Confirmation request: #{confirmation["id"]}. The file was not moved.",
         status: :needs_confirmation,
         permission_decision: permission_decision,
         confirmation: confirmation,
         confirmation_id: confirmation["id"],
         actions: [
           %{
             name: "delete_memory_entry",
             status: :needs_confirmation,
             permission: :memory_write,
             permission_decision: permission_decision,
             execution: :pending_confirmation,
             confirmation_id: confirmation["id"],
             memory_path: entry.path,
             user_id: user_id
           }
         ]
       }}
    else
      {:error, reason} -> error(permission_decision, reason)
    end
  end

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
       message: "Unable to delete memory entry: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "delete_memory_entry",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp confirmation_required?(key) do
    case Settings.get(key) do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_context), do: false

  defp required_path(path) when is_binary(path) and path != "", do: {:ok, path}
  defp required_path(_path), do: {:error, :missing_path}

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp origin(context, user_id) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor, user_id),
      user_id: user_id,
      session_id: Map.get(context, :session_id),
      surface: Map.get(context, :surface, "action")
    }
  end
end
