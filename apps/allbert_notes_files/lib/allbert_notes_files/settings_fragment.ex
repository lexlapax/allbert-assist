defmodule AllbertNotesFiles.SettingsFragment do
  @moduledoc """
  Settings fragment for the v0.42 notes/files reference app.

  A pack `FragmentOwner` since v1.4 M9: the pack answers for its own settings
  rather than contributing through the App path. `resolve_pack/3` runs an exact
  OTP-module census of `:allbert_notes_files` against the pack's declaration, so
  this module must be listed by `AllbertNotesFiles.Pack.settings_fragments/0`
  and nowhere else. The remaining owner callbacks are optional and unused here.

  The `id`, `owner`, and key namespace below are literals rather than anything
  derived from a path or from where the plugin registers, which is why the move
  preserves stored identity without a migration.
  """

  @behaviour AllbertAssist.Settings.FragmentOwner

  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Schema

  @entries [
    %{
      key: "apps.notes_files.notes_root",
      type: :string,
      default: "<ALLBERT_HOME>/notes",
      description: "Root directory for notes/files plugin reads and confirmed writes."
    },
    %{
      key: "apps.notes_files.max_results",
      type: :positive_integer,
      default: 25,
      description: "Maximum notes returned by search_notes and workspace panels."
    }
  ]

  def entries, do: @entries

  # A pack FragmentOwner must declare safe-write rows: the composition path
  # requires the callback even though the behaviour marks it optional, and
  # rejects the pack with :missing_settings_safe_write_rows without it. The keys
  # must exactly equal the fragment's safe_write_keys. Indices continue the
  # global sequence the residual owners use, which ends at 472.
  @safe_write_rows [
    {473, "apps.notes_files.notes_root"},
    {474, "apps.notes_files.max_results"}
  ]

  @impl true
  def safe_write_rows, do: @safe_write_rows

  @impl true
  @spec fragment() :: Fragment.t()
  def fragment do
    schema =
      Map.new(@entries, fn entry ->
        {entry.key,
         %{
           type: entry.type,
           default: entry.default,
           writable?: true,
           sensitive?: false
         }}
      end)

    Fragment.new!(%{
      id: "app:notes_files",
      owner: :notes_files,
      source: :app,
      group: :apps,
      schema: schema,
      defaults: defaults(schema),
      safe_write_keys: Map.keys(schema),
      metadata: %{display_name: "Allbert Notes/Files", reference_scaffold?: true}
    })
  end

  defp defaults(schema) do
    Enum.reduce(schema, %{}, fn {key, entry}, acc ->
      Schema.put_dotted(acc, key, Map.fetch!(entry, :default))
    end)
  end
end
