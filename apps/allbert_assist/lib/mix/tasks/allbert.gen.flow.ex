defmodule Mix.Tasks.Allbert.Gen.Flow do
  @moduledoc """
  Generate inert reviewed scheduled-flow and objective-workflow scaffolds.
  """

  use Mix.Task

  alias Mix.Tasks.Allbert.Gen.Support

  @shortdoc "Generate an Allbert scheduled-flow or objective scaffold"
  @usage """
  Usage:

      mix allbert.gen.flow NAME [--target PATH] [--force]
      mix allbert.gen.flow NAME --pattern objective [--target PATH] [--force]

  Generated output is inert source for review. v0.38 does not live-integrate
  scheduled jobs or objective wiring.
  """

  @impl true
  def run(args) do
    Support.run_flow(args, @usage)
  end
end
