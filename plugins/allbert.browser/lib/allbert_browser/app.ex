defmodule AllbertBrowser.App do
  @moduledoc false

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertBrowser.Panels.Results

  @impl true
  def app_id, do: :allbert_browser

  @impl true
  def display_name, do: "Browser"

  @impl true
  def version, do: "0.43.0"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def actions, do: [AllbertBrowser.Actions.ResearchHandoff]

  @impl AllbertAssist.App
  def surfaces, do: [Results.surface([])]

  def workspace_panel_surfaces(context), do: AllbertBrowser.SurfaceProvider.workspace_panel_surfaces(context)

  def surface_catalog, do: []

  def intent_descriptors do
    [
      %{
        app_id: :allbert_browser,
        action_name: "browser_research_handoff",
        label: "Browser research handoff",
        examples: [
          "research https://example.com",
          "research https://example.com and summarize",
          "summarize the page at https://example.com",
          "screenshot https://example.com",
          "what does https://example.com look like",
          "render https://example.com",
          "extract text from https://example.com",
          "extract html from https://example.com",
          "extract markdown from https://example.com",
          "extract pdf from https://example.com"
        ],
        synonyms: [
          "research",
          "summarize the page",
          "screenshot",
          "render",
          "extract text",
          "extract html",
          "extract markdown",
          "extract pdf"
        ],
        required_slots: [],
        handoff_required?: true
      }
    ]
  end

  def fallback_surface(:browser_results_panel), do: {:ok, Results.fallback_text()}

  def fallback_surface(_surface_id), do: {:error, :not_found}
end
