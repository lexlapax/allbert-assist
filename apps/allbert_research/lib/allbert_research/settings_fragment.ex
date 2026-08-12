defmodule AllbertResearch.SettingsFragment do
  @moduledoc """
  Pack `FragmentOwner` for the research delegate.

  A re-declaration rather than a reshape: `AllbertResearch.Settings.Fragment`
  already held the schema and is still its single source, so this owner derives
  from it instead of copying the entries. A second literal copy is exactly how
  the two drift.

  `id`, `owner` and `source` reproduce what
  `AllbertAssist.Settings.Fragments.plugin_fragments/1` produced from the plugin
  path before the move, so stored identity survives without a migration. `owner`
  is the plugin_id STRING, not an atom -- a plugin-sourced fragment resolves by
  owner id, unlike the app-sourced notes_files fragment.
  """

  @behaviour AllbertAssist.Settings.FragmentOwner

  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Schema
  alias AllbertResearch.Settings.Fragment, as: Source

  # Only writable keys are safe-write rows: `Fragments.safe_write_keys_from_schema/1`
  # filters on `writable?`, so `research.schema_version` and
  # `research.summary.engine` are deliberately absent. The indices continue the
  # global sequence, which email left at 480.
  @safe_write_rows [
    {481, "research.enabled"},
    {482, "research.max_sources"},
    {483, "research.max_extract_bytes_per_source"}
  ]

  @impl true
  def safe_write_rows, do: @safe_write_rows

  @impl true
  @spec fragment() :: Fragment.t()
  def fragment do
    schema =
      Map.new(Source.schema(), fn %{key: key} = entry ->
        {key, Map.delete(entry, :key)}
      end)

    Fragment.new!(%{
      id: "plugin:allbert.research",
      owner: "allbert.research",
      source: :plugin,
      group: :plugins,
      schema: schema,
      defaults: defaults(schema),
      safe_write_keys: Enum.map(@safe_write_rows, &elem(&1, 1)),
      metadata: %{
        display_name: "Allbert Research",
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
