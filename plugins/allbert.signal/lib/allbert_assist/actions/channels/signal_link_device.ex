defmodule AllbertAssist.Actions.Channels.SignalLinkDevice do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :channel_setup,
    skill_backed?: false,
    confirmation: :required,
    name: "signal_link_device",
    description: "Request a signal-cli device-link QR payload through the local daemon.",
    category: "channels",
    tags: ["channels", "signal", "setup"],
    schema: [
      account: [type: :string, required: true],
      device_name: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Signal.Client
  alias AllbertAssist.Channels.Signal.Daemon
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{account: account} = params, context) when is_binary(account) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, settings} <- Channels.channel_settings("signal"),
         device_name <- Map.get(params, :device_name, "Allbert"),
         {:ok, result} <-
           Client.start_link_request(account, device_name, Daemon.client_opts(settings)) do
      {:ok, completed(result, permission_decision)}
    else
      false -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, failed(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    {:ok, failed(permission_decision, :invalid_params)}
  end

  defp completed(result, permission_decision) do
    link_data = Map.get(result, "linkData", Map.get(result, :linkData, ""))

    %{
      message: "Signal device link created.",
      status: :completed,
      link_data: link_data,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          link_data_present: link_data != ""
        })
      ]
    }
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      link_data: nil,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Signal device link failed.",
      status: :error,
      error: reason,
      link_data: nil,
      permission_decision: permission_decision,
      actions: [action(:error, permission_decision, %{error: inspect(reason)})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "signal_link_device",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end
end
