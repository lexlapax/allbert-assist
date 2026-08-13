defmodule AllbertAssist.Pack.AmbientApplicationsTest do
  @moduledoc """
  v1.4 M13.2. The closed projection reconciles metadata for every application in
  the release, and `Application.app_dir/2` raises for one that is built but not
  loaded. Most of them arrive through some owner's dependency closure. The ones
  ABOVE Web do not: nothing depends on them, so an owner-scoped test VM has to
  load them explicitly, from a Mix alias, before the `test` task starts anything.

  `PackBootstrap.ambient_applications/0` is that roster, and it is written out
  because it runs before the projection can be asked. A written-out roster is
  the defect ADR 0098 catalogued, so this derives the same set from the
  projection and the real dependency closure. If a later release adds an
  application above Web, this fails here rather than intermittently in whichever
  lane loses the composition race.
  """

  use ExUnit.Case, async: true

  alias AllbertAssist.Pack.ProjectionProvider
  alias AllbertAssist.TestSupport.PackBootstrap

  @moduletag :pure_async

  # Web is the ceiling: everything Web can reach is loaded by depending on it,
  # and everything that depends on Web is not.
  @ceiling :allbert_assist_web

  test "the ambient roster is exactly the projection's applications above Web" do
    below_or_at_ceiling = closure(@ceiling)

    above_web =
      ProjectionProvider.closed_applications()
      |> Enum.reject(&MapSet.member?(below_or_at_ceiling, &1))
      |> Enum.sort()

    assert above_web == Enum.sort(PackBootstrap.ambient_applications()),
           """
           The applications above Web changed. Whatever is newly above it is not \
           loaded by any owner's dependency closure, so composition's first \
           attempt will fail closed on it and the coordinator will crash-cascade \
           until a test helper catches up -- intermittently, which is how M13.2 \
           found this.

           Add it to PackBootstrap.ambient_applications/0.
           """
  end

  test "every application the projection reconciles is loaded in this VM" do
    unloaded =
      Enum.reject(ProjectionProvider.closed_applications(), &Application.spec(&1, :vsn))

    assert unloaded == [],
           "the closed projection cannot resolve #{inspect(unloaded)}: " <>
             "Application.app_dir/2 raises for an application that is built but not loaded"
  end

  defp closure(application), do: walk(application, MapSet.new())

  defp walk(application, seen) do
    if MapSet.member?(seen, application) do
      seen
    else
      seen = MapSet.put(seen, application)
      Enum.reduce(Application.spec(application, :applications) || [], seen, &walk(&1, &2))
    end
  end
end
