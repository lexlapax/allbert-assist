defmodule AllbertAssist.Plugins.Telegram do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.telegram"

  @impl true
  def display_name, do: "Allbert Telegram Channel"

  @impl true
  def version, do: "0.17.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "telegram",
        provider: "telegram_bot_api",
        adapter: AllbertAssist.Channels.Telegram.Adapter,
        child_spec: {AllbertAssist.Channels.Telegram.Adapter, []},
        secret_refs: ["channels.telegram.bot_token_ref"],
        summary_fields: ["enabled", "response_style", "allowed_chat_ids", "allow_group_chats"],
        settings_prefix: "channels.telegram",
        identity_map_key: "channels.telegram.identity_map",
        session_strategy: {:telegram_chat, prefix: "ch_tg_"},
        primitives: [:button, :typed_command, :list],
        threading: :reply_chain,
        trust_class: :server_readable,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def settings_schema do
    [
      %{key: "channels.telegram.enabled", type: :boolean},
      %{key: "channels.telegram.bot_token_ref", type: :channel_secret_ref}
    ]
  end
end
