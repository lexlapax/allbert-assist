defmodule AllbertAssist.Workspace.Catalog do
  @moduledoc """
  Workspace component catalog metadata.

  v0.26 expands the Surface catalog to the 42 components used by the
  workspace shell, canvas tiles, ephemeral surfaces, and reserved StockSage
  cards. The web tier owns concrete LiveComponent modules; this module keeps
  the core allow-list and workspace tree metadata web-agnostic.

  v0.31 M7 keeps this module as the workspace tree builder and delegates
  component membership to `AllbertAssist.Surface.Catalog`.
  """

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.Runtime.Persistence
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Catalog, as: SurfaceCatalog
  alias AllbertAssist.Surface.Node

  @spec known_components() :: [AllbertAssist.Surface.component(), ...]
  def known_components, do: SurfaceCatalog.known_components()

  @spec workspace_tree(keyword() | map()) :: Surface.t()
  def workspace_tree(context \\ %{}) do
    context = context_map(context)
    panel_context = panel_context(context)

    :workspace
    |> core_surface!()
    |> Map.update!(:metadata, &Map.merge(&1 || %{}, workspace_metadata(context, panel_context)))
    |> Map.update!(:nodes, &inject_runtime_nodes(&1, context, panel_context))
  end

  defp core_surface!(surface_id) do
    Enum.find(CoreApp.surfaces(), &(&1.id == surface_id)) ||
      raise ArgumentError, "unknown core workspace surface: #{inspect(surface_id)}"
  end

  defp workspace_metadata(context, panel_context) when is_map(context) do
    workspace =
      context
      |> Map.take([:user_id, :thread_id])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    metadata = %{workspace: workspace}

    case panel_context.diagnostics do
      [] -> metadata
      diagnostics -> Map.put(metadata, :panel_diagnostics, diagnostics)
    end
  end

  defp context_map(context) when is_list(context), do: Map.new(context)
  defp context_map(context) when is_map(context), do: context

  defp panel_context(context) do
    catalogs = Map.get(context, :surface_catalogs, %{})

    context
    |> Map.get(:panel_surfaces, [])
    |> panel_surface_list()
    |> Enum.reduce(%{nodes_by_zone: %{}, diagnostics: []}, &put_panel_context(&1, &2, catalogs))
  end

  defp panel_surface_list(surfaces) when is_list(surfaces), do: surfaces
  defp panel_surface_list(_surfaces), do: [:invalid_panel_surfaces]

  defp put_panel_context(surface, acc, catalogs) do
    case validate_panel_surface(surface, catalogs) do
      {:ok, %Surface{zone: zone} = surface} ->
        put_panel_nodes(acc, zone, panel_surface_nodes(surface))

      {:error, diagnostics} ->
        put_panel_diagnostics(acc, surface, diagnostics)
    end
  end

  defp put_panel_nodes(acc, zone, panel_nodes) do
    Map.update!(
      acc,
      :nodes_by_zone,
      &Map.update(&1, zone, panel_nodes, fn nodes -> nodes ++ panel_nodes end)
    )
  end

  defp put_panel_diagnostics(acc, surface, diagnostics) do
    Map.update!(acc, :diagnostics, &(&1 ++ bounded_panel_diagnostics(surface, diagnostics)))
  end

  defp validate_panel_surface(%Surface{} = surface, catalogs) do
    with {:ok, %Surface{kind: :panel} = surface} <- Surface.validate_surface(surface),
         :ok <- validate_panel_surface_catalog(surface, catalogs) do
      {:ok, surface}
    else
      {:ok, %Surface{} = surface} ->
        {:error,
         [
           %{
             kind: :invalid_panel_surface,
             message: "Workspace panel context can only render panel surfaces.",
             detail: %{surface_id: surface.id, kind: surface.kind}
           }
         ]}

      {:error, diagnostics} ->
        {:error, diagnostics}
    end
  end

  defp validate_panel_surface(_surface, _catalogs) do
    {:error,
     [
       %{
         kind: :invalid_panel_surface,
         message: "Workspace panel context entry must be an AllbertAssist.Surface struct.",
         detail: %{}
       }
     ]}
  end

  defp validate_panel_surface_catalog(%Surface{app_id: app_id} = surface, catalogs) do
    case Map.get(catalogs, app_id) || Map.get(catalogs, Atom.to_string(app_id)) do
      nil -> :ok
      catalog -> Surface.validate_surface_catalog(surface, catalog)
    end
  end

  defp panel_surface_nodes(%Surface{} = surface) do
    Enum.map(surface.nodes, &namespace_panel_node(&1, surface))
  end

  defp namespace_panel_node(%Node{} = node, %Surface{} = surface) do
    prefix = "workspace-panel-#{safe_id(surface.app_id)}-#{safe_id(surface.id)}"

    namespace_node(node, prefix, %{
      app_id: surface.app_id,
      surface_id: surface.id,
      zone: surface.zone
    })
  end

  defp namespace_node(%Node{} = node, prefix, props) do
    %{
      node
      | id: "#{prefix}-#{safe_id(node.id)}",
        props: Map.merge(node.props || %{}, props),
        children: Enum.map(node.children, &namespace_node(&1, prefix, %{}))
    }
  end

  defp bounded_panel_diagnostics(surface, diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.take(8)
    |> Enum.map(fn diagnostic ->
      %{
        kind: Map.get(diagnostic, :kind, :invalid_panel_surface),
        message: Map.get(diagnostic, :message, "Panel surface was rejected."),
        detail:
          diagnostic
          |> diagnostic_detail()
          |> Map.put_new(:surface_id, panel_surface_id(surface))
      }
    end)
  end

  defp diagnostic_detail(%{} = diagnostic) do
    case Map.get(diagnostic, :detail, %{}) do
      %{} = detail -> detail
      _detail -> %{}
    end
  end

  defp panel_surface_id(%Surface{id: id}), do: id
  defp panel_surface_id(_surface), do: nil

  defp inject_runtime_nodes(nodes, context, panel_context) do
    Enum.map(nodes, &inject_runtime_node(&1, context, panel_context))
  end

  defp inject_runtime_node(%Node{component: :canvas} = node, context, panel_context) do
    tiles = Map.get(context, :canvas_tiles, [])
    panels = Map.get(panel_context.nodes_by_zone, :canvas_panels, [])

    if tiles == [] and panels == [] do
      node
    else
      runtime_children =
        if tiles == [] do
          node.children
        else
          tile_nodes(tiles)
        end

      %{
        node
        | props:
            Map.merge(node.props || %{}, %{
              empty?: false,
              zones: [:canvas_panels]
            }),
          children: runtime_children ++ panels
      }
    end
  end

  defp inject_runtime_node(%Node{component: :ephemeral_surface} = node, context, panel_context) do
    surfaces = Map.get(context, :ephemeral_surfaces, [])
    panels = Map.get(panel_context.nodes_by_zone, :ephemeral, [])

    if surfaces == [] and panels == [] do
      node
    else
      %{
        node
        | props:
            Map.merge(node.props || %{}, %{
              empty?: false,
              zones: [:ephemeral]
            }),
          children: ephemeral_nodes(surfaces) ++ panels
      }
    end
  end

  defp inject_runtime_node(%Node{component: :badge_strip} = node, context, panel_context) do
    badges = Map.get(context, :workspace_badges, [])
    panels = Map.get(panel_context.nodes_by_zone, :context_rail, [])

    if badges == [] and panels == [] do
      node
    else
      %{
        node
        | props:
            Map.merge(node.props || %{}, %{
              title: "Workspace notices",
              body: "#{length(badges)} active notice(s)",
              zones: [:context_rail]
            }),
          children: badge_nodes(badges) ++ panels
      }
    end
  end

  defp inject_runtime_node(%Node{children: children} = node, context, panel_context) do
    %{node | children: inject_runtime_nodes(children, context, panel_context)}
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
          pinned?: Map.get(tile, :pinned, false),
          deleted?: not is_nil(Map.get(tile, :deleted_at)),
          deleted_at: time_value(Map.get(tile, :deleted_at)),
          updated_at: time_value(Map.get(tile, :updated_at)),
          emitter_id: fragment_value(tile, :emitter_id),
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
          pinned?: Map.get(surface, :pinned, false),
          opened_at: time_value(Map.get(surface, :opened_at)),
          emitter_id: fragment_value(surface, :emitter_id),
          dismissible?: dismissible_surface?(surface)
        },
        children: stored_surface_nodes(surface)
      }
    end)
  end

  defp stored_surface_nodes(%{body: body}) do
    case Persistence.surface_from_fragment_body(body) do
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

  defp fragment_value(%{body: body}, key) when is_map(body) do
    fragment = Map.get(body, :fragment) || Map.get(body, "fragment") || %{}
    Map.get(fragment, key) || Map.get(fragment, Atom.to_string(key))
  end

  defp fragment_value(_record, _key), do: nil

  defp time_value(nil), do: nil
  defp time_value(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp time_value(%NaiveDateTime{} = time), do: NaiveDateTime.to_iso8601(time)
  defp time_value(time) when is_binary(time), do: time
  defp time_value(time), do: to_string(time)

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
    |> Persistence.surface_from_fragment_body()
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
