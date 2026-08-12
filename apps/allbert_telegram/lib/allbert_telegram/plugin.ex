defmodule AllbertTelegram.Plugin do
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
        adapter: AllbertTelegram.Adapter,
        child_spec: {AllbertTelegram.Adapter, []},
        secret_refs: ["channels.telegram.bot_token_ref"],
        summary_fields: ["enabled", "response_style", "allowed_chat_ids", "allow_group_chats"],
        settings_prefix: "channels.telegram",
        identity_map_key: "channels.telegram.identity_map",
        session_strategy: {:telegram_chat, prefix: "ch_tg_"},
        primitives: [:button, :typed_command, :list],
        threading: :reply_chain,
        streaming: :progress_messages,
        status_update_mode: :edit_in_place,
        trust_class: :server_readable,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def actions, do: [AllbertTelegram.Actions.Doctor]

  # v1.4 M12: settings ownership moved to AllbertTelegram.SettingsFragment (a
  # pack FragmentOwner, declared by AllbertTelegram.Pack.settings_fragments/0),
  # which is why this returns []: AllbertAssist.Settings.Fragments.
  # plugin_fragments/1 rejects an empty schema rather than producing a second,
  # duplicate "plugin:allbert.telegram" fragment.
  #
  # The two base-key entries this used to declare -- "channels.telegram.enabled"
  # and "channels.telegram.bot_token_ref" -- are gone, not moved: they never
  # reached the composed schema in the first place.
  # AllbertAssist.Settings.Schema.normalize_schema_entry/1 silently drops any
  # plugin schema entry without a `:default`, and neither of those two carried
  # one. Core already owns both keys, with defaults, through
  # AllbertAssist.Settings.FragmentOwners.Channels. Adding a `:default` here
  # later would make the entry reach composition and collide with that core
  # claim -- AllbertAssist.Settings.Fragments.unique_fragment_keys/1 rejects a
  # key claimed twice as :duplicate_settings_key. The remaining 3 keys (the
  # `autonomous_notify.*` triple, which DID always reach composition) now live
  # in AllbertTelegram.SettingsFragment instead.
  @impl true
  def settings_schema, do: []
end
