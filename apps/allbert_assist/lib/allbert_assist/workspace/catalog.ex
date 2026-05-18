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

  @spec known_components() :: [AllbertAssist.Surface.component(), ...]
  def known_components, do: AllbertAssist.Surface.known_components()

  @spec workspace_tree(keyword() | map()) :: Surface.t()
  def workspace_tree(context \\ %{}) do
    :agent
    |> core_surface!()
    |> Map.update!(:metadata, &Map.merge(&1 || %{}, workspace_metadata(context)))
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

  defp workspace_metadata(context) when is_list(context) do
    context
    |> Map.new()
    |> workspace_metadata()
  end

  defp workspace_metadata(context) when is_map(context) do
    context
    |> Map.take([:user_id, :thread_id])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> then(&%{workspace: &1})
  end
end
