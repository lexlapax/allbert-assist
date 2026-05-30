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
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Runtime.Persistence
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Catalog, as: SurfaceCatalog
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Theme.Layout

  @workspace_tool_destinations [
    %{id: "workspace:onboard", tool: "onboard", label: "Onboard", dom_id: "workspace-onboard"},
    %{id: "workspace:create", tool: "create", label: "Create", dom_id: "create"},
    %{
      id: "workspace:discover",
      tool: "discover",
      label: "Discovery",
      dom_id: "workspace-discover"
    },
    %{id: "workspace:jobs", tool: "jobs", label: "Jobs", dom_id: "workspace-jobs"},
    %{
      id: "workspace:objectives",
      tool: "objectives",
      label: "Objectives",
      dom_id: "workspace-objectives"
    },
    %{
      id: "workspace:confirmations",
      tool: "confirmations",
      label: "Confirmations",
      dom_id: "workspace-confirmations"
    },
    %{
      id: "workspace:security",
      tool: "security",
      label: "Security",
      dom_id: "workspace-security"
    },
    %{
      id: "workspace:settings",
      tool: "settings",
      label: "Settings",
      dom_id: "workspace-settings",
      non_hideable?: true
    }
  ]

  @workspace_tool_panels %{
    "onboard" => :core_onboarding_panel,
    "create" => :core_create_panel,
    "discover" => :core_discovery_suggestions_panel,
    "jobs" => :core_jobs_panel,
    "objectives" => :core_objectives_panel,
    "confirmations" => :core_confirmations_panel,
    "security" => :core_security_panel,
    "settings" => :core_settings_panel
  }

  @spec known_components() :: [AllbertAssist.Surface.component(), ...]
  def known_components, do: SurfaceCatalog.known_components()

  @spec known_destinations(keyword() | map()) :: [map()]
  def known_destinations(context \\ %{}) do
    context = context_map(context)

    [
      %{
        id: "output",
        section: :output,
        label: "Output",
        dom_id: "output",
        non_hideable?: true
      }
    ] ++
      app_destinations(registered_apps(context)) ++
      Enum.map(@workspace_tool_destinations, &Map.put(&1, :section, :workspace))
  end

  @spec workspace_tree(keyword() | map()) :: Surface.t()
  def workspace_tree(context \\ %{}) do
    context = context_map(context)
    layout = Map.get(context, :workspace_layout) || Layout.current(context)
    context = Map.put(context, :workspace_layout, layout)
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

    metadata
    |> Map.put(:layout, Map.drop(Map.get(context, :workspace_layout, %{}), [:panel_pins]))
    |> maybe_put_panel_diagnostics(panel_context.diagnostics)
  end

  defp context_map(context) when is_list(context), do: Map.new(context)
  defp context_map(context) when is_map(context), do: context

  defp maybe_put_panel_diagnostics(metadata, []), do: metadata

  defp maybe_put_panel_diagnostics(metadata, diagnostics),
    do: Map.put(metadata, :panel_diagnostics, diagnostics)

  defp registered_apps(%{registered_apps: apps}) when is_list(apps), do: apps

  defp registered_apps(_context) do
    AppRegistry.registered_apps()
  catch
    :exit, _reason -> []
  end

  defp app_destinations(apps) do
    apps
    |> List.wrap()
    |> Enum.reject(&(app_id(&1) == "allbert"))
    |> Enum.map(fn app ->
      app_id = app_id(app)

      %{
        id: "app:#{app_id}",
        section: :apps,
        label: app_label(app),
        dom_id: "app-#{app_id}",
        app_id: app_id
      }
    end)
  end

  defp app_id(app) when is_map(app), do: app |> field(:app_id, :allbert) |> to_string()
  defp app_id(_app), do: "allbert"

  defp app_label(app) when is_map(app),
    do: app |> field(:display_name, app_id(app)) |> to_string()

  defp app_label(_app), do: "Allbert"

  defp field(map, key, fallback) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), fallback)
  end

  defp panel_context(context) do
    catalogs = Map.get(context, :surface_catalogs, %{})

    {entries, diagnostics} =
      context
      |> panel_surfaces()
      |> Enum.with_index()
      |> Enum.reduce({[], []}, &validate_panel_context_entry(&1, &2, catalogs, context))

    entries
    |> Enum.sort_by(fn %{surface: surface, index: index} -> {panel_order(surface), index} end)
    |> Enum.reduce(%{nodes_by_zone: %{}, diagnostics: diagnostics}, &put_panel_context/2)
  end

  defp panel_surface_list(surfaces) when is_list(surfaces), do: surfaces
  defp panel_surface_list(_surfaces), do: [:invalid_panel_surfaces]

  defp panel_surfaces(context) do
    context
    |> Map.get(:panel_surfaces, [])
    |> panel_surface_list()
    |> include_core_panel_surfaces()
  end

  defp include_core_panel_surfaces(surfaces) do
    (surfaces ++ core_panel_surfaces())
    |> Enum.reduce({MapSet.new(), []}, fn
      %Surface{kind: :panel, app_id: app_id, id: id} = surface, {seen, acc} ->
        key = {app_id, id}

        if MapSet.member?(seen, key) do
          {seen, acc}
        else
          {MapSet.put(seen, key), [surface | acc]}
        end

      surface, {seen, acc} ->
        {seen, [surface | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp core_panel_surfaces do
    CoreApp.surfaces()
    |> Enum.filter(&match?(%Surface{kind: :panel}, &1))
  end

  defp validate_panel_context_entry({surface, index}, {entries, diagnostics}, catalogs, context) do
    case validate_panel_surface(surface, catalogs) do
      {:ok, %Surface{zone: zone} = surface} ->
        if panel_visible?(surface, context) do
          entry = %{surface: surface, zone: render_zone(surface, context, zone), index: index}
          {[entry | entries], diagnostics}
        else
          {entries, diagnostics}
        end

      {:error, surface_diagnostics} ->
        {entries, diagnostics ++ bounded_panel_diagnostics(surface, surface_diagnostics)}
    end
  end

  defp put_panel_context(%{surface: %Surface{} = surface, zone: zone}, acc) do
    put_panel_nodes(acc, zone, panel_surface_nodes(surface))
  end

  defp put_panel_nodes(acc, zone, panel_nodes) do
    Map.update!(
      acc,
      :nodes_by_zone,
      &Map.update(&1, zone, panel_nodes, fn nodes -> nodes ++ panel_nodes end)
    )
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

  defp panel_order(%Surface{metadata: metadata}) do
    case metadata_value(metadata, :order) do
      order when is_integer(order) -> order
      _order -> 5_000
    end
  end

  defp panel_visible?(%Surface{} = surface, context) do
    destination = canvas_destination(context)

    if Layout.panel_pinned?(
         Map.get(context, :workspace_layout),
         destination_prop(destination),
         surface
       ) do
      true
    else
      panel_visible_for_destination?(surface, context, destination)
    end
  end

  defp panel_visible_for_destination?(%Surface{} = surface, context, destination) do
    case destination do
      {:output} ->
        surface.zone == :ephemeral and legacy_panel_visible?(surface, context)

      {:app, app_id} ->
        normalize_app_id(surface.app_id) == app_id and app_id != "allbert"

      {:workspace, tool} ->
        surface.id == Map.get(@workspace_tool_panels, tool)
    end
  end

  defp legacy_panel_visible?(%Surface{} = surface, context) do
    case visible_when(surface) do
      :always -> true
      :active_app -> active_app_surface?(surface, context)
      :selected_app -> active_app_surface?(surface, context)
      :has_context -> context_has_runtime_scope?(context)
      :operator_opened -> operator_opened_surface?(surface, context)
    end
  end

  defp render_zone(%Surface{zone: :ephemeral}, _context, zone), do: zone

  defp render_zone(%Surface{}, context, zone) do
    case canvas_destination(context) do
      {:output} -> zone
      {:app, _app_id} -> :canvas_panels
      {:workspace, _tool} -> :canvas_panels
    end
  end

  defp canvas_destination(context) do
    context
    |> Map.get(:canvas_destination, "output")
    |> normalize_canvas_destination()
  end

  defp normalize_canvas_destination("output"), do: {:output}

  defp normalize_canvas_destination("app:" <> app_id) do
    app_id = normalize_app_id(app_id)

    if app_id in [nil, "", "allbert"] do
      {:output}
    else
      {:app, app_id}
    end
  end

  defp normalize_canvas_destination("workspace:" <> tool) do
    if Map.has_key?(@workspace_tool_panels, tool), do: {:workspace, tool}, else: {:output}
  end

  defp normalize_canvas_destination(_destination), do: {:output}

  defp visible_when(%Surface{metadata: metadata}) do
    case metadata_value(metadata, :visible_when) do
      nil ->
        :always

      value when value in [:always, :active_app, :selected_app, :has_context, :operator_opened] ->
        value

      value when is_binary(value) ->
        visible_when_string(value)
    end
  end

  defp visible_when_string(value) do
    case String.trim(value) do
      "always" -> :always
      "active_app" -> :active_app
      "selected_app" -> :selected_app
      "has_context" -> :has_context
      "operator_opened" -> :operator_opened
    end
  end

  defp active_app_surface?(%Surface{app_id: app_id}, context) do
    normalize_app_id(app_id) == normalize_app_id(Map.get(context, :active_app))
  end

  defp context_has_runtime_scope?(context) do
    not is_nil(Map.get(context, :user_id)) or not is_nil(Map.get(context, :thread_id))
  end

  defp operator_opened_surface?(%Surface{} = surface, context) do
    open_panels = context |> Map.get(:operator_opened_panels, []) |> List.wrap()

    surface.id in open_panels or
      to_string(surface.id) in open_panels or
      {surface.app_id, surface.id} in open_panels or
      "#{surface.app_id}:#{surface.id}" in open_panels
  end

  defp normalize_app_id(app_id) when is_atom(app_id), do: Atom.to_string(app_id)
  defp normalize_app_id(app_id) when is_binary(app_id), do: app_id
  defp normalize_app_id(_app_id), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp inject_runtime_nodes(nodes, context, panel_context) do
    Enum.map(nodes, &inject_runtime_node(&1, context, panel_context))
  end

  defp inject_runtime_node(%Node{component: :canvas} = node, context, panel_context) do
    destination = canvas_destination(context)
    tiles = if destination == {:output}, do: Map.get(context, :canvas_tiles, []), else: []
    panels = Map.get(panel_context.nodes_by_zone, :canvas_panels, [])

    if tiles == [] and panels == [] do
      %{node | props: Map.merge(node.props || %{}, %{destination: destination_prop(destination)})}
    else
      runtime_children =
        cond do
          tiles != [] -> tile_nodes(tiles)
          panels != [] -> panels
          true -> node.children
        end

      %{
        node
        | props:
            Map.merge(node.props || %{}, %{
              empty?: false,
              destination: destination_prop(destination),
              zones: [:canvas_panels]
            }),
          children: runtime_children
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

  defp inject_runtime_node(%Node{component: :badge_strip} = node, context, _panel_context) do
    badges = Map.get(context, :workspace_badges, [])

    if badges == [] do
      node
    else
      %{
        node
        | props:
            Map.merge(node.props || %{}, %{
              title: "Workspace notices",
              body: "#{length(badges)} active notice(s)",
              zones: []
            }),
          children: badge_nodes(badges)
      }
    end
  end

  defp inject_runtime_node(%Node{component: :app_launcher} = node, context, _panel_context) do
    %{
      node
      | props: Map.merge(node.props || %{}, %{layout: Map.get(context, :workspace_layout)})
    }
  end

  defp inject_runtime_node(%Node{component: :nav_rail} = node, context, panel_context) do
    panels = Map.get(panel_context.nodes_by_zone, :nav_apps, [])
    children = inject_runtime_nodes(node.children, context, panel_context)

    if panels == [] do
      %{node | children: children}
    else
      %{
        node
        | props: Map.merge(node.props || %{}, %{zones: [:nav_apps]}),
          children: children ++ panels
      }
    end
  end

  defp inject_runtime_node(%Node{component: :utility_drawer} = node, context, panel_context) do
    panels = Map.get(panel_context.nodes_by_zone, :utility_drawer, [])
    children = inject_runtime_nodes(node.children, context, panel_context)

    if panels == [] do
      %{node | children: children}
    else
      %{
        node
        | props: Map.merge(node.props || %{}, %{zones: [:utility_drawer]}),
          children: children ++ panels
      }
    end
  end

  defp inject_runtime_node(%Node{children: children} = node, context, panel_context) do
    %{node | children: inject_runtime_nodes(children, context, panel_context)}
  end

  defp destination_prop({:output}), do: "output"
  defp destination_prop({:app, app_id}), do: "app:#{app_id}"
  defp destination_prop({:workspace, tool}), do: "workspace:#{tool}"

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
