defmodule AllbertAssist.Workspace.DiscoverySuggestions do
  @moduledoc """
  Passive workspace panel for inert discovery and self-improvement suggestions.
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
    # F4: a one-off CLI command never renders this panel; skip the expire+SELECT at boot
    # (the surface keeps its id and renders the empty state, which the web re-renders live).
    if Application.get_env(:allbert_assist, :cli_oneshot?, false) do
      []
    else
      Discovery.list_suggestions(status: "pending", limit: @max_suggestions)
    end
  rescue
    _error in [DBConnection.OwnershipError, DBConnection.ConnectionError] -> []
  end

  defp panel_node([]) do
    %Node{
      id: "core-discovery-suggestions",
      component: :panel,
      props: %{
        title: "Discovery Suggestions",
        body: "No pending suggestions."
      },
      children: [
        %Node{
          id: "core-discovery-suggestions-empty",
          component: :empty_state,
          props: %{
            title: "No pending suggestions",
            body: "Scans have not recorded any pending suggestions."
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
        body: "#{length(suggestions)} pending suggestion(s)."
      },
      children: Enum.flat_map(suggestions, &suggestion_nodes/1)
    }
  end

  defp suggestion_nodes(suggestion) do
    case field(suggestion, :provenance, "discovery") do
      "self_improvement" -> self_improvement_suggestion_nodes(suggestion)
      _provenance -> mcp_suggestion_nodes(suggestion)
    end
  end

  defp mcp_suggestion_nodes(suggestion) do
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

  defp self_improvement_suggestion_nodes(suggestion) do
    metadata = field(suggestion, :metadata, %{})
    suggestion_id = field(suggestion, :id)
    suggestion_type = field(suggestion, :suggestion_type)
    node_id = safe_id(suggestion_id)
    draft_kind = field(metadata, :proposed_draft_kind)

    [
      %Node{
        id: "discovery-suggestion-#{node_id}",
        component: :settings_card,
        props: %{
          title: field(metadata, :title, humanize_type(suggestion_type)),
          body: field(metadata, :summary, "Self-improvement suggestion."),
          status: field(suggestion, :status, "pending"),
          suggestion_id: suggestion_id,
          suggestion_type: suggestion_type,
          proposed_draft_kind: draft_kind
        }
      },
      %Node{
        id: "discovery-suggestion-#{node_id}-metadata",
        component: :status_badge,
        props: %{
          title: "Suggestion metadata",
          body: self_improvement_badge_text(suggestion_type, draft_kind),
          status: "info"
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

  defp self_improvement_badge_text(suggestion_type, draft_kind) do
    ["self_improvement", suggestion_type, draft_kind]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" / ")
  end

  defp humanize_type(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
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
