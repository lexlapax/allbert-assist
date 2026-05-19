defmodule AllbertAssist.Actions.Workspace.DismissEphemeral do
  @moduledoc "Dismiss a workspace ephemeral surface through Security Central."

  use Jido.Action,
    name: "dismiss_workspace_ephemeral",
    description: "Dismiss an active workspace ephemeral surface.",
    category: "workspace",
    tags: ["workspace", "ephemeral", "write"],
    schema: [
      surface_id: [type: :string, required: true],
      user_id: [type: :string, required: false],
      dismissed_by: [type: :string, required: false]
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
    dismissed_by = field(params, :dismissed_by, "operator")

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         user_id when is_binary(user_id) and user_id != "" <- user_id,
         {:ok, surface_id} <- required_string(params, :surface_id),
         {:ok, surface} <- Workspace.dismiss_ephemeral(surface_id, user_id, dismissed_by) do
      {:ok, completed(surface, permission_decision)}
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

  defp completed(surface, permission_decision) do
    %{
      message: "Dismissed workspace ephemeral surface #{surface.id}.",
      status: :completed,
      surface: surface,
      surface_id: surface.id,
      thread_id: surface.thread_id,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          surface_id: surface.id,
          thread_id: surface.thread_id,
          dismissed_by: surface.dismissed_by
        })
      ]
    }
  end

  defp denied(params, permission_decision, reason) do
    %{
      message: "Could not dismiss workspace ephemeral surface: #{inspect(reason)}",
      status: denied_status(permission_decision),
      reason: reason,
      permission_decision: permission_decision,
      actions: [
        action(:denied, permission_decision, %{
          surface_id: field(params, :surface_id),
          error: reason
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "dismiss_workspace_ephemeral",
      status: status,
      permission: :workspace_canvas_write,
      permission_decision: permission_decision,
      workspace_metadata: metadata
    }
  end

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
