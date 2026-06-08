defmodule AllbertArtifacts.SurfaceProvider do
  @moduledoc """
  Workspace surface provider for the Artifacts Browser panel.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertArtifacts.Panels.Browser

  @default_limit 6

  def workspace_panel_surfaces(context) when is_map(context) do
    case Runner.run("list_artifacts", list_params(context), runner_context(context)) do
      {:ok, %{status: :completed, artifacts: artifacts}} ->
        [Browser.surface(artifacts)]

      {:ok, response} ->
        [Browser.unavailable(response)]
    end
  end

  defp list_params(context) do
    %{
      limit: context_value(context, :limit, @default_limit),
      user_id: context_value(context, :user_id),
      origin: context_value(context, :origin),
      mime: context_value(context, :mime)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp runner_context(context) do
    Map.merge(context, %{
      app_id: :allbert_artifacts,
      active_app: :allbert_artifacts,
      channel: context_value(context, :channel, :workspace),
      surface: "artifacts_browser_panel"
    })
  end

  defp context_value(context, key, default \\ nil) do
    request = Map.get(context, :request) || Map.get(context, "request") || %{}

    Map.get(context, key) ||
      Map.get(context, Atom.to_string(key)) ||
      Map.get(request, key) ||
      Map.get(request, Atom.to_string(key)) ||
      default
  end
end
