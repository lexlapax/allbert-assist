defmodule AllbertAssist.Workspace.Catalog do
  @moduledoc """
  Workspace component catalog metadata.

  v0.26 expands the Surface catalog to the 42 components used by the
  workspace shell, canvas tiles, ephemeral surfaces, and reserved StockSage
  cards. The web tier owns concrete LiveComponent modules; this module keeps
  the core allow-list and workspace tree metadata web-agnostic.
  """

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody

  @spec known_components() :: [AllbertAssist.Surface.component(), ...]
  def known_components, do: AllbertAssist.Surface.known_components()

  @spec workspace_tree(keyword() | map()) :: Surface.t()
  def workspace_tree(context \\ %{}) do
    context = context_map(context)

    :agent
    |> core_surface!()
    |> Map.update!(:metadata, &Map.merge(&1 || %{}, workspace_metadata(context)))
    |> Map.update!(:nodes, &inject_runtime_nodes(&1, context))
  end

  @spec component_renderer(atom()) :: {:ok, atom()} | {:error, :unknown_component}
  def component_renderer(component) do
    if component in known_components() do
      {:ok, component}
    else
      {:error, :unknown_component}
    end
  end

  defp core_surface!(surface_id) do
    Enum.find(CoreApp.surfaces(), &(&1.id == surface_id)) ||
      raise ArgumentError, "unknown core workspace surface: #{inspect(surface_id)}"
  end

  defp workspace_metadata(context) when is_map(context) do
    context
    |> Map.take([:user_id, :thread_id])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> then(&%{workspace: &1})
  end

  defp context_map(context) when is_list(context), do: Map.new(context)
  defp context_map(context) when is_map(context), do: context

  defp inject_runtime_nodes(nodes, context) do
    Enum.map(nodes, &inject_runtime_node(&1, context))
  end

  defp inject_runtime_node(%Node{component: :canvas} = node, context) do
    tiles = Map.get(context, :canvas_tiles, [])

    if tiles == [] do
      node
    else
      %{node | props: Map.put(node.props || %{}, :empty?, false), children: tile_nodes(tiles)}
    end
  end

  defp inject_runtime_node(%Node{component: :ephemeral_surface} = node, context) do
    surfaces = Map.get(context, :ephemeral_surfaces, [])

    if surfaces == [] do
      node
    else
      %{
        node
        | props: Map.put(node.props || %{}, :empty?, false),
          children: ephemeral_nodes(surfaces)
      }
    end
  end

  defp inject_runtime_node(%Node{component: :badge_strip} = node, context) do
    badges = Map.get(context, :workspace_badges, [])

    if badges == [] do
      node
    else
      %{
        node
        | props:
            Map.merge(node.props || %{}, %{
              title: "Workspace notices",
              body: "#{length(badges)} active notice(s)"
            }),
          children: badge_nodes(badges)
      }
    end
  end

  defp inject_runtime_node(%Node{children: children} = node, context) do
    %{node | children: inject_runtime_nodes(children, context)}
  end

  defp tile_nodes(tiles) do
    tiles
    |> Enum.map(fn tile ->
      %Node{
        id: "canvas-tile-#{safe_id(tile.id)}",
        component: :tile,
        props: %{
          title: title(tile, "Canvas tile"),
          body: tile_summary(tile),
          tile_id: tile.id,
          tile_kind: tile.kind,
          tile_text: tile_text(tile),
          editable?: editable_tile?(tile),
          base_revision_id: Map.get(tile, :current_revision_id),
          read_only?: Map.get(tile, :read_only, false),
          conflict_summary: conflict_summary(tile)
        },
        children: stored_surface_nodes(tile)
      }
    end)
  end

  defp ephemeral_nodes(surfaces) do
    surfaces
    |> Enum.map(fn surface ->
      %Node{
        id: "ephemeral-surface-#{safe_id(surface.id)}",
        component: :ephemeral_surface,
        props: %{
          title: title(surface, "Ephemeral surface"),
          body: "kind=#{surface.kind}",
          surface_id: surface.id,
          dismissible?: dismissible_surface?(surface)
        },
        children: stored_surface_nodes(surface)
      }
    end)
  end

  defp stored_surface_nodes(%{body: body}) do
    case FragmentBody.surface_from_body(body) do
      {:ok, %Surface{nodes: nodes}} -> nodes
      {:error, _reason} -> []
    end
  end

  defp stored_surface_nodes(_record), do: []

  defp editable_tile?(%{kind: kind, body: body} = tile) when kind in ["text", "markdown"] do
    not Map.get(tile, :read_only, false) and not fragment_body?(body)
  end

  defp editable_tile?(_tile), do: false

  defp tile_summary(tile) do
    case {editable_tile?(tile), tile_text(tile)} do
      {true, ""} -> "Editable #{tile.kind} tile"
      {true, text} -> text
      {false, _text} -> "kind=#{tile.kind}"
    end
  end

  defp tile_text(%{body: body, kind: "markdown"}) when is_map(body) do
    text_value(body, [:markdown, :text, :content, :snapshot])
  end

  defp tile_text(%{body: body}) when is_map(body) do
    text_value(body, [:text, :markdown, :content, :snapshot])
  end

  defp tile_text(_tile), do: ""

  defp text_value(body, keys) do
    Enum.find_value(keys, "", fn key ->
      case Map.get(body, key) || Map.get(body, Atom.to_string(key)) do
        value when is_binary(value) -> value
        _other -> nil
      end
    end)
  end

  defp fragment_body?(body) when is_map(body) do
    Map.has_key?(body, :surface) or Map.has_key?(body, "surface")
  end

  defp fragment_body?(_body), do: false

  defp conflict_summary(%{metadata: metadata}) when is_map(metadata) do
    offline = Map.get(metadata, "offline") || Map.get(metadata, :offline) || %{}

    %{
      conflict?: offline_value(offline, :conflict, false),
      conflict_count: offline_value(offline, :conflict_count, 0),
      latest_revision_id: offline_value(offline, :latest_revision_id),
      revert_revision_id: offline_value(offline, :revert_revision_id),
      previous_revision_id: offline_value(offline, :previous_revision_id),
      reconciled_at: offline_value(offline, :reconciled_at)
    }
  end

  defp conflict_summary(_tile) do
    %{conflict?: false, conflict_count: 0}
  end

  defp offline_value(offline, key, fallback \\ nil) do
    Map.get(offline, Atom.to_string(key)) || Map.get(offline, key) || fallback
  end

  defp dismissible_surface?(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "dismissible?", Map.get(metadata, :dismissible?, true)) != false and
      Map.get(metadata, "dismissible", Map.get(metadata, :dismissible, true)) != false
  end

  defp dismissible_surface?(_surface), do: true

  defp badge_nodes(badges) do
    badges
    |> Enum.flat_map(&badge_surface_nodes/1)
  end

  defp badge_surface_nodes(%{id: id, surface: %Surface{nodes: nodes}}) do
    Enum.map(nodes, fn %Node{} = node ->
      %{node | id: "workspace-badge-#{safe_id(id)}-#{safe_id(node.id)}"}
    end)
  end

  defp badge_surface_nodes(badge) do
    [
      %Node{
        id: "workspace-badge-#{safe_id(Map.get(badge, :id) || Map.get(badge, "id") || "notice")}",
        component: :status_badge,
        props: %{
          title: Map.get(badge, :title) || Map.get(badge, "title") || "Workspace notice",
          body: Map.get(badge, :body) || Map.get(badge, "body") || "Workspace notice",
          status: Map.get(badge, :status) || Map.get(badge, "status") || "info"
        }
      }
    ]
  end

  defp title(%{body: body, id: id}, fallback) when is_map(body) do
    body
    |> FragmentBody.surface_from_body()
    |> case do
      {:ok, %Surface{label: label}} when is_binary(label) and label != "" -> label
      _other -> "#{fallback} #{id}"
    end
  end

  defp title(%{id: id}, fallback), do: "#{fallback} #{id}"
  defp title(_record, fallback), do: fallback

  defp safe_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.:-]/, "-")
  end
end
