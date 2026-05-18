defmodule AllbertAssist.Surface do
  @moduledoc """
  Local declarative surface DSL for app-provided Allbert surfaces.

  This module validates source-tree surface data before it reaches a renderer.
  It is metadata, not executable UI code.
  """

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Surface.ActionBinding
  alias AllbertAssist.Surface.Node

  defstruct [
    :id,
    :app_id,
    :label,
    :path,
    :kind,
    :status,
    nodes: [],
    fallback_text: "",
    metadata: %{}
  ]

  @known_components [
    :route,
    :chat,
    :timeline,
    :composer,
    :panel,
    :section,
    :text,
    :list,
    :empty_state,
    :button,
    :action_button,
    :status_badge,
    :workspace,
    :canvas,
    :tile,
    :ephemeral_surface,
    :header,
    :badge_strip,
    :tabs,
    :tab,
    :tab_panel,
    :diff,
    :trace_link,
    :trace_viewer,
    :icon,
    :link,
    :divider,
    :table,
    :row,
    :column,
    :objective_card,
    :confirmation_card,
    :approval_card,
    :approval_inspector,
    :memory_review_card,
    :job_card,
    :channel_card,
    :settings_card,
    :analysis_card,
    :agent_report_card,
    :parity_card,
    :debate_round_card
  ]

  @known_kinds [:route, :chat, :workspace, :analysis, :canvas, :settings]
  @known_statuses [:available, :placeholder, :disabled]
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
          status: atom(),
          nodes: [Node.t()],
          fallback_text: String.t(),
          metadata: map()
        }

  @spec known_components() :: [component(), ...]
  def known_components, do: @known_components

  @spec validate_surface(t()) :: {:ok, t()} | {:error, [diagnostic()]}
  def validate_surface(%__MODULE__{} = surface) do
    diagnostics =
      []
      |> validate_surface_shape(surface)
      |> validate_surface_nodes(surface)

    if diagnostics == [] do
      {:ok, %{surface | nodes: validate_nodes!(surface.nodes)}}
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
  end

  defp validate_surface_nodes(diagnostics, surface) do
    node_count = count_nodes(surface.nodes)

    diagnostics
    |> validate_node_count(node_count)
    |> validate_duplicate_node_ids(surface.nodes)
    |> validate_node_list(surface.nodes)
  end

  defp validate_node_count(diagnostics, count) when count <= 256, do: diagnostics

  defp validate_node_count(diagnostics, count),
    do: [
      diagnostic(:surface_too_large, "Surface has too many nodes.", %{count: count}) | diagnostics
    ]

  defp validate_node_list(diagnostics, nodes) when is_list(nodes) do
    Enum.reduce(nodes, diagnostics, &validate_node/2)
  end

  defp validate_node_list(diagnostics, _nodes),
    do: [diagnostic(:invalid_nodes, "Surface nodes must be a list.") | diagnostics]

  defp validate_node(%Node{} = node, diagnostics) do
    diagnostics
    |> require_bounded_string(node.id, :node_id, 1, 64)
    |> require_member(node.component, @known_components, :component)
    |> validate_props(node.props)
    |> validate_bindings(node.bindings)
    |> validate_node_list(node.children)
  end

  defp validate_node(_node, diagnostics),
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

  defp validate_bindings(diagnostics, bindings) when is_list(bindings) do
    Enum.reduce(bindings, diagnostics, &validate_binding/2)
  end

  defp validate_bindings(diagnostics, _bindings),
    do: [diagnostic(:invalid_bindings, "Surface action bindings must be a list.") | diagnostics]

  defp validate_binding(%ActionBinding{} = binding, diagnostics) do
    case binding_error(binding) do
      nil -> diagnostics
      diagnostic -> [diagnostic | diagnostics]
    end
  end

  defp validate_binding(_binding, diagnostics),
    do: [
      diagnostic(:invalid_action_binding, "Action binding must be an ActionBinding struct.")
      | diagnostics
    ]

  defp binding_error(%ActionBinding{} = binding) do
    cond do
      not is_binary(binding.action_name) or String.trim(binding.action_name) == "" ->
        diagnostic(:invalid_action_binding, "Action binding requires a non-empty action name.")

      unsafe_binding_value?(binding) ->
        diagnostic(:unsafe_action_binding, "Action binding contains an unsafe value.")

      true ->
        binding_capability_error(binding, ActionsRegistry.capability(binding.action_name))
    end
  end

  defp binding_capability_error(binding, {:ok, capability}) do
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

      true ->
        nil
    end
  end

  defp binding_capability_error(binding, {:error, _reason}) do
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
    component = Map.get(entry, :component, Map.get(entry, "component"))
    allowed_props = Map.get(entry, :allowed_props, Map.get(entry, "allowed_props", []))
    allowed_bindings = Map.get(entry, :allowed_bindings, Map.get(entry, "allowed_bindings", []))

    []
    |> require_member(component, @known_components, :catalog_component)
    |> validate_atom_list(allowed_props, :catalog_allowed_props)
    |> validate_string_list(allowed_bindings, :catalog_allowed_bindings)
    |> Enum.map(&put_in(&1[:detail][:index], index))
  end

  defp catalog_entry_diagnostics(_entry, index),
    do: [diagnostic(:invalid_catalog_entry, "Catalog entry must be a map.", %{index: index})]

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
       when is_map(metadata) and map_size(metadata) <= 64,
       do: diagnostics

  defp validate_metadata(diagnostics, _metadata),
    do: [diagnostic(:invalid_metadata, "Surface metadata must be a bounded map.") | diagnostics]

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
