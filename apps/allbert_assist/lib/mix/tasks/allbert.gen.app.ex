defmodule Mix.Tasks.Allbert.Gen.App do
  @moduledoc """
  Generate an inert plugin-contributed Allbert workspace app scaffold.

  ## Usage

      mix allbert.gen.app NAME [--target PATH] [--force] [--smoke]
  """

  use Mix.Task

  alias Mix.Tasks.Allbert.Gen.Support

  @shortdoc "Generate an inert Allbert workspace app scaffold"

  @impl true
  def run(args) do
    Support.run_pattern("app", args, usage())
  end

  defp usage do
    """
    Usage:
      mix allbert.gen.app NAME [--target PATH] [--force] [--smoke]
    """
  end
end
