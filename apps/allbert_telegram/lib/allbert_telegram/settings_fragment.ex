defmodule AllbertTelegram.SettingsFragment do
  @moduledoc """
  Settings fragment for the extracted Telegram channel plugin.

  A pack `FragmentOwner` since v1.4 M12, mirroring the move
  `AllbertNotesFiles.SettingsFragment` made at M9: the pack answers for its own
  settings rather than contributing through the Plugin path. `resolve_pack/3`
  runs an exact OTP-module census of `:allbert_telegram` against the pack's
  declaration, so this module must be listed by
  `AllbertTelegram.Pack.settings_fragments/0` and nowhere else.

  `id: "plugin:allbert.telegram"`, `owner: "allbert.telegram"` (the plugin_id
  string, not an atom — unlike `AllbertNotesFiles.SettingsFragment`, which is
  `source: :app` and therefore keyed by app-id atom), `source: :plugin`, and
  `group: :plugins` are the literals `AllbertAssist.Settings.Fragments.
  plugin_fragments/1` would have produced from the pre-M12 plugin-schema path.
  Reusing them here means stored identity survives the move without a
  migration.

  Only 3 keys live here. `AllbertTelegram.Plugin.settings_schema/0` used to
  declare 5: `channels.telegram.enabled` and `channels.telegram.bot_token_ref`
  never actually reached the composed schema, because
  `AllbertAssist.Settings.Schema.normalize_schema_entry/1` silently discards
  any plugin schema entry lacking a `:default` field, and those two entries
  never carried one — `channels.telegram.*` is owned, with defaults, by the
  core `AllbertAssist.Settings.FragmentOwners.Channels` fragment. Carrying
  those declarations forward here would not be a no-op: giving either a
  `:default` would make it reach composition and collide with the core
  fragment's claim on the same key, which
  `AllbertAssist.Settings.Fragments.unique_fragment_keys/1` (and, on the pack
  path, `FragmentOwner.resolve_pack/3`'s `unique_fragment_ids`/schema merge)
  rejects as `:duplicate_settings_key`. So they are deleted, not carried.

  The 3 keys that DO survive are exactly
  `AllbertAssist.Channels.Notify.settings_schema("telegram")`'s output —
  derived from that function directly, rather than copied as literals, so this
  fragment cannot drift from the shared schema it is required to match.
  """

  @behaviour AllbertAssist.Settings.FragmentOwner

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Schema

  # Inlined rather than a named helper: a module attribute is evaluated while
  # the module is still being defined, so it cannot call this module's own
  # functions.
  @entries "telegram"
           |> Notify.settings_schema()
           |> Enum.map(fn %{key: key} = entry ->
             {key, Map.merge(%{writable?: true, sensitive?: false}, Map.delete(entry, :key))}
           end)

  def entries, do: @entries

  # A pack FragmentOwner must declare safe-write rows: the composition path
  # requires the callback even though the behaviour marks it optional, and
  # rejects the pack with :missing_settings_safe_write_rows without it. The
  # keys must exactly equal the fragment's safe_write_keys. Indices continue
  # the global sequence notes_files left off at 474.
  @safe_write_rows [
    {475, "channels.telegram.autonomous_notify.enabled"},
    {476, "channels.telegram.autonomous_notify.level"},
    {477, "channels.telegram.autonomous_notify.min_interval_seconds"}
  ]

  @impl true
  def safe_write_rows, do: @safe_write_rows

  @impl true
  @spec fragment() :: Fragment.t()
  def fragment do
    schema = Map.new(@entries)

    Fragment.new!(%{
      id: "plugin:allbert.telegram",
      owner: "allbert.telegram",
      source: :plugin,
      group: :plugins,
      schema: schema,
      defaults: defaults(schema),
      safe_write_keys: Map.keys(schema),
      metadata: %{
        display_name: "Allbert Telegram Channel",
        trust_status: :trusted,
        source: :shipped
      }
    })
  end

  defp defaults(schema) do
    Enum.reduce(schema, %{}, fn {key, entry}, acc ->
      Schema.put_dotted(acc, key, Map.fetch!(entry, :default))
    end)
  end
end
