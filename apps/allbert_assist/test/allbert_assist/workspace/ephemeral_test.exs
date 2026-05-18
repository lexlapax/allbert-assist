defmodule AllbertAssist.Workspace.EphemeralTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Workspace.Ephemeral

  test "open lists and dismisses per-thread ephemeral surfaces" do
    thread_id = "thread-eph-crud"
    user_id = "user-eph-crud"

    assert {:ok, surface} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "Approval"}
             })

    assert surface.body == %{"title" => "Approval"}
    assert {:ok, [listed]} = Ephemeral.surfaces_for_thread(thread_id, user_id)
    assert listed.id == surface.id

    assert {:ok, dismissed} = Ephemeral.dismiss(surface.id, user_id, :operator)
    assert dismissed.dismissed_by == "operator"
    assert {:ok, []} = Ephemeral.surfaces_for_thread(thread_id, user_id)

    assert {:ok, [historical]} =
             Ephemeral.surfaces_for_thread(thread_id, user_id, include_dismissed: true)

    assert historical.id == surface.id
  end

  test "cap enforcement dismisses oldest non-pinned surface" do
    thread_id = "thread-eph-cap"
    user_id = "user-eph-cap"

    surfaces =
      for index <- 1..16 do
        assert {:ok, surface} =
                 Ephemeral.open(%{
                   thread_id: thread_id,
                   user_id: user_id,
                   kind: :approval_card,
                   body: %{title: "surface #{index}"},
                   pinned: index == 1
                 })

        surface
      end

    assert {:ok, _overflow} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "overflow"}
             })

    assert {:ok, all_surfaces} =
             Ephemeral.surfaces_for_thread(thread_id, user_id, include_dismissed: true)

    pinned = Enum.find(all_surfaces, &(&1.id == List.first(surfaces).id))
    evicted = Enum.find(all_surfaces, &(&1.id == Enum.at(surfaces, 1).id))

    assert is_nil(pinned.dismissed_at)
    assert evicted.dismissed_by == "cap_evicted"
  end
end
