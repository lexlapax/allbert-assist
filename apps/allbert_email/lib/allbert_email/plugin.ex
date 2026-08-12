defmodule AllbertEmail.Plugin do
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
        adapter: AllbertEmail.Adapter,
        child_spec: {AllbertEmail.Adapter, []},
        secret_refs: [
          "channels.email.imap_password_ref",
          "channels.email.smtp_password_ref"
        ],
        summary_fields: ["enabled", "response_style", "imap_host", "smtp_host", "from_address"],
        settings_prefix: "channels.email",
        identity_map_key: "channels.email.identity_map",
        session_strategy: {:email_sender, prefix: "ch_em_"},
        primitives: [:typed_command, :list],
        threading: :reply_chain,
        streaming: :turn_complete,
        trust_class: :server_readable,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def actions, do: [AllbertEmail.Actions.Doctor]

  # v1.4 M12: settings ownership moved to AllbertEmail.SettingsFragment (a
  # pack FragmentOwner, declared by AllbertEmail.Pack.settings_fragments/0),
  # which is why this returns []: AllbertAssist.Settings.Fragments.
  # plugin_fragments/1 rejects an empty schema rather than producing a second,
  # duplicate "plugin:allbert.email" fragment.
  #
  # The three base-key entries this used to declare -- "channels.email.enabled",
  # "channels.email.imap_password_ref", and "channels.email.smtp_password_ref"
  # -- are gone, not moved: they never reached the composed schema in the first
  # place. AllbertAssist.Settings.Schema.normalize_schema_entry/1 silently
  # drops any plugin schema entry without a `:default`, and none of those three
  # carried one. Core already owns all three keys, with defaults, through
  # AllbertAssist.Settings.FragmentOwners.Channels. Adding a `:default` here
  # later would make the entry reach composition and collide with that core
  # claim -- AllbertAssist.Settings.Fragments.unique_fragment_keys/1 rejects a
  # key claimed twice as :duplicate_settings_key. The remaining 3 keys (the
  # `autonomous_notify.*` triple, which DID always reach composition) now live
  # in AllbertEmail.SettingsFragment instead.
  @impl true
  def settings_schema, do: []
end
