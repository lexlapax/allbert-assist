defmodule AllbertAssist.Surface do
  @moduledoc """
  Local declarative surface DSL for app-provided Allbert surfaces.

  This module validates source-tree surface data before it reaches a renderer.
  It is metadata, not executable UI code.
  """

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Surface.ActionBinding
  alias AllbertAssist.Surface.Catalog
  alias AllbertAssist.Surface.Node

  defstruct [
    :id,
    :app_id,
    :label,
    :path,
    :kind,
    :zone,
    :status,
    nodes: [],
    fallback_text: "",
    metadata: %{}
  ]

  @known_kinds [:route, :chat, :workspace, :analysis, :canvas, :settings, :panel]
  @known_statuses [:available, :placeholder, :disabled]
  @known_visible_when [:always, :active_app, :selected_app, :has_context, :operator_opened]
  @secret_key_regex ~r/(^|_)(key|secret|token|password|credential|api_key)$/i

  @type diagnostic :: %{
          required(:kind) => atom(),
          required(:message) => String.t(),
          optional(:detail) => map()
        }

  @type catalog_entry :: %{
          required(:component) => atom(),
          optional(:allowed_props) => [atom()],
          optional(:allowed_bindings) => [String.t()]
        }

  @type component ::
          :route
          | :chat
          | :timeline
          | :composer
          | :panel
          | :section
          | :text
          | :list
          | :empty_state
          | :button
          | :action_button
          | :status_badge
          | :workspace_shell
          | :nav_rail
          | :thread_list
          | :app_launcher
          | :utility_drawer
          | :workspace_panel
          | :workspace
          | :canvas
          | :tile
          | :ephemeral_surface
          | :header
          | :badge_strip
          | :tabs
          | :tab
          | :tab_panel
          | :diff
          | :trace_link
          | :trace_viewer
          | :icon
          | :link
          | :divider
          | :table
          | :row
          | :column
          | :objective_card
          | :confirmation_card
          | :approval_card
          | :approval_inspector
          | :memory_review_card
          | :job_card
          | :channel_card
          | :settings_card
          | :analysis_card
          | :agent_report_card
          | :parity_card
          | :debate_round_card

  @type t :: %__MODULE__{
          id: atom(),
          app_id: atom(),
          label: String.t(),
          path: String.t(),
          kind: atom(),
          zone: atom() | nil,
          status: atom(),
          nodes: [Node.t()],
          fallback_text: String.t(),
          metadata: map()
        }

  @spec known_components() :: [component(), ...]
  def known_components, do: Catalog.known_components()

  @spec known_zones() :: [Catalog.zone(), ...]
  def known_zones, do: Catalog.known_zones()

  @spec validate_surface(t()) :: {:ok, t()} | {:error, [diagnostic()]}
  def validate_surface(%__MODULE__{} = surface) do
    diagnostics =
      []
      |> validate_surface_shape(surface)
      |> validate_surface_nodes(surface)

    if diagnostics == [] do
      {:ok,
       %{
         surface
         | nodes: validate_nodes!(surface.nodes),
           zone: normalized_surface_zone(surface)
       }}
    else
      {:error, Enum.reverse(diagnostics)}
    end
  end

  def validate_surface(_surface),
    do:
      {:error, [diagnostic(:invalid_surface, "Surface must be an AllbertAssist.Surface struct.")]}

  @spec validate_catalog([catalog_entry()]) :: {:ok, [catalog_entry()]} | {:error, [diagnostic()]}
  def validate_catalog(catalog) when is_list(catalog) do
    catalog
    |> Enum.with_index()
    |> Enum.reduce([], fn {entry, index}, diagnostics ->
      diagnostics ++ catalog_entry_diagnostics(entry, index)
    end)
    |> case do
      [] -> {:ok, catalog}
      diagnostics -> {:error, diagnostics}
    end
  end

  def validate_catalog(_catalog),
    do: {:error, [diagnostic(:invalid_catalog, "Surface catalog must be a list.")]}

  @doc """
  Validate that non-primitive nodes on a surface are declared by the app catalog.

  Surface primitives are shared substrate components. App-owned card and domain
  components must be declared by the provider catalog before they can render or
  cross a Fragment boundary.
  """
  @spec validate_surface_catalog(t(), [catalog_entry()]) :: :ok | {:error, [diagnostic()]}
  def validate_surface_catalog(%__MODULE__{} = surface, catalog) do
    with {:ok, catalog} <- validate_catalog(catalog) do
      allowed = catalog |> Enum.map(&catalog_component/1) |> MapSet.new()

      diagnostics =
        surface.nodes
        |> flatten_nodes()
        |> Enum.reduce([], &catalog_node_diagnostics(&1, &2, allowed, surface.app_id))

      if diagnostics == [], do: :ok, else: {:error, Enum.reverse(diagnostics)}
    end
  end

  def validate_surface_catalog(_surface, _catalog),
    do:
      {:error, [diagnostic(:invalid_surface, "Surface must be an AllbertAssist.Surface struct.")]}

  defp catalog_node_diagnostics(%Node{} = node, acc, allowed, app_id) do
    if Catalog.primitive_component?(node.component) or MapSet.member?(allowed, node.component) do
      acc
    else
      [
        diagnostic(
          :component_not_in_app_catalog,
          "Surface component is not declared by the app catalog.",
          %{
            node_id: node.id,
            component: node.component,
            app_id: app_id
          }
        )
        | acc
      ]
    end
  end

  defp catalog_node_diagnostics(_node, acc, _allowed, _app_id), do: acc

  defp validate_surface_shape(diagnostics, surface) do
    diagnostics
    |> require_atom(surface.id, :id)
    |> require_atom(surface.app_id, :app_id)
    |> require_bounded_string(surface.label, :label, 1, 64)
    |> validate_path(surface.path)
    |> require_member(surface.kind, @known_kinds, :kind)
    |> require_member(surface.status, @known_statuses, :status)
    |> require_bounded_string(surface.fallback_text, :fallback_text, 1, 512)
    |> validate_metadata(surface.metadata)
    |> validate_panel_contract(surface)
  end

  defp validate_surface_nodes(diagnostics, surface) do
    node_count = count_nodes(surface.nodes)

    diagnostics
    |> validate_node_count(node_count)
    |> validate_duplicate_node_ids(surface.nodes)
    |> validate_node_list(surface.nodes, surface.app_id)
  end

  defp validate_node_count(diagnostics, count) when count <= 256, do: diagnostics

  defp validate_node_count(diagnostics, count),
    do: [
      diagnostic(:surface_too_large, "Surface has too many nodes.", %{count: count}) | diagnostics
    ]

  defp validate_node_list(diagnostics, nodes, app_id) when is_list(nodes) do
    Enum.reduce(nodes, diagnostics, &validate_node(&1, &2, app_id))
  end

  defp validate_node_list(diagnostics, _nodes, _app_id),
    do: [diagnostic(:invalid_nodes, "Surface nodes must be a list.") | diagnostics]

  defp validate_node(%Node{} = node, diagnostics, app_id) do
    diagnostics
    |> require_bounded_string(node.id, :node_id, 1, 64)
    |> require_member(node.component, Catalog.known_components(), :component)
    |> validate_props(node.props)
    |> validate_bindings(node.bindings, app_id)
    |> validate_node_list(node.children, app_id)
  end

  defp validate_node(_node, diagnostics, _app_id),
    do: [
      diagnostic(:invalid_node, "Surface node must be an AllbertAssist.Surface.Node struct.")
      | diagnostics
    ]

  defp validate_duplicate_node_ids(diagnostics, nodes) do
    duplicate_ids =
      nodes
      |> flatten_nodes()
      |> Enum.map(fn
        %Node{id: id} -> id
        _node -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)

    case duplicate_ids do
      [] ->
        diagnostics

      ids ->
        [
          diagnostic(:duplicate_node_id, "Surface contains duplicate node ids.", %{node_ids: ids})
          | diagnostics
        ]
    end
  end

  defp validate_props(diagnostics, props) when is_map(props) and map_size(props) <= 64 do
    Enum.reduce(props, diagnostics, fn {key, value}, acc ->
      acc
      |> validate_prop_key(key)
      |> validate_prop_value(key, value)
    end)
  end

  defp validate_props(diagnostics, props) when is_map(props),
    do: [diagnostic(:props_too_large, "Surface node props exceed 64 keys.") | diagnostics]

  defp validate_props(diagnostics, _props),
    do: [diagnostic(:invalid_props, "Surface node props must be a map.") | diagnostics]

  defp validate_prop_key(diagnostics, key) do
    if Regex.match?(@secret_key_regex, to_string(key)) do
      [
        diagnostic(:secret_prop_key, "Surface prop key looks secret-like.", %{key: inspect(key)})
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp validate_prop_value(diagnostics, key, value) when is_binary(value) do
    cond do
      byte_size(value) > 2048 ->
        [
          diagnostic(:prop_value_too_large, "Surface prop string is too large.", %{
            key: inspect(key)
          })
          | diagnostics
        ]

      raw_html?(value) ->
        [
          diagnostic(:raw_html_prop, "Surface prop values cannot contain raw HTML.", %{
            key: inspect(key)
          })
          | diagnostics
        ]

      unsafe_url_or_script?(value) ->
        [
          diagnostic(
            :unsafe_prop_value,
            "Surface prop values cannot contain scripts or remote URLs.",
            %{key: inspect(key)}
          )
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  defp validate_prop_value(diagnostics, _key, value) when is_list(value) do
    Enum.reduce(value, diagnostics, fn item, acc -> validate_prop_value(acc, :list_item, item) end)
  end

  defp validate_prop_value(diagnostics, _key, value) when is_map(value) do
    validate_props(diagnostics, value)
  end

  defp validate_prop_value(diagnostics, _key, _value), do: diagnostics

  defp validate_bindings(diagnostics, bindings, app_id) when is_list(bindings) do
    Enum.reduce(bindings, diagnostics, &validate_binding(&1, &2, app_id))
  end

  defp validate_bindings(diagnostics, _bindings, _app_id),
    do: [diagnostic(:invalid_bindings, "Surface action bindings must be a list.") | diagnostics]

  defp validate_binding(%ActionBinding{} = binding, diagnostics, app_id) do
    case binding_error(binding, app_id) do
      nil -> diagnostics
      diagnostic -> [diagnostic | diagnostics]
    end
  end

  defp validate_binding(_binding, diagnostics, _app_id),
    do: [
      diagnostic(:invalid_action_binding, "Action binding must be an ActionBinding struct.")
      | diagnostics
    ]

  defp binding_error(%ActionBinding{} = binding, app_id) do
    cond do
      not is_binary(binding.action_name) or String.trim(binding.action_name) == "" ->
        diagnostic(:invalid_action_binding, "Action binding requires a non-empty action name.")

      unsafe_binding_value?(binding) ->
        diagnostic(:unsafe_action_binding, "Action binding contains an unsafe value.")

      true ->
        binding_capability_error(binding, ActionsRegistry.capability(binding.action_name), app_id)
    end
  end

  defp binding_capability_error(binding, {:ok, capability}, app_id) do
    cond do
      capability.permission == :command_execute ->
        diagnostic(
          :denied_action_binding,
          "Surface binding references a permanently denied action.",
          %{action_name: binding.action_name}
        )

      binding.action_module && binding.action_module != capability.module ->
        diagnostic(
          :invalid_action_binding,
          "Action binding module does not match the registered action.",
          %{action_name: binding.action_name}
        )

      capability.app_id && capability.app_id != app_id ->
        diagnostic(
          :foreign_action_binding,
          "Surface binding references an action owned by another app.",
          %{
            action_name: binding.action_name,
            surface_app_id: app_id,
            action_app_id: capability.app_id
          }
        )

      true ->
        nil
    end
  end

  defp binding_capability_error(binding, {:error, _reason}, _app_id) do
    diagnostic(:unknown_action_binding, "Action binding references an unknown action.", %{
      action_name: binding.action_name
    })
  end

  defp validate_nodes!(nodes) do
    Enum.map(nodes, fn node ->
      %{
        node
        | bindings: Enum.map(node.bindings, &enrich_binding/1),
          children: validate_nodes!(node.children)
      }
    end)
  end

  defp enrich_binding(binding) do
    case ActionsRegistry.capability(binding.action_name) do
      {:ok, capability} ->
        %{
          binding
          | action_module: capability.module,
            app_id: capability.app_id,
            plugin_id: capability.plugin_id,
            permission: capability.permission,
            confirmation_required?: capability.confirmation != :not_required
        }

      {:error, _reason} ->
        binding
    end
  end

  defp catalog_entry_diagnostics(%{} = entry, index) do
    component = catalog_component(entry)
    allowed_props = Map.get(entry, :allowed_props, Map.get(entry, "allowed_props", []))
    allowed_bindings = Map.get(entry, :allowed_bindings, Map.get(entry, "allowed_bindings", []))

    []
    |> require_member(component, Catalog.known_components(), :catalog_component)
    |> validate_atom_list(allowed_props, :catalog_allowed_props)
    |> validate_string_list(allowed_bindings, :catalog_allowed_bindings)
    |> Enum.map(&put_in(&1[:detail][:index], index))
  end

  defp catalog_entry_diagnostics(_entry, index),
    do: [diagnostic(:invalid_catalog_entry, "Catalog entry must be a map.", %{index: index})]

  defp catalog_component(entry), do: Map.get(entry, :component, Map.get(entry, "component"))

  defp validate_path(diagnostics, path) when is_binary(path) do
    cond do
      byte_size(path) not in 1..128 ->
        [diagnostic(:invalid_path, "Surface path must be 1..128 bytes.") | diagnostics]

      not String.starts_with?(path, "/") ->
        [diagnostic(:invalid_path, "Surface path must start with /.") | diagnostics]

      String.starts_with?(path, ["//", "http://", "https://"]) or
          String.contains?(path, ["://", "?", "#"]) ->
        [
          diagnostic(
            :invalid_path,
            "Surface path must be a local route without scheme, query, or fragment."
          )
          | diagnostics
        ]

      Regex.match?(~r/\s/, path) ->
        [diagnostic(:invalid_path, "Surface path must not contain whitespace.") | diagnostics]

      true ->
        diagnostics
    end
  end

  defp validate_path(diagnostics, _path),
    do: [diagnostic(:invalid_path, "Surface path must be a string.") | diagnostics]

  defp require_atom(diagnostics, value, _field) when is_atom(value) and not is_nil(value),
    do: diagnostics

  defp require_atom(diagnostics, _value, field),
    do: [
      diagnostic(:invalid_field, "Surface #{field} must be an atom.", %{field: field})
      | diagnostics
    ]

  defp require_bounded_string(diagnostics, value, _field, min, max)
       when is_binary(value) and byte_size(value) >= min and byte_size(value) <= max,
       do: diagnostics

  defp require_bounded_string(diagnostics, _value, field, min, max),
    do: [
      diagnostic(:invalid_field, "Surface #{field} must be a string #{min}..#{max} bytes.", %{
        field: field
      })
      | diagnostics
    ]

  defp require_member(diagnostics, value, values, field) do
    if value in values do
      diagnostics
    else
      [
        diagnostic(:invalid_field, "Surface #{field} is not allowed.", %{
          field: field,
          value: inspect(value)
        })
        | diagnostics
      ]
    end
  end

  defp validate_metadata(diagnostics, metadata)
       when is_map(metadata) and map_size(metadata) <= 64 do
    Enum.reduce(metadata, diagnostics, fn {key, value}, acc ->
      acc
      |> validate_metadata_key(key)
      |> validate_prop_value(key, value)
    end)
  end

  defp validate_metadata(diagnostics, _metadata),
    do: [diagnostic(:invalid_metadata, "Surface metadata must be a bounded map.") | diagnostics]

  defp validate_metadata_key(diagnostics, key) when is_atom(key) or is_binary(key) do
    validate_prop_key(diagnostics, key)
  end

  defp validate_metadata_key(diagnostics, key) do
    [
      diagnostic(:invalid_metadata, "Surface metadata keys must be atoms or strings.", %{
        key: inspect(key)
      })
      | diagnostics
    ]
  end

  defp validate_panel_contract(diagnostics, %{kind: :panel} = surface) do
    zone = normalized_surface_zone(surface)

    diagnostics
    |> validate_panel_zone(surface, zone)
    |> validate_panel_metadata(surface)
    |> validate_panel_nodes(surface.nodes)
  end

  defp validate_panel_contract(diagnostics, surface) do
    if normalized_surface_zone(surface) do
      [
        diagnostic(:unexpected_zone, "Only panel surfaces may target workspace zones.", %{
          surface_id: surface.id,
          kind: surface.kind
        })
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp validate_panel_zone(diagnostics, surface, zone) do
    top_level_zone = normalize_zone(surface.zone)
    metadata_zone = normalize_zone(metadata_value(surface.metadata, :zone))

    cond do
      is_nil(surface.zone) and is_nil(metadata_value(surface.metadata, :zone)) ->
        [
          diagnostic(:missing_panel_zone, "Panel surfaces must target a known workspace zone.", %{
            surface_id: surface.id,
            zones: Catalog.known_zones()
          })
          | diagnostics
        ]

      is_nil(zone) ->
        [
          diagnostic(:unknown_zone, "Panel surface targets an unknown workspace zone.", %{
            surface_id: surface.id,
            zone: inspect(surface.zone || metadata_value(surface.metadata, :zone)),
            zones: Catalog.known_zones()
          })
          | diagnostics
        ]

      top_level_zone && metadata_zone && top_level_zone != metadata_zone ->
        [
          diagnostic(:zone_conflict, "Panel surface has conflicting zone declarations.", %{
            surface_id: surface.id,
            zone: top_level_zone,
            metadata_zone: metadata_zone
          })
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  defp validate_panel_metadata(diagnostics, %{metadata: metadata}) when is_map(metadata) do
    diagnostics
    |> validate_visible_when(metadata_value(metadata, :visible_when))
    |> validate_panel_order(metadata_value(metadata, :order))
  end

  defp validate_panel_metadata(diagnostics, _surface), do: diagnostics

  defp validate_visible_when(diagnostics, nil), do: diagnostics

  defp validate_visible_when(diagnostics, value) do
    if normalize_visible_when(value) do
      diagnostics
    else
      [
        diagnostic(:invalid_visible_when, "Panel visible_when metadata is not allowed.", %{
          value: inspect(value),
          allowed: @known_visible_when
        })
        | diagnostics
      ]
    end
  end

  defp validate_panel_order(diagnostics, nil), do: diagnostics

  defp validate_panel_order(diagnostics, order) when is_integer(order) and order in 0..10_000,
    do: diagnostics

  defp validate_panel_order(diagnostics, order) do
    [
      diagnostic(:invalid_panel_order, "Panel order metadata must be an integer 0..10000.", %{
        value: inspect(order)
      })
      | diagnostics
    ]
  end

  defp validate_panel_nodes(diagnostics, nodes) when is_list(nodes) do
    cond do
      nodes == [] ->
        [
          diagnostic(:missing_panel_node, "Panel surfaces must include a panel root node.")
          | diagnostics
        ]

      Enum.any?(nodes, &match?(%Node{component: component} when component != :panel, &1)) ->
        [
          diagnostic(
            :invalid_panel_node,
            "Panel surface root nodes must use the panel component."
          )
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  defp validate_panel_nodes(diagnostics, _nodes), do: diagnostics

  defp normalized_surface_zone(surface) do
    normalize_zone(surface.zone) || normalize_zone(metadata_value(surface.metadata, :zone))
  end

  defp normalize_zone(zone) when is_atom(zone) do
    if Catalog.known_zone?(zone), do: zone
  end

  defp normalize_zone(zone) when is_binary(zone) do
    normalized = String.trim(zone)

    Enum.find(Catalog.known_zones(), &(Atom.to_string(&1) == normalized))
  end

  defp normalize_zone(_zone), do: nil

  defp normalize_visible_when(value) when is_atom(value) do
    if value in @known_visible_when, do: value
  end

  defp normalize_visible_when(value) when is_binary(value) do
    normalized = String.trim(value)

    Enum.find(@known_visible_when, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_visible_when(_value), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp validate_atom_list(diagnostics, values, _field) when is_list(values) do
    if Enum.all?(values, &is_atom/1),
      do: diagnostics,
      else: [
        diagnostic(:invalid_catalog_entry, "Catalog allowed_props must be atoms.") | diagnostics
      ]
  end

  defp validate_atom_list(diagnostics, _values, _field),
    do: [
      diagnostic(:invalid_catalog_entry, "Catalog allowed_props must be a list.") | diagnostics
    ]

  defp validate_string_list(diagnostics, values, _field) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: diagnostics,
      else: [
        diagnostic(:invalid_catalog_entry, "Catalog allowed_bindings must be strings.")
        | diagnostics
      ]
  end

  defp validate_string_list(diagnostics, _values, _field),
    do: [
      diagnostic(:invalid_catalog_entry, "Catalog allowed_bindings must be a list.") | diagnostics
    ]

  defp count_nodes(nodes), do: nodes |> flatten_nodes() |> length()

  defp flatten_nodes(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      %Node{children: children} = node -> [node | flatten_nodes(children)]
      node -> [node]
    end)
  end

  defp flatten_nodes(_nodes), do: []

  defp raw_html?(value) do
    value
    |> String.trim_leading()
    |> then(&(String.starts_with?(&1, "<") and String.contains?(&1, ">")))
  end

  defp unsafe_url_or_script?(value) do
    normalized = value |> String.trim_leading() |> String.downcase()

    String.starts_with?(normalized, ["javascript:", "data:", "http://", "https://", "//"]) or
      String.contains?(normalized, "<script")
  end

  defp unsafe_binding_value?(%ActionBinding{} = binding) do
    binding
    |> Map.from_struct()
    |> Enum.any?(fn {_key, value} -> unsafe_binding_term?(value) end)
  end

  defp unsafe_binding_term?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    String.starts_with?(normalized, [
      "javascript:",
      "data:",
      "http://",
      "https://",
      "//",
      "/",
      "~"
    ]) or
      String.contains?(normalized, [";", "&&", "||", "$(", "`", "<script"])
  end

  defp unsafe_binding_term?(_value), do: false

  defp diagnostic(kind, message, detail \\ %{}) do
    %{kind: kind, message: message, detail: detail}
  end
end
