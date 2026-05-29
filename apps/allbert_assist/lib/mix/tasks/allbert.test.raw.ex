defmodule Mix.Tasks.Allbert.Test.Raw do
  @moduledoc """
  Run ExUnit directly for v0.41 developer gate orchestration.

  This task intentionally bypasses child-app `test` aliases. The outer
  `allbert.test` gate owns database/home setup before invoking raw test shards.
  """

  use Mix.Task

  alias Mix.Tasks.Test

  @shortdoc "Run ExUnit without child-app test aliases"

  @impl true
  def run(args) do
    Test.run(args)
  end
end
