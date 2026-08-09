defmodule AllbertAssist.Actions.Conversations.PersistAttachedFanoutReportTest do
  @moduledoc """
  v1.1 M12.21 — attached Web fan-in becomes one canonical, idempotent
  conversation message before the browser can acknowledge delivery.
  """

  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Conversations.PersistAttachedFanoutReport
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Runtime
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.ReadyEffectContext

  test "both layout-v2 selections persist their exact body once" do
    for source <- [:model, :fallback] do
      {:ok, thread} = Conversations.create_general_thread("local", "Fan-in origin #{source}")

      %{parent: parent, children: children, report_body: report_body} =
        joined_web_fanout!(thread.id, source)

      params = %{thread_id: thread.id, parent_id: parent.id}

      assert {:ok,
              %{
                status: :completed,
                parent_id: parent_id,
                canonical_message_id: message_id,
                report_delivery_receipt: receipt,
                delivery_context: %{channel: "live_view"},
                acknowledgement_required?: true
              }} = Runner.run("persist_attached_fanout_report", params, %{user_id: "local"})

      assert parent_id == parent.id
      assert is_binary(message_id)
      assert is_binary(receipt)

      assert {:ok, %{status: :completed, canonical_message_id: ^message_id}} =
               Runner.run("persist_attached_fanout_report", params, %{user_id: "local"})

      assert [message] = Conversations.list_messages(thread)
      assert message.id == message_id
      assert message.role == "assistant"
      assert message.content == report_body
      assert message.metadata["kind"] == "fanout_join_report"
      assert message.metadata["parent_objective_id"] == parent.id
      assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
      assert Enum.all?(children, &(&1.status == "completed"))
    end
  end

  test "server-derived identity and origin thread prevent cross-owner or cross-thread writes" do
    {:ok, origin} = Conversations.create_general_thread("local", "Origin")
    {:ok, other} = Conversations.create_general_thread("local", "Other")
    %{parent: parent} = joined_web_fanout!(origin.id)

    assert {:ok, %{status: :error, error: {:thread_not_found, _}}} =
             Runner.run(
               "persist_attached_fanout_report",
               %{thread_id: origin.id, parent_id: parent.id, user_id: "local"},
               %{user_id: "alice"}
             )

    assert {:ok, %{status: :error, error: :origin_thread_mismatch}} =
             Runner.run(
               "persist_attached_fanout_report",
               %{thread_id: other.id, parent_id: parent.id, user_id: "alice"},
               %{user_id: "local"}
             )

    assert Conversations.list_messages(origin) == []
    assert Conversations.list_messages(other) == []
  end

  test "unjoined or non-Web fan-outs cannot become attached Web messages" do
    {:ok, thread} = Conversations.create_general_thread("local", "Wrong state")

    assert {:ok, %{parent: open_parent}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "local",
                 source_channel: "live_view",
                 source_thread_id: thread.id,
                 title: "Still open",
                 objective: "Not ready"
               }),
               ["one", "two"]
             )

    assert {:ok, %{status: :error, error: {:report_not_ready, "not_ready"}}} =
             Runner.run(
               "persist_attached_fanout_report",
               %{thread_id: thread.id, parent_id: open_parent.id},
               %{user_id: "local"}
             )

    %{parent: tui_parent} = joined_fanout!(thread.id, "tui")

    assert {:ok, %{status: :error, error: :not_attached_web_origin}} =
             Runner.run(
               "persist_attached_fanout_report",
               %{thread_id: thread.id, parent_id: tui_parent.id},
               %{user_id: "local"}
             )

    assert Conversations.list_messages(thread) == []
  end

  test "a browser-delivered parent can be re-ensured without duplicating its message" do
    {:ok, thread} = Conversations.create_general_thread("local", "Delivered")
    %{parent: parent} = joined_web_fanout!(thread.id)
    params = %{thread_id: thread.id, parent_id: parent.id}

    assert {:ok, first} =
             Runner.run("persist_attached_fanout_report", params, %{user_id: "local"})

    assert first.acknowledgement_required?

    assert :ok =
             Runtime.acknowledge_report_delivery(
               first.report_delivery_receipt,
               first.delivery_context
             )

    assert {:ok,
            %{
              status: :completed,
              canonical_message_id: message_id,
              acknowledgement_required?: false
            }} = Runner.run("persist_attached_fanout_report", params, %{user_id: "local"})

    assert message_id == first.canonical_message_id
    assert [_message] = Conversations.list_messages(thread)
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
  end

  test "the permission gate deny path creates no canonical message" do
    {:ok, thread} = Conversations.create_general_thread("local", "Denied")
    %{parent: parent} = joined_web_fanout!(thread.id)

    assert {:ok, %{status: status, actions: [%{status: :denied}]}} =
             PersistAttachedFanoutReport.run(
               %{thread_id: thread.id, parent_id: parent.id},
               %{user_id: "local", selected_action: "unregistered_boundary_probe"}
             )

    assert status in [:denied, :error]
    assert Conversations.list_messages(thread) == []
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
  end

  defp joined_web_fanout!(thread_id, source \\ :fallback) do
    joined_fanout!(thread_id, "live_view", source)
  end

  defp joined_fanout!(thread_id, channel, source \\ :fallback) do
    FanoutReportFixture.selected_report!(source, %{
      user_id: "local",
      source_channel: channel,
      source_surface: "channel",
      source_thread_id: thread_id
    })
  end
end
