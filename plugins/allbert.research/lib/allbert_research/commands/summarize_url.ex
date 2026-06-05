defmodule AllbertResearch.Commands.SummarizeUrl do
  @moduledoc false

  use Jido.Action,
    name: "allbert_research_summarize_url",
    description: "Run delegated browser extraction and summary for one URL."

  alias AllbertResearch.Research

  @impl true
  def run(params, context) do
    params =
      case field(params, :url) do
        url when is_binary(url) and url != "" -> Map.put(params, :sources, [url])
        _other -> params
      end

    Research.run(:summarize_url, params, context)
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
