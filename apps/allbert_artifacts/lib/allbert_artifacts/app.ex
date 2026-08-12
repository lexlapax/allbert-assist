defmodule AllbertArtifacts.App do
  @moduledoc """
  App contract for the Artifacts Browser sidecar.

  The app is a plugin-owned read surface over the v0.50 core artifact actions.
  It contributes no artifact store internals and no new authority.
  """

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertArtifacts.Panels.Browser

  @impl true
  def app_id, do: :allbert_artifacts

  @impl true
  def display_name, do: "Artifacts"

  @impl true
  def version, do: "0.50.1"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def surfaces, do: [Browser.surface([])]

  def workspace_panel_surfaces(context) when is_map(context),
    do: AllbertArtifacts.SurfaceProvider.workspace_panel_surfaces(context)

  def surface_catalog, do: []

  def fallback_surface(:artifacts_browser_panel), do: {:ok, Browser.fallback_text()}
  def fallback_surface(_surface_id), do: {:error, :not_found}
end
