defmodule Mix.Tasks.Allbert.Gen.Tool do
  @moduledoc """
  Generate an inert reviewed LLM-tool/action scaffold.
  """

  use Mix.Task

  alias Mix.Tasks.Allbert.Gen.Support

  @shortdoc "Generate an Allbert LLM-tool/action scaffold"
  @usage """
  Usage:

      mix allbert.gen.tool NAME [--target PATH] [--force] [--smoke]
      mix allbert.gen.tool NAME [--permission read_only|memory_write|external_network]

  Generated output is inert source for review. Operator live integration of the
  action shape still goes through the v0.36 sandbox gate and v0.37 loader.
  """

  @impl true
  def run(args) do
    Support.run_pattern("llm_tool", args, @usage)
  end
end
