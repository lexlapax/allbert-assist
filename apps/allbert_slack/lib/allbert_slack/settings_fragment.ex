defmodule AllbertSlack.SettingsFragment do
  @moduledoc """
  Pack `FragmentOwner` for the Allbert Slack Channel.

  Derived from `AllbertSlack.Settings.Fragment`, which already held the schema and
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
    (AllbertSlack.Settings.Fragment.settings_schema() ++ Notify.settings_schema("slack"))
    |> Enum.filter(&Map.has_key?(&1, :default))
    # A FragmentOwner entry must state writability and sensitivity explicitly;
    # the plugin-path schema left them implicit and composition rejects that with
    # :missing_writable. Defaults match what the plugin path assumed.
    |> Enum.map(&Map.merge(%{writable?: true, sensitive?: false}, &1))
    # `:description` is a plugin-schema affordance the fragment contract does not
    # accept; carrying it through fails composition with "unknown settings schema
    # entry fields". Dropped here rather than deleted from the source schema,
    # which the operator-facing settings surface still reads.
    |> Enum.map(&Map.delete(&1, :description))
  end

  @impl true
  def safe_write_rows do
    entries()
    |> Enum.filter(&Map.get(&1, :writable?, true))
    |> Enum.with_index(692)
    |> Enum.map(fn {entry, index} -> {index, entry.key} end)
  end

  @impl true
  @spec fragment() :: Fragment.t()
  def fragment do
    schema = Map.new(entries(), fn %{key: key} = entry -> {key, entry_fields(entry)} end)

    Fragment.new!(%{
      id: "plugin:allbert.slack",
      owner: "allbert.slack",
      source: :plugin,
      group: :plugins,
      schema: schema,
      defaults: defaults(schema),
      safe_write_keys: Enum.map(safe_write_rows(), &elem(&1, 1)),
      metadata: %{display_name: "Allbert Slack Channel", trust_status: :trusted, source: :shipped}
    })
  end

  defp defaults(schema) do
    Enum.reduce(schema, %{}, fn {key, entry}, acc ->
      SettingsSchema.put_dotted(acc, key, Map.fetch!(entry, :default))
    end)
  end

  # The fragment contract accepts a closed field set and rejects anything else
  # with "unknown settings schema entry fields". Plugin-path schemas carry extras
  # -- `:description` most often -- so project onto the accepted set rather than
  # deleting whichever key happened to fail first.
  defp entry_fields(entry) do
    Map.take(entry, [:type, :default, :writable?, :sensitive?, :allowed_values, :min, :max])
  end
end
