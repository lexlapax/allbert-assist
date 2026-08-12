defmodule AllbertBrowser.Panels.Results do
  @moduledoc """
  Browser workspace results panel.
  """

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  @panel_id :browser_results_panel

  def panel_id, do: @panel_id

  def surface(artifacts) do
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
          children: result_nodes(artifacts)
        }
      ],
      fallback_text: fallback_text(),
      metadata: %{zone: :canvas_panels, visible_when: :operator_opened, order: 80}
    }
  end

  def fallback_text, do: "Browser results are available from the Browser workspace panel."

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
