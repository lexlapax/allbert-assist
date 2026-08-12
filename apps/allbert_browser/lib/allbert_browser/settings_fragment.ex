defmodule AllbertBrowser.SettingsFragment do
  @moduledoc """
  Pack `FragmentOwner` for the browser.

  The schema moved here wholesale rather than being derived: unlike research,
  which already had a dedicated `Settings.Fragment` module, the browser declared
  all 33 keys inline in `AllbertBrowser.Plugin.settings_schema/0`. Leaving them
  there and deriving would keep a plugin-path declaration alive purely as a data
  source, which is the shape M13 is removing.

  `id`, `owner` and `source` reproduce what
  `AllbertAssist.Settings.Fragments.plugin_fragments/1` produced before the move,
  so stored identity survives without a migration.
  """

  @behaviour AllbertAssist.Settings.FragmentOwner

  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Schema, as: SettingsSchema

  @doc "The browser settings entries, in declaration order."
  def entries do
    [
      schema("browser.enabled", :boolean, false),
      schema("browser.driver.kind", :enum, "playwright_chromium",
        writable?: false,
        allowed_values: ["playwright_chromium"]
      ),
      schema("browser.driver.node_path", :string_or_nil, nil),
      schema("browser.driver.node_module_path", :string_or_nil, nil),
      schema("browser.driver.binary_path", :string_or_nil, nil),
      schema("browser.driver.version_pin", :string_or_nil, nil),
      schema("browser.driver.host_resolver_rules", :string_or_nil, nil),
      schema("browser.session.max_concurrent", :bounded_integer, 1, min: 1, max: 1),
      schema("browser.session.max_lifetime_ms", :bounded_integer, 300_000,
        min: 1_000,
        max: 900_000
      ),
      schema("browser.session.idle_timeout_ms", :bounded_integer, 60_000,
        min: 1_000,
        max: 900_000
      ),
      schema("browser.session.max_pages", :bounded_integer, 20, min: 1, max: 100),
      schema("browser.session.headless", :boolean, true, writable?: false),
      schema("browser.session.profile_mode", :enum, "ephemeral",
        writable?: false,
        allowed_values: ["ephemeral"]
      ),
      schema("browser.session.javascript_enabled", :boolean, true),
      schema("browser.session.user_agent", :string, "AllbertBrowser/0.43 (+local research)"),
      schema("browser.navigation.allowed_domains", :string_list, []),
      schema("browser.navigation.denied_domains", :string_list, []),
      schema("browser.navigation.timeout_ms", :timeout_ms, 30_000),
      schema("browser.navigation.max_redirects", :bounded_integer, 0, min: 0, max: 3),
      schema("browser.navigation.subresource_cdn_allowlist", :string_list, []),
      schema("browser.extraction.max_bytes", :bounded_integer, 1_048_576,
        min: 1,
        max: 4_194_304
      ),
      schema("browser.extraction.pdf_max_pages", :bounded_integer, 50, min: 1, max: 100),
      schema("browser.extraction.pdf_parse_timeout_ms", :timeout_ms, 20_000),
      schema("browser.screenshot.max_bytes", :bounded_integer, 524_288,
        min: 1,
        max: 2_097_152
      ),
      schema("browser.screenshot.full_page", :boolean, false, writable?: false),
      schema("browser.screenshot.redact_credential_inputs", :boolean, true, writable?: false),
      schema("browser.form_fill.enabled", :boolean, false),
      schema("browser.download.enabled", :boolean, false),
      schema("browser.cache.max_bytes", :bounded_integer, 33_554_432,
        min: 1,
        max: 134_217_728
      ),
      schema("browser.cache.max_age_ms", :bounded_integer, 86_400_000,
        min: 1_000,
        max: 604_800_000
      ),
      schema("browser.cache.sweep.schedule", :enum, "paused",
        allowed_values: ["paused", "operator_approved"]
      ),
      schema("browser.doctor.max_age_ms", :bounded_integer, 86_400_000,
        min: 1_000,
        max: 604_800_000
      ),
      schema("browser.routing.dynamic_hosts", :string_list, [])
    ]
  end

  defp schema(key, type, default, opts \\ []) do
    %{
      key: key,
      type: type,
      default: default,
      writable?: Keyword.get(opts, :writable?, true),
      sensitive?: Keyword.get(opts, :sensitive?, false)
    }
    |> maybe_put(:allowed_values, Keyword.get(opts, :allowed_values))
    |> maybe_put(:min, Keyword.get(opts, :min))
    |> maybe_put(:max, Keyword.get(opts, :max))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Only writable keys are safe-write rows -- `writable?: false` entries are
  # excluded, matching `Fragments.safe_write_keys_from_schema/1`. Indices
  # continue the global sequence, which research left at 483.
  @impl true
  def safe_write_rows do
    entries()
    |> Enum.filter(&Map.get(&1, :writable?, true))
    |> Enum.with_index(484)
    |> Enum.map(fn {entry, index} -> {index, entry.key} end)
  end

  @impl true
  @spec fragment() :: Fragment.t()
  def fragment do
    schema = Map.new(entries(), fn %{key: key} = entry -> {key, entry_fields(entry)} end)

    Fragment.new!(%{
      id: "plugin:allbert.browser",
      owner: "allbert.browser",
      source: :plugin,
      group: :plugins,
      schema: schema,
      defaults: defaults(schema),
      safe_write_keys: Enum.map(safe_write_rows(), &elem(&1, 1)),
      metadata: %{
        display_name: "Allbert Browser",
        trust_status: :trusted,
        source: :shipped
      }
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
