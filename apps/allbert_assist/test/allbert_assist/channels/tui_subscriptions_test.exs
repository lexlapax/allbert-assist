defmodule AllbertAssist.Channels.TUISubscriptionsTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Channels.TUI.Subscriptions
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias Jido.Signal

  test "renders only signals owned by the attached identity map" do
    assert {:ok, alice} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Owned fan-out",
               objective: "owned",
               fanout_role: "parent"
             })

    assert {:ok, mallory} =
             Objectives.create_objective(%{
               user_id: "mallory",
               title: "Foreign fan-out",
               objective: "foreign",
               fanout_role: "parent"
             })

    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]

    owned =
      Signal.new!("allbert.objectives.fanout.joined", %{parent_id: alice.id, title: alice.title})

    foreign = Signal.new!("allbert.objectives.fanout.joined", %{parent_id: mallory.id})

    assert Subscriptions.attached_user_signal?(owned, identity_map)
    refute Subscriptions.attached_user_signal?(foreign, identity_map)
    assert Subscriptions.status_line(owned) == "[fan-out] fanout joined: Owned fan-out"
  end

  test "disabled sessions do not register" do
    assert {:ok, nil} = Subscriptions.register(false)
    assert :ok = Subscriptions.unregister(nil)
  end

  test "joined delivery is durable, result-bearing, and owned" do
    assert {:ok, %{parent: parent, children: [completed, cancelled]}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_channel: "tui",
                 source_thread_id: "thread-attached",
                 title: "Attached results",
                 objective: "Render the durable report"
               },
               ["completed task", "cancelled task"]
             )

    assert {:ok, _transition} =
             TerminalTransitions.terminalize_child(
               completed,
               %{
                 status: "completed",
                 last_observation_summary: "completed result",
                 completed_at: DateTime.utc_now()
               },
               "run_completed",
               %{}
             )

    assert {:ok, _transition} =
             TerminalTransitions.terminalize_child(
               cancelled,
               %{
                 status: "cancelled",
                 review_reason: "cancelled by operator",
                 completed_at: DateTime.utc_now()
               },
               "run_cancelled",
               %{}
             )

    signal = Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})
    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]

    assert {:ok, delivery} = Subscriptions.delivery(signal, identity_map)
    assert delivery.parent_id == parent.id

    assert delivery.lines == [
             "[fan-out] fanout joined: Attached results",
             "Attached results — partial: ✓ completed task — completed result; ⊘ cancelled task — cancelled by operator"
           ]

    assert :ignore =
             Subscriptions.delivery(signal, [
               %{"external_user_id" => "local", "user_id" => "mallory", "enabled" => true}
             ])
  end

  test "same-user remote channels and other TUI profiles are not attached deliveries" do
    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]
    attachment = %{channel: "tui", receiver_account_ref: "tui:default"}

    for {source_channel, receiver_account_ref} <- [
          {"telegram", "telegram:bot:test"},
          {"tui", "tui:other-profile"}
        ] do
      assert {:ok, %{parent: parent, children: children}} =
               Fanout.frame(
                 %{
                   user_id: "alice",
                   source_channel: source_channel,
                   source_thread_id: "thread-#{source_channel}",
                   origin_receiver_account_ref: receiver_account_ref,
                   title: "Other origin",
                   objective: "Do not consume here"
                 },
                 ["one", "two"]
               )

      Enum.each(children, fn child ->
        assert {:ok, _transition} =
                 TerminalTransitions.terminalize_child(
                   child,
                   %{status: "completed", completed_at: DateTime.utc_now()},
                   "run_completed",
                   %{}
                 )
      end)

      signal = Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})
      assert :ignore = Subscriptions.delivery(signal, identity_map, attachment)
      assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
    end
  end

  test "attached lifecycle and report delivery require the active parent thread and session" do
    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_channel: "tui",
                 source_thread_id: "origin-thread",
                 session_id: "origin-session",
                 origin_receiver_account_ref: "tui:default",
                 title: "Scoped TUI fan-out",
                 objective: "Stay in one attached session"
               },
               ["one", "two"]
             )

    wrong_attachment = %{
      channel: "tui",
      receiver_account_ref: "tui:default",
      parent_id: parent.id,
      thread_id: "other-thread",
      session_id: "origin-session"
    }

    child_signal =
      Signal.new!("allbert.objectives.run.progress", %{
        parent_id: parent.id,
        child_id: hd(children).id
      })

    assert :ignore = Subscriptions.delivery(child_signal, identity_map, wrong_attachment)

    Enum.each(children, fn child ->
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{status: "completed", completed_at: DateTime.utc_now()},
                 "run_completed",
                 %{}
               )
    end)

    joined = Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})
    assert :ignore = Subscriptions.delivery(joined, identity_map, wrong_attachment)
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"

    right_attachment = %{
      wrong_attachment
      | thread_id: "origin-thread",
        session_id: "origin-session"
    }

    assert {:ok, %{report: %{receipt: receipt}}} =
             Subscriptions.delivery(joined, identity_map, right_attachment)

    assert receipt == Fanout.receipt_for(:report, parent.id)
  end
end
