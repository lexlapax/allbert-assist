defmodule AllbertAssist.Actions.Channels.ConfigureChannelSetting do
  @moduledoc """
  v0.62 M8.15 — route channel config Settings writes onto the one action spine.

  Operator channel configuration that writes only Settings Central keys under
  `channels.<channel>.*` — token references, application/team ids, allowlist
  values, per-provider identity-map entries, and enable/disable toggles — runs
  here so the write is gated by `:settings_write` and audited through the Runner
  instead of a direct store call. No secret value passes through this action;
  credential writes go through `configure_channel_secret`.
  """

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :channel_config_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "configure_channel_setting",
    description: "Write one channels.* Settings Central key (gated + audited).",
    category: "channels",
    tags: ["channels", "settings", "config"],
    schema: [
      channel: [type: :string, required: true],
      key: [type: :string, required: true],
      value: [type: :any, required: true, doc: "Typed channels.* Settings Central value."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      setting: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(%{channel: channel, key: key, value: value}, context)
      when is_binary(channel) and is_binary(key) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    setting_key = "channels.#{channel}.#{key}"

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, setting} <-
           Settings.put(setting_key, value, action_context(context, permission_decision)) do
      {:ok,
       %{
         message: "Updated #{setting.key}.",
         status: :completed,
         permission_decision: permission_decision,
         setting: %{
           channel: channel,
           key: key,
           setting_key: setting.key,
           value: setting.value
         },
         actions: [
           action(:completed, permission_decision, %{channel: channel, setting_key: setting.key})
         ]
       }}
    else
      false -> {:ok, denied(channel, setting_key, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(channel, setting_key, permission_decision, reason)}
    end
  end

  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    {:ok,
     denied(
       Map.get(params, :channel),
       Map.get(params, :key),
       permission_decision,
       :invalid_params
     )}
  end

  defp denied(channel, setting_key, permission_decision, reason) do
    %{
      message: "I could not update #{inspect(setting_key)}: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [
        action(:denied, permission_decision, %{
          channel: channel,
          setting_key: setting_key,
          error: reason
        })
      ]
    }
  end

  defp denied_status(permission_decision, :permission_denied),
    do: PermissionGate.response_status(permission_decision)

  defp denied_status(_permission_decision, _reason), do: :denied

  defp action(status, permission_decision, metadata) do
    %{
      name: "configure_channel_setting",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end

  # Never carries `audit?: false`, so the channels.* write is audited on the spine.
  defp action_context(context, permission_decision) do
    request_context = Map.get(context, :request, context)

    request_context
    |> Map.take([:actor, :operator_id, :channel, :input_signal_id])
    |> Map.new(fn
      {:operator_id, value} -> {:actor, value}
      {:input_signal_id, value} -> {:source_signal_id, value}
      other -> other
    end)
    |> Map.put(:permission_decision, permission_decision)
  end
end
