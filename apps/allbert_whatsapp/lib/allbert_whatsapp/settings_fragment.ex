defmodule AllbertWhatsApp.SettingsFragment do
  @moduledoc """
  Pack `FragmentOwner` for the Allbert WhatsApp Channel.

  Derived from `AllbertWhatsApp.Settings.Fragment`, which already held the schema and
  remains its only definition, plus the shared autonomous-notify triple the
  channel contributes. Copying the entries instead would create a second literal
  that drifts.

  `id`, `owner` and `source` reproduce what
  `AllbertAssist.Settings.Fragments.plugin_fragments/1` produced from the plugin
  path, so stored identity survives the move without a migration.
  """

  @behaviour AllbertAssist.Settings.FragmentOwner

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Schema, as: SettingsSchema

  @doc "The channel's settings entries, in declaration order."
  def entries do
    (AllbertWhatsApp.Settings.Fragment.settings_schema() ++ Notify.settings_schema("whatsapp"))
    |> Enum.filter(&Map.has_key?(&1, :default))
  end

  @impl true
  def safe_write_rows do
    entries()
    |> Enum.filter(&Map.get(&1, :writable?, true))
    |> Enum.with_index(812)
    |> Enum.map(fn {entry, index} -> {index, entry.key} end)
  end

  @impl true
  @spec fragment() :: Fragment.t()
  def fragment do
    schema = Map.new(entries(), fn %{key: key} = entry -> {key, Map.delete(entry, :key)} end)

    Fragment.new!(%{
      id: "plugin:allbert.whatsapp",
      owner: "allbert.whatsapp",
      source: :plugin,
      group: :plugins,
      schema: schema,
      defaults: defaults(schema),
      safe_write_keys: Enum.map(safe_write_rows(), &elem(&1, 1)),
      metadata: %{display_name: "Allbert WhatsApp Channel", trust_status: :trusted, source: :shipped}
    })
  end

  defp defaults(schema) do
    Enum.reduce(schema, %{}, fn {key, entry}, acc ->
      SettingsSchema.put_dotted(acc, key, Map.fetch!(entry, :default))
    end)
  end
end
