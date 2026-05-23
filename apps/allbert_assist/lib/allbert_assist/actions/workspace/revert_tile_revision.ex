defmodule AllbertAssist.Actions.Workspace.RevertTileRevision do
  @moduledoc "Revert an editable workspace tile to a recorded revision snapshot."

  use AllbertAssist.Action,
    permission: :workspace_canvas_write,
    exposure: :internal,
    execution_mode: :workspace_canvas_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "revert_tile_revision",
    description: "Revert a workspace canvas tile to a prior recorded revision.",
    category: "workspace",
    tags: ["workspace", "canvas", "write"],
    schema: [
      tile_id: [type: :string, required: true],
      revision_id: [type: :string, required: true],
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
  def run(%{tile_id: tile_id, revision_id: revision_id} = params, context) do
    permission_decision = PermissionGate.authorize(:workspace_canvas_write, context)
    user_id = Map.get(params, :user_id) || Map.get(context, :user_id) || Map.get(context, :actor)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         user_id when is_binary(user_id) and user_id != "" <- user_id,
         {:ok, result} <-
           Workspace.revert_tile_revision(%{
             tile_id: tile_id,
             revision_id: revision_id,
             user_id: user_id
           }) do
      {:ok, completed(result, revision_id, permission_decision)}
    else
      {:allowed, false} ->
        {:ok, denied(tile_id, revision_id, permission_decision, :permission_denied)}

      nil ->
        {:ok, denied(tile_id, revision_id, permission_decision, :missing_user_id)}

      "" ->
        {:ok, denied(tile_id, revision_id, permission_decision, :missing_user_id)}

      {:error, reason} ->
        {:ok, denied(tile_id, revision_id, permission_decision, reason)}

      _other ->
        {:ok, denied(tile_id, revision_id, permission_decision, :missing_user_id)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:workspace_canvas_write, context)
    {:ok, denied(nil, nil, permission_decision, :invalid_params)}
  end

  defp completed(result, reverted_to_revision_id, permission_decision) do
    %{
      message: "Reverted tile #{result.tile.id} to revision #{reverted_to_revision_id}.",
      status: :completed,
      tile_id: result.tile.id,
      revision_id: result.revision.id,
      reverted_to_revision_id: reverted_to_revision_id,
      permission_decision: permission_decision,
      actions: [
        action(:completed, result.tile.id, reverted_to_revision_id, permission_decision)
      ]
    }
  end

  defp denied(tile_id, revision_id, permission_decision, reason) do
    %{
      message: "Could not revert tile revision: #{inspect(reason)}",
      status: :denied,
      reason: reason,
      permission_decision: permission_decision,
      actions: [action(:denied, tile_id, revision_id, permission_decision)]
    }
  end

  defp action(status, tile_id, revision_id, permission_decision) do
    %{
      name: "revert_tile_revision",
      status: status,
      permission: :workspace_canvas_write,
      permission_decision: permission_decision,
      workspace_metadata: %{
        tile_id: tile_id,
        revision_id: revision_id
      }
    }
  end
end
