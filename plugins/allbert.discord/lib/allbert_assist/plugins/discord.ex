defmodule AllbertAssist.Plugins.Discord do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.discord"

  @impl true
  def display_name, do: "Allbert Discord Channel"

  @impl true
  def version, do: "0.52.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "discord",
        provider: "discord_gateway",
        adapter: AllbertAssist.Channels.Discord.Adapter,
        child_spec: {AllbertAssist.Channels.Discord.Adapter, []},
        secret_refs: ["channels.discord.bot_token_ref"],
        summary_fields: [
          "enabled",
          "response_style",
          "application_id",
          "allowed_guild_ids",
          "allowed_channel_ids"
        ],
        settings_prefix: "channels.discord",
        identity_map_key: "channels.discord.identity_map",
        session_strategy: {:discord_native_thread, prefix: "ch_di_"},
        primitives: [:button, :typed_command, :list],
        threading: :native_threads,
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
  def actions, do: [AllbertAssist.Actions.Channels.DiscordDoctor]

  @impl true
  def settings_schema, do: AllbertDiscord.Settings.Fragment.settings_schema()
end
