defmodule AllbertAssist.Workspace.DiscoverySuggestions do
  @moduledoc """
  Passive workspace panel for inert MCP discovery suggestions.
  """

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Tools.Discovery

  @surface_id :core_discovery_suggestions_panel
  @max_suggestions 8

  @doc "Build the host-owned Discovery Suggestions workspace panel."
  def surface(_context \\ %{}) do
    suggestions = pending_suggestions()

    %Surface{
      id: @surface_id,
      app_id: :allbert,
      label: "Discovery Suggestions",
      path: "/workspace",
      kind: :panel,
      zone: :canvas_panels,
      status: :available,
      nodes: [panel_node(suggestions)],
      fallback_text: "Discovery suggestions are available in the workspace.",
      metadata: %{visible_when: :operator_opened, order: 15}
    }
  end

  defp pending_suggestions do
    Discovery.list_suggestions(status: "pending", limit: @max_suggestions)
  rescue
    _error in [DBConnection.OwnershipError, DBConnection.ConnectionError] -> []
  end

  defp panel_node([]) do
    %Node{
      id: "core-discovery-suggestions",
      component: :panel,
      props: %{
        title: "Discovery Suggestions",
        body: "No pending discovery suggestions."
      },
      children: [
        %Node{
          id: "core-discovery-suggestions-empty",
          component: :empty_state,
          props: %{
            title: "No pending suggestions",
            body: "Scans have not recorded any pending MCP candidates."
          }
        }
      ]
    }
  end

  defp panel_node(suggestions) do
    %Node{
      id: "core-discovery-suggestions",
      component: :panel,
      props: %{
        title: "Discovery Suggestions",
        body: "#{length(suggestions)} pending MCP candidate(s)."
      },
      children: Enum.flat_map(suggestions, &suggestion_nodes/1)
    }
  end

  defp suggestion_nodes(suggestion) do
    candidate = field(suggestion, :candidate_snapshot, %{})
    evaluation = field(suggestion, :evaluation_snapshot, %{})
    candidate_id = field(suggestion, :candidate_id)
    node_id = safe_id(candidate_id)

    [
      %Node{
        id: "discovery-suggestion-#{node_id}",
        component: :settings_card,
        props: %{
          title: field(candidate, :name, candidate_id),
          body: field(candidate, :description, "Remote MCP server candidate."),
          status: field(suggestion, :status, "pending"),
          external_id: candidate_id
        }
      },
      %Node{
        id: "discovery-suggestion-#{node_id}-metadata",
        component: :status_badge,
        props: %{
          title: "Discovery metadata",
          body: suggestion_badge_text(candidate, evaluation),
          status: "info"
        }
      },
      %Node{
        id: "discovery-suggestion-#{node_id}-connect",
        component: :action_button,
        props: %{
          title: "Connect",
          phx_click: "connect_discovery_candidate",
          candidate_id: candidate_id,
          action_name: "mcp_server_connect"
        }
      }
    ]
  end

  defp suggestion_badge_text(candidate, evaluation) do
    [
      field(candidate, :source),
      field(candidate, :requires),
      field(evaluation, :health_status)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" / ")
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp blank?(value), do: value in [nil, ""]

  defp safe_id(value) do
    raw = to_string(value)

    slug =
      raw
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.:-]/, "-")
      |> String.trim("-")
      |> String.slice(0, 23)

    hash =
      raw
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    case slug do
      "" -> "candidate-#{hash}"
      slug -> "#{slug}-#{hash}"
    end
  end
end
