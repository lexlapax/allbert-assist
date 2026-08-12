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
  # v1.4 M13: settings ownership moved to AllbertBrowser.SettingsFragment, a pack
  # FragmentOwner declared by AllbertBrowser.Pack.settings_fragments/0. Declaring
  # the same keys here as well would produce the fragment twice.
  def settings_schema, do: []
end
