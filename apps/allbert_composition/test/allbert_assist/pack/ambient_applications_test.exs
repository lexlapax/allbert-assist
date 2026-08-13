defmodule AllbertAssist.Pack.AmbientApplicationsTest do
  @moduledoc """
  v1.4 M13.2. The closed projection reconciles metadata for every application in
  the release, and `Application.app_dir/2` raises for one whose ebin the code
  path cannot resolve. Most arrive through some owner's dependency closure. The
  ones ABOVE Web -- artifacts and stocksage since M13 -- do not: nothing depends
  on them, so an owner-scoped test VM only has them because a test helper went
  and got them.

  That is a precondition with a real failure mode, and it held only by accident
  in the composition owner's VM, where Web itself was reachable but never
  loaded. Asserting it directly is cheap; finding it again from an intermittent
  lane failure was not.
  """

  use ExUnit.Case, async: true

  alias AllbertAssist.Pack.ProjectionProvider

  @moduletag :pure_async

  test "every application the closed projection reconciles is loaded in this VM" do
    unloaded = Enum.reject(ProjectionProvider.closed_applications(), &Application.spec(&1, :vsn))

    assert unloaded == [],
           """
           The closed projection cannot resolve #{inspect(unloaded)}.

           `Application.app_dir/2` raises for an application the code path does \
           not resolve, so composition fails closed on the first one it reads. \
           Whatever is missing is in no owner's dependency closure -- load it in \
           the test helpers that build a projection.
           """
  end
end
