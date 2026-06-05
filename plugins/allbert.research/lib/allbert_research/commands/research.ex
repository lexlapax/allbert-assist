defmodule AllbertResearch.Commands.Research do
  @moduledoc false

  use Jido.Action,
    name: "allbert_research_research",
    description: "Run bounded delegated browser research."

  alias AllbertResearch.Research

  @impl true
  def run(params, context) do
    Research.run(:research, params, context)
  end
end
