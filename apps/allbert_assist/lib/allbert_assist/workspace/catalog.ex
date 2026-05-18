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
          body: "kind=#{tile.kind}",
          tile_id: tile.id
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
          surface_id: surface.id
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
