defmodule AllbertAssist.Plugins.WhatsApp do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.whatsapp"

  @impl true
  def display_name, do: "Allbert WhatsApp Channel"

  @impl true
  def version, do: "0.53.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "whatsapp",
        provider: "whatsapp_cloud_api",
        adapter: AllbertAssist.Channels.WhatsApp.Adapter,
        child_spec: {AllbertAssist.Channels.WhatsApp.Adapter, []},
        secret_refs: [
          "channels.whatsapp.access_token_ref",
          "channels.whatsapp.app_secret_ref",
          "channels.whatsapp.webhook_verify_token_ref"
        ],
        summary_fields: ["enabled", "webhook_enabled", "phone_number_id", "waba_id"],
        settings_prefix: "channels.whatsapp",
        identity_map_key: "channels.whatsapp.identity_map",
        session_strategy: {:whatsapp_direct, prefix: "ch_wa_"},
        primitives: [:button, :typed_command, :link, :list],
        threading: :reply_chain,
        trust_class: :server_readable,
        can_create_thread: false,
        reply_key_type: :opaque_id,
        quote_ttl_ms: 86_400_000,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def actions, do: [AllbertAssist.Actions.Channels.WhatsAppDoctor]

  @impl true
  def settings_schema, do: AllbertWhatsApp.Settings.Fragment.settings_schema()
end
