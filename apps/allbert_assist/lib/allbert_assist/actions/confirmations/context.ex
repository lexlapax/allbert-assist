defmodule AllbertAssist.Actions.Confirmations.Context do
  @moduledoc false

  def resolution_attrs(context, reason, record \\ nil) do
    %{
      resolver_actor: actor(context),
      resolver_channel: channel(context),
      resolver_surface: surface(context),
      resolver_session_id: session_id(context),
      resolution_reason: blank_to_nil(reason),
      same_channel?: same_channel?(record, context),
      decision_source: "operator"
    }
  end

  def action(record, action_name, status, permission_decision, metadata \\ %{}) do
    %{
      name: action_name,
      status: status,
      permission: Map.get(permission_decision, :permission, :confirmation_decide),
      permission_decision: permission_decision,
      confirmation_metadata:
        Map.merge(
          %{
            id: Map.get(record, "id"),
            confirmation_status: Map.get(record, "status"),
            target_action: get_in(record, ["target_action", "name"]),
            target_permission: Map.get(record, "target_permission")
          },
          metadata
        )
    }
  end

  def denied(action_name, permission, permission_decision, reason) do
    {:ok,
     %{
       message: "Confirmation action #{action_name} was denied: #{inspect(reason)}",
       status: :denied,
       permission_decision: permission_decision,
       error: reason,
       actions: [
         %{
           name: action_name,
           status: :denied,
           permission: permission,
           permission_decision: permission_decision,
           confirmation_metadata: %{error: reason}
         }
       ]
     }}
  end

  defp actor(%{request: %{operator_id: actor}}), do: actor
  defp actor(%{request: %{"operator_id" => actor}}), do: actor
  defp actor(%{actor: actor}), do: actor
  defp actor(%{"actor" => actor}), do: actor
  defp actor(_context), do: "local"

  defp channel(%{request: %{channel: channel}}), do: channel
  defp channel(%{request: %{"channel" => channel}}), do: channel
  defp channel(%{channel: channel}), do: channel
  defp channel(%{"channel" => channel}), do: channel
  defp channel(_context), do: :unknown

  defp surface(%{surface: surface}), do: surface
  defp surface(%{"surface" => surface}), do: surface
  defp surface(_context), do: "action"

  defp session_id(%{session_id: session_id}), do: session_id
  defp session_id(%{"session_id" => session_id}), do: session_id
  defp session_id(%{request: %{session_id: session_id}}), do: session_id
  defp session_id(%{request: %{"session_id" => session_id}}), do: session_id
  defp session_id(_context), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp same_channel?(%{"origin" => %{} = origin}, context) do
    channel_key(Map.get(origin, "channel")) == channel_key(channel(context))
  end

  defp same_channel?(_record, _context), do: false

  defp channel_key(:liveview), do: "live_view"
  defp channel_key("liveview"), do: "live_view"
  defp channel_key(value) when is_atom(value), do: Atom.to_string(value)
  defp channel_key(value) when is_binary(value), do: value
  defp channel_key(value), do: inspect(value)
end
