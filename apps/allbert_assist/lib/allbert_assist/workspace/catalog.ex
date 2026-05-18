defmodule AllbertAssist.Workspace.Catalog do
  @moduledoc """
  Workspace component catalog metadata.

  v0.26 expands the Surface catalog to the 42 components used by the
  workspace shell, canvas tiles, ephemeral surfaces, and reserved StockSage
  cards. Renderer dispatch lands in later v0.26 milestones; this module is
  the metadata foundation.
  """

  @spec known_components() :: [AllbertAssist.Surface.component(), ...]
  def known_components, do: AllbertAssist.Surface.known_components()

  @spec component_renderer(atom()) :: {:error, :renderer_not_implemented | :unknown_component}
  def component_renderer(component) do
    if component in known_components() do
      {:error, :renderer_not_implemented}
    else
      {:error, :unknown_component}
    end
  end
end
