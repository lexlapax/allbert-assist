defmodule AllbertAssist.Actions.Channels.ConfigureChannelSecret do
  @moduledoc """
  v0.62 M8.15 — route per-provider channel credential setup onto the one action
  spine.

  Credential setup that writes an encrypted secret **and** its Settings Central
  reference (Telegram/Matrix/WhatsApp tokens, email IMAP/SMTP passwords) runs
  here so the write is gated by `:settings_secret_write` and audited through the
  Runner instead of a direct store call. The raw credential is accepted only as
  an action param; it is never rendered, logged, or echoed — the encrypted store
  and audit records keep only the reference name and status.
  """

  use AllbertAssist.Action,
    permission: :settings_secret_write,
    exposure: :internal,
    execution_mode: :channel_config_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "configure_channel_secret",
    description:
      "Store a channel credential secret and its settings reference (gated + audited).",
    category: "channels",
    tags: ["channels", "settings", "secrets"],
    schema: [
      channel: [type: :string, required: true],
      credential: [type: :string, required: true],
      # `secret_value` (not `value`): the "secret" key fragment triggers the
      # Runner's signal redaction so the raw credential never reaches logs/traces.
      secret_value: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      secret: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  # {channel, credential} => {secret_ref, settings-reference key}. The action is
  # the single spine boundary for these credential writes, so the ref/key mapping
  # lives here rather than being supplied (and trusted) by the caller.
  @credentials %{
    {"telegram", "bot_token"} =>
      {"secret://channels/telegram/bot_token", "channels.telegram.bot_token_ref"},
    {"matrix", "access_token"} =>
      {"secret://channels/matrix/access_token", "channels.matrix.access_token_ref"},
    {"whatsapp", "access_token"} =>
      {"secret://channels/whatsapp/access_token", "channels.whatsapp.access_token_ref"},
    {"email", "imap_password"} =>
      {"secret://channels/email/imap_password", "channels.email.imap_password_ref"},
    {"email", "smtp_password"} =>
      {"secret://channels/email/smtp_password", "channels.email.smtp_password_ref"}
  }

  @impl true
  def run(%{channel: channel, credential: credential, secret_value: secret_value}, context)
      when is_binary(channel) and is_binary(credential) and is_binary(secret_value) do
    permission_decision = PermissionGate.authorize(:settings_secret_write, context)

    case Map.fetch(@credentials, {channel, credential}) do
      {:ok, {secret_ref, ref_key}} ->
        store(
          channel,
          credential,
          secret_ref,
          ref_key,
          secret_value,
          permission_decision,
          context
        )

      :error ->
        {:ok,
         denied(
           channel,
           credential,
           permission_decision,
           {:unknown_channel_credential, channel, credential}
         )}
    end
  end

  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_secret_write, context)

    {:ok,
     denied(
       Map.get(params, :channel),
       Map.get(params, :credential),
       permission_decision,
       :invalid_params
     )}
  end

  defp store(channel, credential, secret_ref, ref_key, secret_value, permission_decision, context) do
    write_context = action_context(context, permission_decision)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, _secret} <- Secrets.put_secret(secret_ref, secret_value, write_context),
         {:ok, _setting} <- Settings.put(ref_key, secret_ref, write_context) do
      {:ok,
       %{
         message: "Stored #{channel} #{credential}.",
         status: :completed,
         permission_decision: permission_decision,
         secret: %{
           channel: channel,
           credential: credential,
           secret_ref: secret_ref,
           status: :configured
         },
         actions: [
           action(:completed, permission_decision, %{
             channel: channel,
             credential: credential,
             secret_status: :redacted
           })
         ]
       }}
    else
      false -> {:ok, denied(channel, credential, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(channel, credential, permission_decision, reason)}
    end
  end

  defp denied(channel, credential, permission_decision, reason) do
    %{
      message: "I could not store the #{channel} #{credential} credential: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [
        action(:denied, permission_decision, %{
          channel: channel,
          credential: credential,
          secret_status: :redacted,
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
      name: "configure_channel_secret",
      status: status,
      permission: :settings_secret_write,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end

  # Never carries `audit?: false`, so the credential-reference write is audited on
  # the spine. The secret value is never placed in the context.
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
