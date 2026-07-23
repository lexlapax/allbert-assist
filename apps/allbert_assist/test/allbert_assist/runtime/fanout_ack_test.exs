defmodule AllbertAssist.Runtime.FanoutAckTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Runs.Supervisor, as: RunsSupervisor
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings

  setup do
    original = Application.get_env(:allbert_assist, Runtime)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok, %{message: "single: #{request.text}", status: :completed}}
      end
    )

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", false, %{audit?: false})

    on_exit(fn ->
      if Process.whereis(RunsSupervisor) do
        RunsSupervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_id, pid, _type, _modules} ->
          DynamicSupervisor.terminate_child(RunsSupervisor, pid)
        end)
      end

      if original,
        do: Application.put_env(:allbert_assist, Runtime, original),
        else: Application.delete_env(:allbert_assist, Runtime)
    end)

    :ok
  end

  test "visible kickoff is a hard start barrier and acknowledgement is idempotent" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Research alpha and then draft beta",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "alice"
             })

    assert response.message =~ "1. Research alpha"
    assert response.message =~ "2. draft beta"
    assert response.fanout.delivery_state == "pending"
    assert is_binary(response.fanout_start_receipt)

    children = Fanout.children(response.fanout.parent_id)
    assert Enum.all?(children, &(&1.run_attempt_count == 0 and &1.status == "open"))

    identity = %{user_id: "alice", channel: "test", thread_id: response.thread_id}
    assert :ok = Runtime.acknowledge_fanout_start(response.fanout_start_receipt, identity)
    assert :ok = Runtime.acknowledge_fanout_start(response.fanout_start_receipt, identity)

    eventually(fn ->
      Fanout.children(response.fanout.parent_id)
      |> Enum.all?(&(&1.run_attempt_count >= 1 and &1.status != "running"))
    end)

    assert Enum.map(Fanout.children(response.fanout.parent_id), &{&1.status, &1.review_reason}) ==
             [{"completed", nil}, {"completed", nil}]
  end

  test "an undelivered kickoff stays pending and retry reuses its receipt" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    request = %{
      text: "first task; second task",
      channel: :test,
      user_id: "alice",
      delivery_ack_capability: Runtime.fanout_delivery_ack_capability()
    }

    assert {:ok, response} = Runtime.submit_user_input(request)

    assert {:ok, parent} = Objectives.get_objective(response.fanout.parent_id)
    assert parent.kickoff_delivery_state == "pending"
    assert Enum.all?(Fanout.children(parent), &(&1.run_attempt_count == 0))
    assert Fanout.receipt_for(:start, parent.id) == response.fanout_start_receipt

    context = %{user_id: "alice", thread_id: response.thread_id, channel: "test"}
    assert :ok = Runtime.delivery_failed(response, context)
    assert {:ok, blocked} = Objectives.get_objective(parent.id)
    assert blocked.kickoff_delivery_state == "blocked"
    assert Enum.all?(Fanout.children(parent), &(&1.run_attempt_count == 0))

    assert :ok = Runtime.acknowledge_fanout_start(response.fanout_start_receipt, context)
    assert {:ok, acknowledged} = Objectives.get_objective(parent.id)
    assert acknowledged.kickoff_delivery_state == "acknowledged"

    eventually(fn ->
      Fanout.children(parent) |> Enum.all?(&(&1.status == "completed"))
    end)
  end

  test "pending reports are non-destructive and identity-bound until delivery acknowledgement" do
    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{text: "hello", channel: :test, user_id: "alice"})

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Finished work",
                 objective: "Finished work",
                 source_channel: "test",
                 source_surface: "channel",
                 source_thread_id: first_turn.thread_id
               },
               ["one", "two"]
             )

    for child <- children do
      assert {:ok, _completed} =
               Objectives.update_objective(child, %{
                 status: "completed",
                 last_observation_summary: "done #{child.queue_position}",
                 completed_at: DateTime.utc_now()
               })
    end

    assert {:ok, %{report_delivery_receipt: receipt}} = Fanout.finalize_join(parent)
    parent_id = parent.id

    assert {:ok, next_turn} =
             Runtime.submit_user_input(%{
               text: "what next?",
               channel: :test,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    assert [%{parent_objective_id: ^parent_id, report_delivery_receipt: ^receipt}] =
             next_turn.pending_reports

    assert next_turn.message =~ "Finished work"
    assert next_turn.message =~ "✓ one"

    assert {:error, :receipt_identity_mismatch} =
             Runtime.acknowledge_report_delivery(receipt, %{
               user_id: "mallory",
               channel: "test",
               thread_id: first_turn.thread_id
             })

    assert [%{report_delivery_receipt: ^receipt}] =
             Fanout.pending_reports("alice", first_turn.thread_id)

    assert :ok =
             Runtime.acknowledge_report_delivery(receipt, %{
               user_id: "alice",
               channel: "test",
               thread_id: first_turn.thread_id
             })

    assert Fanout.pending_reports("alice", first_turn.thread_id) == []
  end

  test "exact origin binding denies missing or changed account context" do
    assert {:ok, %{parent: parent, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Bound work",
                 objective: "Bound work",
                 source_channel: "telegram",
                 source_surface: "channel",
                 source_thread_id: "thread-bound",
                 origin_thread_ref_digest: "digest-1",
                 origin_receiver_account_ref: "account-1"
               },
               ["one", "two"]
             )

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               thread_id: "thread-bound",
               channel: "telegram"
             })

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               thread_id: "thread-bound",
               channel: "telegram",
               origin_thread_ref_digest: "digest-1",
               origin_receiver_account_ref: "account-2"
             })

    assert :ok =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               thread_id: "thread-bound",
               channel: "telegram",
               origin_thread_ref_digest: "digest-1",
               origin_receiver_account_ref: "account-1"
             })

    assert {:ok, acknowledged} = Objectives.get_objective(parent.id)
    assert acknowledged.kickoff_delivery_state == "acknowledged"
  end

  test "await continuation enforces ownership and returns bounded kickoff on timeout" do
    assert {:ok, %{parent: parent}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Await work",
                 objective: "Await work",
                 source_channel: "openai_api",
                 source_surface: "api",
                 source_thread_id: "thread-await"
               },
               ["one", "two"]
             )

    assert {:error, :fanout_identity_mismatch} = Runtime.await_fanout(parent.id, "mallory", 0)

    assert {:timeout, kickoff} = Runtime.await_fanout(parent.id, "alice", 0)
    assert kickoff.parent_id == parent.id
    assert length(kickoff.children) == 2
  end

  test "confirm-before-start persists approval and resumes only through the registered action" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", true, %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "first task; second task",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "alice"
             })

    assert response.status == :needs_confirmation
    confirmation_id = response.approval_handoff.confirmation_id
    assert is_binary(confirmation_id)
    assert Enum.all?(Fanout.children(response.fanout.parent_id), &(&1.run_attempt_count == 0))

    assert :ok =
             Runtime.acknowledge_deliveries(response, %{
               channel: "test",
               user_id: "alice",
               thread_id: response.thread_id
             })

    assert Enum.all?(Fanout.children(response.fanout.parent_id), &(&1.run_attempt_count == 0))

    assert {:ok, %{status: :completed}} =
             Runner.run("approve_confirmation", %{id: confirmation_id}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    eventually(fn ->
      Fanout.children(response.fanout.parent_id)
      |> Enum.all?(&(&1.status == "completed"))
    end)
  end

  test "missing or malformed delivery acknowledgement capability fails closed to one turn" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    for capability <- [nil, false, true, "fanout_delivery_ack_v2", :fanout_delivery_ack_v1] do
      request = %{
        text: "first task; second task",
        channel: :test,
        user_id: "unadapted-#{inspect(capability)}"
      }

      request =
        if is_nil(capability),
          do: request,
          else: Map.put(request, :delivery_ack_capability, capability)

      assert {:ok, response} = Runtime.submit_user_input(request)
      assert response.message =~ "single:"
      assert Map.get(response, :fanout) == nil
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
