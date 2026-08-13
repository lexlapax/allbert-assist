defmodule AllbertAssist.Channels.TUISubscriptionsTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias AllbertTUI.Subscriptions
  alias Jido.Signal

  test "renders only signals owned by the attached identity map" do
    assert {:ok, alice} =
             Objectives.create_objective(
               %{
                 user_id: "alice",
                 title: "Owned fan-out",
                 objective: "owned",
                 fanout_role: "parent"
               },
               ReadyEffectContext.context()
             )

    assert {:ok, mallory} =
             Objectives.create_objective(
               %{
                 user_id: "mallory",
                 title: "Foreign fan-out",
                 objective: "foreign",
                 fanout_role: "parent"
               },
               ReadyEffectContext.context()
             )

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

  test "joined delivery preserves both layout-v2 selection bodies exactly" do
    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]

    for source <- [:model, :fallback] do
      selected =
        FanoutReportFixture.selected_report!(source, %{
          user_id: "alice",
          source_channel: "tui",
          source_surface: "tui",
          source_thread_id: "thread-attached-#{source}"
        })

      signal =
        Signal.new!("allbert.objectives.fanout.joined", %{parent_id: selected.parent.id})

      assert {:ok, delivery} = Subscriptions.delivery(signal, identity_map)
      assert delivery.parent_id == selected.parent.id

      assert delivery.lines == [
               "[fan-out] fanout joined: #{selected.parent.title}",
               selected.report_body
             ]

      assert {:ok, recovered_without_signal} =
               Subscriptions.pending_join_delivery(selected.parent.id, identity_map, %{})

      assert recovered_without_signal == delivery

      assert :ignore =
               Subscriptions.delivery(signal, [
                 %{
                   "external_user_id" => "local",
                   "user_id" => "mallory",
                   "enabled" => true
                 }
               ])
    end
  end

  test "same-user remote channels and other TUI profiles are not attached deliveries" do
    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]
    attachment = %{channel: "tui", receiver_account_ref: "tui:default"}

    for {source_channel, receiver_account_ref} <- [
          {"telegram", "telegram:bot:test"},
          {"tui", "tui:other-profile"}
        ] do
      %{parent: parent} =
        FanoutReportFixture.selected_report!(:fallback, %{
          user_id: "alice",
          source_channel: source_channel,
          source_surface: "channel",
          source_thread_id: "thread-#{source_channel}",
          origin_receiver_account_ref: receiver_account_ref
        })

      signal = Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})
      assert :ignore = Subscriptions.delivery(signal, identity_map, attachment)
      assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
    end
  end

  test "attached lifecycle and report delivery require the active parent thread and session" do
    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]

    frame =
      FanoutReportFixture.frame!(%{
        user_id: "alice",
        source_channel: "tui",
        source_surface: "tui",
        source_thread_id: "origin-thread",
        session_id: "origin-session",
        origin_receiver_account_ref: "tui:default"
      })

    %{parent: parent, children: children} = frame

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

    FanoutReportFixture.complete_and_select!(frame, :fallback)

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
