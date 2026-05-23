defmodule AllbertAssist.Actions.Workspace.ManageTile do
  @moduledoc "Manage a workspace canvas tile through Security Central."

  use AllbertAssist.Action,
    permission: :workspace_canvas_write,
    exposure: :internal,
    execution_mode: :workspace_canvas_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "manage_workspace_tile",
    description: "Pin, unpin, remove, or restore a workspace canvas tile.",
    category: "workspace",
    tags: ["workspace", "canvas", "write"],
    schema: [
      tile_id: [type: :string, required: true],
      operation: [type: :string, required: true],
      thread_id: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Workspace

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:workspace_canvas_write, context)
    user_id = field(params, :user_id) || field(context, :user_id) || field(context, :actor)
    thread_id = field(params, :thread_id) || field(context, :thread_id)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         user_id when is_binary(user_id) and user_id != "" <- user_id,
         {:ok, tile_id} <- required_string(params, :tile_id),
         {:ok, operation} <- operation(params),
         {:ok, scoped_tile} <- scoped_tile(operation, tile_id, user_id, thread_id),
         {:ok, tile} <- manage_tile(operation, scoped_tile, user_id) do
      {:ok, completed(tile, operation, permission_decision)}
    else
      {:allowed, false} ->
        {:ok, denied(params, permission_decision, :permission_denied)}

      nil ->
        {:ok, denied(params, permission_decision, :missing_user_id)}

      "" ->
        {:ok, denied(params, permission_decision, :missing_user_id)}

      {:error, reason} ->
        {:ok, denied(params, permission_decision, reason)}

      _other ->
        {:ok, denied(params, permission_decision, :missing_user_id)}
    end
  end

  def run(params, context) do
    permission_decision = PermissionGate.authorize(:workspace_canvas_write, context)
    {:ok, denied(params, permission_decision, :invalid_params)}
  end

  defp scoped_tile(operation, tile_id, user_id, thread_id) do
    get_opts = if operation == :restore, do: [include_deleted: true], else: []

    with {:ok, tile} <- Workspace.get_tile(tile_id, user_id, get_opts),
         :ok <- ensure_thread(tile, thread_id) do
      {:ok, tile}
    end
  end

  defp ensure_thread(_tile, nil), do: :ok
  defp ensure_thread(_tile, ""), do: :ok
  defp ensure_thread(%{thread_id: thread_id}, thread_id), do: :ok
  defp ensure_thread(_tile, _thread_id), do: {:error, :tile_thread_mismatch}

  defp manage_tile(:pin, tile, user_id), do: Workspace.pin_tile(tile.id, user_id)
  defp manage_tile(:unpin, tile, user_id), do: Workspace.unpin_tile(tile.id, user_id)
  defp manage_tile(:restore, tile, user_id), do: Workspace.restore_tile(tile.id, user_id)

  defp manage_tile(:remove, tile, user_id) do
    with :ok <- Workspace.remove_tile(tile.id, user_id),
         {:ok, removed} <- Workspace.get_tile(tile.id, user_id, include_deleted: true) do
      {:ok, removed}
    end
  end

  defp completed(tile, operation, permission_decision) do
    %{
      message: "#{operation_label(operation)} workspace tile #{tile.id}.",
      status: :completed,
      tile: tile,
      tile_id: tile.id,
      operation: operation,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          tile_id: tile.id,
          thread_id: tile.thread_id,
          operation: operation
        })
      ]
    }
  end

  defp denied(params, permission_decision, reason) do
    %{
      message: "Could not manage workspace tile: #{inspect(reason)}",
      status: denied_status(permission_decision),
      reason: reason,
      permission_decision: permission_decision,
      actions: [
        action(:denied, permission_decision, %{
          tile_id: field(params, :tile_id),
          thread_id: field(params, :thread_id),
          operation: field(params, :operation),
          error: reason
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "manage_workspace_tile",
      status: status,
      permission: :workspace_canvas_write,
      permission_decision: permission_decision,
      workspace_metadata: metadata
    }
  end

  defp operation(params) do
    case field(params, :operation) do
      "pin" -> {:ok, :pin}
      "unpin" -> {:ok, :unpin}
      "remove" -> {:ok, :remove}
      "restore" -> {:ok, :restore}
      value -> {:error, {:unsupported_operation, value}}
    end
  end

  defp operation_label(:pin), do: "Pinned"
  defp operation_label(:unpin), do: "Unpinned"
  defp operation_label(:remove), do: "Removed"
  defp operation_label(:restore), do: "Restored"

  defp denied_status(%{decision: :allowed}), do: :denied
  defp denied_status(permission_decision), do: PermissionGate.response_status(permission_decision)

  defp required_string(map, key) do
    case field(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required, key}}
    end
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
