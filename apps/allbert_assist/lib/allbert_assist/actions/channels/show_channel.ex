defmodule AllbertAssist.Actions.Channels.ShowChannel do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "show_channel",
    description: "Show one configured Allbert channel adapter.",
    category: "channels",
    tags: ["channels", "read_only"],
    schema: [channel: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Channels
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{channel: channel}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, settings} <- Channels.channel_settings(channel),
         summary <- Enum.find(Channels.list_channels(), &(&1.channel == channel)) do
      detail = detail(channel, settings, summary)

      {:ok,
       %{
         message: message(detail),
         status: :completed,
         channel: detail,
         actions: [action(:completed, permission_decision, %{channel: channel})]
       }}
    else
      false ->
        denied(channel, permission_decision, :permission_denied)

      {:error, :unknown_channel} ->
        not_found(channel, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    denied(nil, permission_decision, :invalid_params)
  end

  defp detail("telegram", settings, summary) do
    %{
      channel: "telegram",
      provider: "telegram_bot_api",
      enabled: Map.get(settings, "enabled", false),
      response_style: Map.get(settings, "response_style"),
      identity_count: length(Map.get(settings, "identity_map", [])),
      allowed_chat_count: length(Map.get(settings, "allowed_chat_ids", [])),
      allow_group_chats: Map.get(settings, "allow_group_chats", false),
      poll_interval_ms: Map.get(settings, "poll_interval_ms"),
      poll_timeout_seconds: Map.get(settings, "poll_timeout_seconds"),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      render_approval_buttons: Map.get(settings, "render_approval_buttons"),
      credential_status: summary.credential_status,
      last_event: summary.last_event
    }
  end

  defp detail("email", settings, summary) do
    %{
      channel: "email",
      provider: "email_imap",
      enabled: Map.get(settings, "enabled", false),
      response_style: Map.get(settings, "response_style"),
      imap_host: Map.get(settings, "imap_host"),
      imap_port: Map.get(settings, "imap_port"),
      imap_mailbox: Map.get(settings, "imap_mailbox"),
      smtp_host: Map.get(settings, "smtp_host"),
      smtp_port: Map.get(settings, "smtp_port"),
      from_address: Map.get(settings, "from_address"),
      identity_count: length(Map.get(settings, "identity_map", [])),
      imap_poll_interval_ms: Map.get(settings, "imap_poll_interval_ms"),
      max_body_bytes: Map.get(settings, "max_body_bytes"),
      allow_html_replies: Map.get(settings, "allow_html_replies"),
      credential_status: summary.credential_status,
      last_event: summary.last_event
    }
  end

  defp detail("discord", settings, summary) do
    %{
      channel: "discord",
      provider: "discord_gateway",
      enabled: Map.get(settings, "enabled", false),
      response_style: Map.get(settings, "response_style"),
      application_id: Map.get(settings, "application_id"),
      allowed_guild_count: length(Map.get(settings, "allowed_guild_ids", [])),
      allowed_channel_count: length(Map.get(settings, "allowed_channel_ids", [])),
      identity_count: length(Map.get(settings, "identity_map", [])),
      gateway_intents: Map.get(settings, "gateway_intents", []),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      render_approval_buttons: Map.get(settings, "render_approval_buttons"),
      credential_status: summary.credential_status,
      doctor: discord_doctor_state(),
      last_event: summary.last_event
    }
  end

  defp detail("slack", settings, summary) do
    %{
      channel: "slack",
      provider: "slack_socket_mode",
      enabled: Map.get(settings, "enabled", false),
      response_style: Map.get(settings, "response_style"),
      workspace_team_id: Map.get(settings, "workspace_team_id"),
      allowed_channel_count: length(Map.get(settings, "allowed_channel_ids", [])),
      identity_count: length(Map.get(settings, "identity_map", [])),
      socket_mode: get_in(settings, ["socket_mode", "enabled"]),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      render_approval_buttons: Map.get(settings, "render_approval_buttons"),
      credential_status: summary.credential_status,
      doctor: slack_doctor_state(),
      last_event: summary.last_event
    }
  end

  defp detail("matrix", settings, summary) do
    %{
      channel: "matrix",
      provider: "matrix_client_server",
      enabled: Map.get(settings, "enabled", false),
      homeserver_url: Map.get(settings, "homeserver_url"),
      allowed_room_count: length(Map.get(settings, "allowed_room_ids", [])),
      identity_count: length(Map.get(settings, "identity_map", [])),
      sync_poll_interval_ms: Map.get(settings, "sync_poll_interval_ms"),
      sync_timeout_ms: Map.get(settings, "sync_timeout_ms"),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      credential_status: summary.credential_status,
      doctor: matrix_doctor_state(),
      last_event: summary.last_event
    }
  end

  defp detail(channel, settings, summary) do
    %{
      channel: channel,
      provider: summary.provider,
      enabled: Map.get(settings, "enabled", false),
      identity_count: length(Map.get(settings, "identity_map", [])),
      credential_status: summary.credential_status,
      last_event: summary.last_event
    }
  end

  defp message(detail) do
    """
    Channel #{detail.channel}: #{detail.provider}
    Enabled: #{detail.enabled}
    Identities: #{detail.identity_count}
    Credentials: #{inspect(detail.credential_status)}
    Last event: #{inspect(detail.last_event)}
    """
    |> String.trim()
  end

  defp discord_doctor_state do
    case AllbertAssist.Channels.Discord.Doctor.read_state() do
      {:ok, state} -> state
      {:error, :not_found} -> %{"status" => "not_run"}
    end
  end

  defp slack_doctor_state do
    case AllbertAssist.Channels.Slack.Doctor.read_state() do
      {:ok, state} -> state
      {:error, :not_found} -> %{"status" => "not_run"}
    end
  end

  defp matrix_doctor_state do
    case AllbertAssist.Channels.Matrix.Doctor.read_state() do
      {:ok, state} -> state
      {:error, :not_found} -> %{"status" => "not_run"}
    end
  end

  defp denied(channel, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not show channel #{inspect(channel)}: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, %{channel: channel, error: reason})]
     }}
  end

  defp not_found(channel, permission_decision) do
    {:ok,
     %{
       message: "Channel not found: #{channel}",
       status: :not_found,
       error: :unknown_channel,
       actions: [
         action(:not_found, permission_decision, %{channel: channel, error: :unknown_channel})
       ]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "show_channel",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end
end
