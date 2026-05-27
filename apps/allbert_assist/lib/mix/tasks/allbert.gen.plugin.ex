defmodule Mix.Tasks.Allbert.Gen.Plugin do
  @moduledoc """
  Generate an inert source-tree Allbert plugin scaffold.

  ## Usage

      mix allbert.gen.plugin NAME [--target PATH] [--force]
  """

  use Mix.Task

  alias Mix.Tasks.Allbert.Gen.Support

  @shortdoc "Generate an inert Allbert plugin scaffold"

  @impl true
  def run(args) do
    Support.run_pattern("plugin", args, usage())
  end

  defp usage do
    """
    Usage:
      mix allbert.gen.plugin NAME [--target PATH] [--force]
    """
  end
end
