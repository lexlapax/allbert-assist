defmodule AllbertResearch.Commands.SummarizeUrl do
  @moduledoc false

  use Jido.Action,
    name: "allbert_research_summarize_url",
    description: "Run delegated browser extraction and summary for one URL."

  alias AllbertResearch.Research
  alias AllbertAssist.Objectives.Runs.CancelToken

  @impl true
  def run(params, context) do
    params =
      case field(params, :url) do
        url when is_binary(url) and url != "" -> Map.put(params, :sources, [url])
        _other -> params
      end

    case CancelToken.checkpoint(params) do
      :ok -> Research.run(:summarize_url, params, context)
      :cancelled -> {:ok, %{last_result: {:error, :cancelled}}}
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
