defmodule AllbertBrowser.SurfaceProvider do
  @moduledoc """
  Workspace surface provider for Browser app panels.
  """

  alias AllbertBrowser.Cache
  alias AllbertBrowser.Panels.Results

  def workspace_panel_surfaces(_context) do
    [Results.surface(Cache.latest_artifacts(limit: 6))]
  end
end
