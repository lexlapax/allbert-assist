defmodule AllbertArtifacts.SurfaceProvider do
  @moduledoc """
  Workspace surface provider for the Artifacts Browser panel.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertArtifacts.Panels.Browser

  @default_limit 6

  def workspace_panel_surfaces(context) when is_map(context) do
    filters = filters(context)

    case Runner.run("list_artifacts", list_params(context, filters), runner_context(context)) do
      {:ok, %{status: :completed, artifacts: artifacts}} ->
        [Browser.surface(artifacts, filters)]

      {:ok, response} ->
        [Browser.unavailable(response)]
    end
  end

  defp list_params(context, filters) do
    %{
      limit: context_value(context, :limit, @default_limit),
      user_id: context_value(context, :user_id),
      origin: context_value(context, :origin),
      mime: context_value(context, :mime),
      thread_id: Map.get(filters, :thread_id),
      since: Map.get(filters, :since),
      retention: Map.get(filters, :retention),
      lifecycle: Map.get(filters, :lifecycle)
    }
    |> Map.merge(filters)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp filters(context) do
    context
    |> context_value(:artifacts_browser_filters, %{})
    |> normalize_filters()
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

    filters =
      Map.get(context, :artifacts_browser_filters) ||
        Map.get(context, "artifacts_browser_filters") || %{}

    Map.get(context, key) ||
      Map.get(context, Atom.to_string(key)) ||
      Map.get(filters, key) ||
      Map.get(filters, Atom.to_string(key)) ||
      Map.get(request, key) ||
      Map.get(request, Atom.to_string(key)) ||
      default
  end

  defp normalize_filters(filters) when is_map(filters) do
    filters
    |> Enum.flat_map(fn {key, value} -> normalize_filter(key, value) end)
    |> Map.new()
  end

  defp normalize_filters(_filters), do: %{}

  defp normalize_filter(_key, value) when value in [nil, ""], do: []
  defp normalize_filter(key, value) when key in [:type, "type"], do: [{:mime, value}]
  defp normalize_filter(key, value) when key in [:thread, "thread"], do: [{:thread_id, value}]

  defp normalize_filter(key, value) when key in [:limit, "limit"] and is_integer(value),
    do: [{:limit, value}]

  defp normalize_filter(key, value) when key in [:limit, "limit"], do: parse_limit(value)

  defp normalize_filter(key, value)
       when key in [
              :mime,
              "mime",
              :origin,
              "origin",
              :thread_id,
              "thread_id",
              :since,
              "since",
              :retention,
              "retention",
              :lifecycle,
              "lifecycle"
            ] do
    [{normalize_key(key), value}]
  end

  defp normalize_filter(_key, _value), do: []

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> [{:limit, limit}]
      _other -> []
    end
  end

  defp parse_limit(_value), do: []
end
