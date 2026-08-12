defmodule AllbertResearch.Settings.Fragment do
  @moduledoc """
  Settings Central schema fragment for the v0.46 research specialist.
  """

  @doc "Return the research plugin settings schema fragment."
  def schema do
    [
      schema("research.enabled", :boolean, false),
      schema("research.schema_version", :positive_integer, 1, writable?: false),
      schema("research.max_sources", :bounded_integer, 3, min: 1, max: 8),
      schema("research.max_extract_bytes_per_source", :bounded_integer, 524_288,
        min: 1_024,
        max: 1_048_576
      ),
      schema("research.summary.engine", :enum, "extractive_fallback",
        writable?: false,
        allowed_values: ["extractive_fallback"]
      )
    ]
  end

  defp schema(key, type, default, opts \\ []) do
    %{
      key: key,
      type: type,
      default: default,
      writable?: Keyword.get(opts, :writable?, true),
      sensitive?: Keyword.get(opts, :sensitive?, false)
    }
    |> maybe_put(:allowed_values, Keyword.get(opts, :allowed_values))
    |> maybe_put(:min, Keyword.get(opts, :min))
    |> maybe_put(:max, Keyword.get(opts, :max))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
