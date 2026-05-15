defmodule AllbertAssist.Plugins.Email do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.email"

  @impl true
  def display_name, do: "Allbert Email Channel"

  @impl true
  def version, do: "0.17.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "email",
        provider: "email_imap",
        adapter: AllbertAssist.Channels.Email.Adapter,
        child_spec: {AllbertAssist.Channels.Email.Adapter, []},
        secret_refs: [
          "channels.email.imap_password_ref",
          "channels.email.smtp_password_ref"
        ],
        summary_fields: ["enabled", "response_style", "imap_host", "smtp_host", "from_address"],
        settings_prefix: "channels.email",
        identity_map_key: "channels.email.identity_map",
        session_strategy: {:email_sender, prefix: "ch_em_"},
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def settings_schema do
    [
      %{key: "channels.email.enabled", type: :boolean},
      %{key: "channels.email.imap_password_ref", type: :channel_secret_ref},
      %{key: "channels.email.smtp_password_ref", type: :channel_secret_ref}
    ]
  end
end
