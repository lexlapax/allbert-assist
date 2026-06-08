defmodule AllbertArtifacts.Panels.Browser do
  @moduledoc """
  Workspace panel for browsing Artifacts Central metadata.
  """

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  @panel_id :artifacts_browser_panel

  def panel_id, do: @panel_id

  def surface(artifacts) when is_list(artifacts) do
    panel(
      :available,
      "Artifacts",
      "Recent Artifacts Central metadata.",
      artifact_nodes(artifacts)
    )
  end

  def unavailable(response) do
    reason =
      response
      |> Map.get(:error, :unavailable)
      |> Redactor.redact()
      |> inspect()

    panel(:available, "Artifacts", "Artifacts metadata is unavailable.", [
      %Node{
        id: "artifacts-browser-unavailable",
        component: :empty_state,
        props: %{
          title: "Artifacts unavailable",
          body: "Artifact metadata cannot be listed: #{reason}"
        }
      }
    ])
  end

  def fallback_text, do: "Artifacts are available from the Artifacts workspace panel."

  defp panel(status, title, body, children) do
    %Surface{
      id: @panel_id,
      app_id: :allbert_artifacts,
      label: "Artifacts",
      path: "/workspace",
      kind: :panel,
      zone: :canvas_panels,
      status: status,
      nodes: [
        %Node{
          id: "artifacts-browser-root",
          component: :panel,
          props: %{title: title, body: body, status: "metadata-only"},
          children: children
        }
      ],
      fallback_text: fallback_text(),
      metadata: %{zone: :canvas_panels, visible_when: :operator_opened, order: 90}
    }
  end

  defp artifact_nodes([]) do
    [
      %Node{
        id: "artifacts-browser-empty",
        component: :empty_state,
        props: %{
          title: "No artifacts",
          body: "Retained artifacts appear here after Artifacts Central stores them."
        }
      }
    ]
  end

  defp artifact_nodes(artifacts) do
    artifacts
    |> Enum.take(6)
    |> Enum.with_index()
    |> Enum.map(fn {artifact, index} -> artifact_node(artifact, index) end)
  end

  defp artifact_node(artifact, index) do
    sha256 = safe_string(Map.get(artifact, :sha256) || metadata_value(artifact, :sha256))
    metadata = Map.get(artifact, :metadata, %{})

    %Node{
      id: "artifact-row-#{index}",
      component: :section,
      props: %{
        title: artifact_title(metadata, sha256),
        body: artifact_body(metadata, sha256),
        status: safe_string(metadata_value(metadata, :lifecycle, "active"))
      },
      children: []
    }
  end

  defp artifact_title(metadata, sha256) do
    mime = metadata_value(metadata, :mime, "artifact")
    short_sha = String.slice(sha256, 0, 12)
    "#{safe_string(mime)} #{short_sha}"
  end

  defp artifact_body(metadata, sha256) do
    [
      "sha=#{String.slice(sha256, 0, 12)}",
      "bytes=#{metadata_value(metadata, :byte_size, "unknown")}",
      "origin=#{metadata_value(metadata, :origin, "unknown")}",
      "retention=#{metadata_value(metadata, :retention, "unknown")}",
      "created=#{metadata_value(metadata, :created_at, "unknown")}",
      "lifecycle=#{metadata_value(metadata, :lifecycle, "unknown")}",
      "redaction=#{metadata_value(metadata, :redaction_status, "metadata_only")}"
    ]
    |> Enum.map(&safe_string/1)
    |> Enum.join(" | ")
  end

  defp metadata_value(metadata, key, default \\ nil)

  defp metadata_value(metadata, key, default) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key)) || default
  end

  defp metadata_value(_metadata, _key, default), do: default

  defp safe_string(value) do
    value
    |> Redactor.redact()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 180)
  end
end
