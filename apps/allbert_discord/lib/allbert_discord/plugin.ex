defmodule AllbertDiscord.Plugin do
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
        adapter: AllbertDiscord.Adapter,
        doctor: AllbertDiscord.Doctor,
        child_spec: {AllbertDiscord.Adapter, []},
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
        streaming: :progress_messages,
        status_update_mode: :edit_in_place,
        trust_class: :server_readable,
        can_create_thread: false,
        reply_key_type: :opaque_id,
        quote_ttl_ms: 86_400_000,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled,
        # v1.4 M13: this pack is `native_effectful` (catalog.json) and starts
        # its own adapter through AllbertDiscord.EffectSupervisor. Tells the
        # residual's aggregate AllbertAssist.Channels.channel_child_specs/1 to
        # skip this descriptor so the adapter is never started twice.
        supervised_by: :pack
      }
    ]
  end

  @impl true
  def actions, do: [AllbertDiscord.Actions.Doctor]

  @impl true
  # v1.4 M13: settings ownership moved to the pack FragmentOwner.
  def settings_schema, do: []
end
