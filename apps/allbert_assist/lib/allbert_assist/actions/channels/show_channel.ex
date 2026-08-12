defmodule AllbertAssist.Actions.Channels.ShowChannel do
  @moduledoc false

  use AllbertAssist.Action,
    registry_order: 30,
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
  alias AllbertAssist.Security

  @impl true
  def run(%{channel: channel}, context) do
    permission_decision = Security.authorize(:read_only, context)

    with true <- Security.allowed?(permission_decision),
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
    permission_decision = Security.authorize(:read_only, context)
    denied(nil, permission_decision, :invalid_params)
  end

  defp detail("telegram", settings, summary) do
    %{
      channel: "telegram",
      provider: "telegram_bot_api",
      release_status: summary.release_status,
      release_decision: summary.release_decision,
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
      release_status: summary.release_status,
      release_decision: summary.release_decision,
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
      release_status: summary.release_status,
      release_decision: summary.release_decision,
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
      doctor: doctor_state("discord"),
      last_event: summary.last_event
    }
  end

  defp detail("slack", settings, summary) do
    %{
      channel: "slack",
      provider: "slack_socket_mode",
      release_status: summary.release_status,
      release_decision: summary.release_decision,
      enabled: Map.get(settings, "enabled", false),
      response_style: Map.get(settings, "response_style"),
      workspace_team_id: Map.get(settings, "workspace_team_id"),
      allowed_channel_count: length(Map.get(settings, "allowed_channel_ids", [])),
      identity_count: length(Map.get(settings, "identity_map", [])),
      socket_mode: get_in(settings, ["socket_mode", "enabled"]),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      render_approval_buttons: Map.get(settings, "render_approval_buttons"),
      credential_status: summary.credential_status,
      doctor: doctor_state("slack"),
      last_event: summary.last_event
    }
  end

  defp detail("matrix", settings, summary) do
    %{
      channel: "matrix",
      provider: "matrix_client_server",
      release_status: summary.release_status,
      release_decision: summary.release_decision,
      enabled: Map.get(settings, "enabled", false),
      homeserver_url: Map.get(settings, "homeserver_url"),
      allowed_room_count: length(Map.get(settings, "allowed_room_ids", [])),
      identity_count: length(Map.get(settings, "identity_map", [])),
      sync_poll_interval_ms: Map.get(settings, "sync_poll_interval_ms"),
      sync_timeout_ms: Map.get(settings, "sync_timeout_ms"),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      credential_status: summary.credential_status,
      doctor: doctor_state("matrix"),
      last_event: summary.last_event
    }
  end

  defp detail("whatsapp", settings, summary) do
    %{
      channel: "whatsapp",
      provider: "whatsapp_cloud_api",
      release_status: summary.release_status,
      release_decision: summary.release_decision,
      enabled: Map.get(settings, "enabled", false),
      webhook_enabled: Map.get(settings, "webhook_enabled", false),
      phone_number_id: Map.get(settings, "phone_number_id"),
      waba_id: Map.get(settings, "waba_id"),
      identity_count: length(Map.get(settings, "identity_map", [])),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      render_approval_buttons: Map.get(settings, "render_approval_buttons"),
      quote_ttl_ms: Map.get(settings, "quote_ttl_ms"),
      credential_status: summary.credential_status,
      doctor: doctor_state("whatsapp"),
      last_event: summary.last_event
    }
  end

  defp detail("signal", settings, summary) do
    %{
      channel: "signal",
      provider: "signal_cli_jsonrpc",
      release_status: summary.release_status,
      release_decision: summary.release_decision,
      enabled: Map.get(settings, "enabled", false),
      account_configured: configured?(Map.get(settings, "account_identifier")),
      local_aci_configured: configured?(Map.get(settings, "local_aci")),
      control_mode: Map.get(settings, "control_mode"),
      identity_count: length(Map.get(settings, "identity_map", [])),
      allowed_aci_count: length(Map.get(settings, "allowed_aci_ids", [])),
      max_text_bytes: Map.get(settings, "max_text_bytes"),
      credential_status: summary.credential_status,
      doctor: doctor_state("signal"),
      last_event: summary.last_event
    }
  end

  defp detail(channel, settings, summary) do
    %{
      channel: channel,
      provider: summary.provider,
      release_status: summary.release_status,
      release_decision: summary.release_decision,
      enabled: Map.get(settings, "enabled", false),
      identity_count: length(Map.get(settings, "identity_map", [])),
      credential_status: summary.credential_status,
      last_event: summary.last_event
    }
  end

  defp message(detail) do
    """
    Channel #{detail.channel}: #{detail.provider}
    Release status: #{detail.release_status}
    Release decision: #{detail.release_decision.decision}
    Enabled: #{detail.enabled}
    Identities: #{detail.identity_count}
    Credentials: #{inspect(detail.credential_status)}
    Last event: #{inspect(detail.last_event)}
    """
    |> String.trim()
  end

  # v1.4 M13 extracted every channel plugin into its own pack; the R0 frozen
  # DAG forbids the residual from referencing a pack module at compile time,
  # so the doctor module can no longer be named by alias here. Each pack now
  # publishes its doctor through the `doctor:` key on the `channels/0`
  # descriptor it registers (see `AllbertDiscord.Plugin.channels/0` and its
  # siblings), and this resolves that module at runtime the same way
  # `AllbertAssist.CLI.PackGroups` resolves a pack's `cli_groups/0` module.
  # A channel with no `doctor:` key (telegram, email, and any future channel
  # that never registers one) degrades to the same "not_run" reading a
  # missing doctor run produces today -- this does not add a new state.
  defp doctor_state(channel) do
    with {:ok, descriptor} <- Channels.channel_descriptor(channel),
         module when is_atom(module) and not is_nil(module) <- Map.get(descriptor, :doctor),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :read_state, 0) do
      case module.read_state() do
        {:ok, state} -> state
        {:error, :not_found} -> %{"status" => "not_run"}
      end
    else
      _other -> %{"status" => "not_run"}
    end
  end

  defp configured?(value), do: is_binary(value) and String.trim(value) != ""

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
