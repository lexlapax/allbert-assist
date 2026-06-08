defmodule AllbertBrowser.Plugin do
  @moduledoc """
  Shipped v0.43 browser/web-research plugin.

  The plugin contributes the `browser.*` Settings Central schema, registered
  browser actions, workspace surfaces, and the supervised browser session
  runtime. Operational control is through the reviewed Playwright/Chromium
  bridge; deterministic release tests use the stub driver.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.browser"

  @impl true
  def display_name, do: "Allbert Browser"

  @impl true
  def version, do: "0.43.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def apps, do: [AllbertBrowser.App]

  @impl true
  def actions do
    [
      AllbertBrowser.Actions.Doctor,
      AllbertBrowser.Actions.StartSession,
      AllbertBrowser.Actions.Navigate,
      AllbertBrowser.Actions.Extract,
      AllbertBrowser.Actions.Screenshot,
      AllbertBrowser.Actions.AnalyzeScreenshot,
      AllbertBrowser.Actions.Click,
      AllbertBrowser.Actions.Fill,
      AllbertBrowser.Actions.Download,
      AllbertBrowser.Actions.ListSessions,
      AllbertBrowser.Actions.CloseSession,
      AllbertBrowser.Actions.SweepCache,
      AllbertBrowser.Actions.ResearchHandoff
    ]
  end

  @impl true
  def child_spec(_opts), do: AllbertBrowser.Supervisor.child_spec([])

  @impl true
  def settings_schema do
    [
      schema("browser.enabled", :boolean, false),
      schema("browser.driver.kind", :enum, "playwright_chromium",
        writable?: false,
        allowed_values: ["playwright_chromium"]
      ),
      schema("browser.driver.node_path", :string_or_nil, nil),
      schema("browser.driver.binary_path", :string_or_nil, nil),
      schema("browser.driver.version_pin", :string_or_nil, nil),
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
end
