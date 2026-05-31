defmodule AllbertNotesFiles.SettingsFragment do
  @moduledoc """
  Settings fragment for the v0.42 notes/files reference app.
  """

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
