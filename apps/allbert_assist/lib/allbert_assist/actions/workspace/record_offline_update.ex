defmodule AllbertAssist.Actions.Workspace.RecordOfflineUpdate do
  @moduledoc "Record a browser-originated workspace editor update through Security Central."

  use AllbertAssist.Action,
    permission: :workspace_canvas_write,
    exposure: :internal,
    execution_mode: :workspace_canvas_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "record_workspace_offline_update",
    description: "Record a browser-originated workspace canvas editor revision.",
    category: "workspace",
    tags: ["workspace", "canvas", "offline", "write"],
    schema: [
      tile_id: [type: :string, required: true],
      thread_id: [type: :string, required: true],
      user_id: [type: :string, required: false],
      snapshot: [type: :string, required: true],
      update: [type: :string, required: false],
      state_vector: [type: :string, required: false],
      base_revision_id: [type: :string, required: false],
      origin: [type: :string, required: false],
      max_bytes: [type: :integer, required: false],
      metadata: [type: :map, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Workspace

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:workspace_canvas_write, context)
    user_id = field(context, :user_id) || field(context, :actor) || field(params, :user_id)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         user_id when is_binary(user_id) and user_id != "" <- user_id,
         {:ok, result} <- Workspace.record_offline_update(Map.put(params, :user_id, user_id)) do
      {:ok, completed(result, permission_decision)}
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

  defp completed(result, permission_decision) do
    status = if result.conflict?, do: :conflict, else: :completed

    %{
      message: "Recorded workspace offline update for tile #{result.tile.id}.",
      status: status,
      result: result,
      tile_id: result.tile.id,
      revision_id: result.revision.id,
      current_revision_id: result.tile.current_revision_id,
      conflict_count: result.conflict_count,
      conflict?: result.conflict?,
      permission_decision: permission_decision,
      actions: [
        action(status, permission_decision, %{
          tile_id: result.tile.id,
          thread_id: result.tile.thread_id,
          revision_id: result.revision.id,
          conflict_count: result.conflict_count,
          origin: result.revision.origin
        })
      ]
    }
  end

  defp denied(params, permission_decision, reason) do
    %{
      message: "Could not record workspace offline update: #{inspect(reason)}",
      status: denied_status(permission_decision),
      reason: reason,
      permission_decision: permission_decision,
      actions: [
        action(:denied, permission_decision, %{
          tile_id: field(params, :tile_id),
          thread_id: field(params, :thread_id),
          error: reason
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "record_workspace_offline_update",
      status: status,
      permission: :workspace_canvas_write,
      permission_decision: permission_decision,
      workspace_metadata: metadata
    }
  end

  defp denied_status(%{decision: :allowed}), do: :denied
  defp denied_status(permission_decision), do: PermissionGate.response_status(permission_decision)

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
