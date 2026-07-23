defmodule AllbertResearch.Commands.Research do
  @moduledoc false

  use Jido.Action,
    name: "allbert_research_research",
    description: "Run bounded delegated browser research."

  alias AllbertResearch.Research
  alias AllbertAssist.Objectives.Runs.CancelToken

  @impl true
  def run(params, context) do
    case CancelToken.checkpoint(params) do
      :ok -> Research.run(:research, params, context)
      :cancelled -> {:ok, %{last_result: {:error, :cancelled}}}
    end
  end
end
