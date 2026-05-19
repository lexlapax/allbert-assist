defmodule AllbertAssist.Workspace.EphemeralTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.Ephemeral

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-ephemeral-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

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

  test "dismiss_for_thread dismisses every active surface for a user thread" do
    thread_id = "thread-eph-close"
    user_id = "user-eph-close"

    assert {:ok, first} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "first"}
             })

    assert {:ok, second} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :trace_viewer,
               body: %{title: "second"}
             })

    assert {:ok, other_thread} =
             Ephemeral.open(%{
               thread_id: "other-thread",
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "other"}
             })

    assert {:ok, dismissed} = Ephemeral.dismiss_for_thread(thread_id, user_id, :thread_closed)
    assert Enum.map(dismissed, & &1.id) == [first.id, second.id]
    assert Enum.all?(dismissed, &(&1.dismissed_by == "thread_closed"))

    assert {:ok, []} = Ephemeral.surfaces_for_thread(thread_id, user_id)
    assert {:ok, [still_active]} = Ephemeral.surfaces_for_thread("other-thread", user_id)
    assert still_active.id == other_thread.id
  end

  test "registered dismissal action dismisses through workspace write permission metadata" do
    thread_id = "thread-eph-action"
    user_id = "user-eph-action"

    assert {:ok, surface} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "Approval"}
             })

    assert {:ok, response} =
             Runner.run(
               "dismiss_workspace_ephemeral",
               %{surface_id: surface.id, user_id: user_id, dismissed_by: "operator"},
               %{actor: user_id, user_id: user_id, channel: :test}
             )

    assert response.status == :completed
    assert response.surface_id == surface.id
    assert response.runner_metadata.action_name == "dismiss_workspace_ephemeral"
    assert response.runner_metadata.permission_decision.permission == :workspace_canvas_write
    assert response.actions |> List.first() |> Map.fetch!(:permission) == :workspace_canvas_write

    assert {:ok, []} = Ephemeral.surfaces_for_thread(thread_id, user_id)
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
