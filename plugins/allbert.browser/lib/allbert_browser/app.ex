defmodule AllbertBrowser.App do
  @moduledoc false

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertBrowser.Cache

  @panel_id :browser_results_panel

  @impl true
  def app_id, do: :allbert_browser

  @impl true
  def display_name, do: "Browser"

  @impl true
  def version, do: "0.43.0"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def surfaces, do: [panel_surface(result_nodes([]))]

  def workspace_panel_surfaces(_context) do
    artifacts = Cache.latest_artifacts(limit: 6)
    [panel_surface(result_nodes(artifacts))]
  end

  def surface_catalog, do: []

  def fallback_surface(@panel_id),
    do: {:ok, "Browser results are available from the Browser workspace panel."}

  def fallback_surface(_surface_id), do: {:error, :not_found}

  defp panel_surface(children) do
    %Surface{
      id: @panel_id,
      app_id: :allbert_browser,
      label: "Browser results",
      path: "/workspace",
      kind: :panel,
      zone: :canvas_panels,
      status: :available,
      nodes: [
        %Node{
          id: "browser-results-root",
          component: :panel,
          props: %{title: "Browser results", body: "Rendered browser research evidence."},
          children: children
        }
      ],
      fallback_text: "Browser results are available from the Browser workspace panel.",
      metadata: %{zone: :canvas_panels, visible_when: :selected_app, order: 80}
    }
  end

  defp result_nodes([]) do
    [
      %Node{
        id: "browser-results-empty",
        component: :empty_state,
        props: %{
          title: "No browser results",
          body: "Browser evidence appears here after extraction."
        }
      }
    ]
  end

  defp result_nodes(artifacts) do
    artifacts
    |> Enum.with_index()
    |> Enum.map(fn {artifact, index} ->
      %Node{
        id: "browser-result-#{index}",
        component: :section,
        props: %{
          title: artifact_title(artifact),
          body: artifact_body(artifact),
          status: Map.get(artifact, :kind)
        },
        children: artifact_children(artifact, index)
      }
    end)
  end

  defp artifact_children(%{kind: "screenshot"} = artifact, index) do
    [
      %Node{
        id: "browser-result-link-#{index}",
        component: :link,
        props: %{title: "Open screenshot cache path", href: Map.get(artifact, :path)}
      }
    ]
  end

  defp artifact_children(%{preview: preview}, index) when is_binary(preview) and preview != "" do
    [
      %Node{
        id: "browser-result-text-#{index}",
        component: :text,
        props: %{body: preview}
      }
    ]
  end

  defp artifact_children(_artifact, _index), do: []

  defp artifact_title(artifact) do
    [Map.get(artifact, :kind, "artifact"), Map.get(artifact, :format)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp artifact_body(artifact) do
    [
      Map.get(artifact, :session_id),
      Map.get(artifact, :url),
      Map.get(artifact, :ref)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end
end
