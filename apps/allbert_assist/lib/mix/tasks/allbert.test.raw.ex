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
    reach_ambient_applications()
    Test.run(args)
  end

  # v1.4 M13.2. The closed projection reconciles metadata for every application
  # in the release, and `Application.app_dir/2` raises for one whose ebin is not
  # on the code path. The applications ABOVE Web -- artifacts and stocksage since
  # M13 -- are in no owner's dependency closure, so an owner-scoped VM never
  # reaches them on its own, while `Test.run/1` starts a closure that reaches the
  # composition host. Composition's first attempt then fails closed on an
  # unloaded application and the coordinator crash-cascades until a test helper
  # catches up. Recovery usually won; one M13 closeout census run did not.
  #
  # This is the last point before applications start, and it is here rather than
  # in a child `test` alias precisely because this task bypasses those by design.
  #
  # Unconditional, including for an owner that will never build a projection.
  # Putting these two on the code path cannot mask a missing dependency
  # declaration -- the usual objection, and the reason `ensure_loaded!/1` is not
  # a blanket prepend -- because nothing in the umbrella is permitted to depend
  # on an application above Web at all, and the R0 acyclic DAG proof enforces
  # that independently of anything here.
  defp reach_ambient_applications do
    if Code.ensure_loaded?(AllbertAssist.TestSupport.PackBootstrap) do
      AllbertAssist.TestSupport.PackBootstrap.ensure_ambient_reachable!()
    end
  end
end
