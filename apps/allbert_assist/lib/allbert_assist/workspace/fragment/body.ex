defmodule AllbertAssist.Workspace.Fragment.Body do
  @moduledoc """
  Encodes and decodes validated FragmentEnvelope bodies for workspace storage.

  The canvas and ephemeral stores persist plain maps in YAML. This module keeps
  the declarative Surface tree recoverable without making the stores know about
  fragment provenance or Surface internals.

  v0.31 keeps this module as the internal fragment-body codec. New
  runtime-facing code should call `AllbertAssist.Runtime.Persistence`.
  """

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.ActionBinding
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Envelope

  @type decode_error :: :invalid_fragment_body

  @spec encode(Envelope.t()) :: map()
  def encode(%Envelope{} = envelope) do
    %{
      fragment: %{
        id: envelope.id,
        emitter_id: envelope.emitter_id,
        emitted_at: envelope.emitted_at,
        scope: envelope.scope,
        kind: envelope.kind,
        metadata: envelope.metadata
      },
      surface: encode_surface(envelope.surface)
    }
  end

  @spec surface_from_body(map()) :: {:ok, Surface.t()} | {:error, decode_error()}
  def surface_from_body(body) when is_map(body) do
    with {:ok, surface} <- body |> value(:surface) |> decode_surface(),
         {:ok, surface} <- Surface.validate_surface(surface) do
      {:ok, surface}
    else
      _error -> {:error, :invalid_fragment_body}
    end
  end

  def surface_from_body(_body), do: {:error, :invalid_fragment_body}

  defp encode_surface(%Surface{} = surface) do
    %{
      id: surface.id,
      app_id: surface.app_id,
      label: surface.label,
      path: surface.path,
      kind: surface.kind,
      zone: surface.zone,
      status: surface.status,
      nodes: Enum.map(surface.nodes, &encode_node/1),
      fallback_text: surface.fallback_text,
      metadata: surface.metadata
    }
  end

  defp encode_node(%Node{} = node) do
    %{
      id: node.id,
      component: node.component,
      props: node.props,
      children: Enum.map(node.children, &encode_node/1),
      bindings: Enum.map(node.bindings, &encode_binding/1)
    }
  end

  defp encode_binding(%ActionBinding{} = binding) do
    %{
      action_name: binding.action_name,
      action_module: binding.action_module,
      app_id: binding.app_id,
      plugin_id: binding.plugin_id,
      permission: binding.permission,
      confirmation_required?: binding.confirmation_required?
    }
  end

  defp decode_surface(%{} = attrs) do
    with {:ok, id} <- atom_value(value(attrs, :id)),
         {:ok, app_id} <- atom_value(value(attrs, :app_id)),
         {:ok, kind} <- atom_value(value(attrs, :kind)),
         {:ok, status} <- atom_value(value(attrs, :status)),
         {:ok, nodes} <- decode_nodes(value(attrs, :nodes) || []),
         {:ok, metadata} <- map_value(value(attrs, :metadata) || %{}) do
      {:ok,
       %Surface{
         id: id,
         app_id: app_id,
         label: value(attrs, :label),
         path: value(attrs, :path),
         kind: kind,
         zone: optional_zone_value(value(attrs, :zone)),
         status: status,
         nodes: nodes,
         fallback_text: value(attrs, :fallback_text),
         metadata: metadata
       }}
    end
  end

  defp decode_surface(_attrs), do: {:error, :invalid_fragment_body}

  defp decode_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn node_attrs, {:ok, nodes} ->
      case decode_node(node_attrs) do
        {:ok, node} -> {:cont, {:ok, [node | nodes]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_nodes(_nodes), do: {:error, :invalid_fragment_body}

  defp decode_node(%{} = attrs) do
    with {:ok, component} <- component_value(value(attrs, :component)),
         {:ok, props} <- map_value(value(attrs, :props) || %{}),
         {:ok, children} <- decode_nodes(value(attrs, :children) || []),
         {:ok, bindings} <- decode_bindings(value(attrs, :bindings) || []) do
      {:ok,
       %Node{
         id: value(attrs, :id),
         component: component,
         props: props,
         children: children,
         bindings: bindings
       }}
    end
  end

  defp decode_node(_attrs), do: {:error, :invalid_fragment_body}

  defp decode_bindings(bindings) when is_list(bindings) do
    bindings
    |> Enum.reduce_while({:ok, []}, fn binding_attrs, {:ok, bindings} ->
      case decode_binding(binding_attrs) do
        {:ok, binding} -> {:cont, {:ok, [binding | bindings]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_bindings(_bindings), do: {:error, :invalid_fragment_body}

  defp decode_binding(%{} = attrs) do
    with {:ok, action_module} <- optional_module_value(value(attrs, :action_module)),
         {:ok, app_id} <- optional_atom_value(value(attrs, :app_id)),
         {:ok, permission} <- optional_atom_value(value(attrs, :permission)) do
      {:ok,
       %ActionBinding{
         action_name: value(attrs, :action_name),
         action_module: action_module,
         app_id: app_id,
         plugin_id: value(attrs, :plugin_id),
         permission: permission,
         confirmation_required?: value(attrs, :confirmation_required?)
       }}
    end
  end

  defp decode_binding(_attrs), do: {:error, :invalid_fragment_body}

  defp value(map, key), do: AllbertAssist.Maps.field_truthy(map, key)

  defp map_value(value) when is_map(value), do: {:ok, value}
  defp map_value(_value), do: {:error, :invalid_fragment_body}

  defp component_value(value) when is_atom(value) do
    if value in Surface.known_components(),
      do: {:ok, value},
      else: {:error, :invalid_fragment_body}
  end

  defp component_value(value) when is_binary(value) do
    Surface.known_components()
    |> Enum.find(&(Atom.to_string(&1) == value))
    |> case do
      nil -> {:error, :invalid_fragment_body}
      component -> {:ok, component}
    end
  end

  defp component_value(_value), do: {:error, :invalid_fragment_body}

  defp optional_atom_value(nil), do: {:ok, nil}
  defp optional_atom_value(value), do: atom_value(value)

  defp optional_zone_value(nil), do: nil

  defp optional_zone_value(value) do
    case optional_atom_value(value) do
      {:ok, zone} -> zone
      {:error, :invalid_fragment_body} -> nil
    end
  end

  defp atom_value(value) when is_atom(value) and not is_nil(value), do: {:ok, value}

  defp atom_value(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, :invalid_fragment_body}
  end

  defp atom_value(_value), do: {:error, :invalid_fragment_body}

  defp optional_module_value(nil), do: {:ok, nil}
  defp optional_module_value(module) when is_atom(module), do: {:ok, module}

  defp optional_module_value(module) when is_binary(module) do
    module
    |> String.replace_prefix("Elixir.", "")
    |> then(&String.to_existing_atom("Elixir." <> &1))
    |> then(&{:ok, &1})
  rescue
    ArgumentError -> {:error, :invalid_fragment_body}
  end

  defp optional_module_value(_module), do: {:error, :invalid_fragment_body}
end
