defmodule AllbertAssist.Workspace.EphemeralTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.Ephemeral
  alias Jido.Signal.Bus

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-ephemeral-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
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

  test "open and dismiss emit lifecycle signals" do
    thread_id = "thread-eph-events"
    user_id = "user-eph-events"

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.ephemeral.**")

    assert {:ok, surface} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "Approval"}
             })

    opened = receive_signal("allbert.workspace.ephemeral.opened")
    assert opened.data.surface_id == surface.id
    assert opened.data.user_id == user_id
    assert opened.data.thread_id == thread_id

    assert {:ok, dismissed} = Ephemeral.dismiss(surface.id, user_id, :operator)

    closed = receive_signal("allbert.workspace.ephemeral.closed")
    assert closed.data.surface_id == dismissed.id
    assert closed.data.dismissed_by == :operator
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

  test "dismiss is idempotent for an already dismissed surface in the same thread" do
    thread_id = "thread-eph-idempotent"
    user_id = "user-eph-idempotent"

    assert {:ok, surface} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "Approval"}
             })

    assert {:ok, first} = Ephemeral.dismiss(surface.id, user_id, :operator, thread_id: thread_id)
    assert {:ok, second} = Ephemeral.dismiss(surface.id, user_id, :operator, thread_id: thread_id)

    assert second.id == first.id
    assert second.dismissed_by == "operator"

    assert {:error, :not_found} =
             Ephemeral.dismiss(surface.id, user_id, :operator, thread_id: "other-thread")
  end

  test "open reactivates a dismissed surface id in the same thread" do
    thread_id = "thread-eph-reopen"
    user_id = "user-eph-reopen"

    assert {:ok, surface} =
             Ephemeral.open(%{
               id: "eph_reopen_same_prompt",
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "Approval", sequence: 1},
               metadata: %{sequence: 1}
             })

    assert {:ok, dismissed} = Ephemeral.dismiss(surface.id, user_id, :operator)
    assert dismissed.dismissed_by == "operator"

    assert {:ok, reopened} =
             Ephemeral.open(%{
               id: surface.id,
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "Approval", sequence: 2},
               metadata: %{sequence: 2}
             })

    assert reopened.id == surface.id
    assert is_nil(reopened.dismissed_at)
    assert is_nil(reopened.dismissed_by)
    assert reopened.body == %{"sequence" => 2, "title" => "Approval"}
    assert (reopened.metadata[:sequence] || reopened.metadata["sequence"]) == 2

    assert {:ok, [active]} = Ephemeral.surfaces_for_thread(thread_id, user_id)
    assert active.id == surface.id
    assert active.body == %{"sequence" => 2, "title" => "Approval"}
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

  defp receive_signal(type) do
    receive do
      {:signal, %{type: ^type} = signal} -> signal
      {:signal, _signal} -> receive_signal(type)
    after
      1_000 -> flunk("expected signal #{type}")
    end
  end
end
