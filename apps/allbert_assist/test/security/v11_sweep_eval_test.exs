defmodule AllbertAssist.Security.V11SweepEvalTest do
  @moduledoc "Behavior-bound v1.1 fan-out authority and denial contracts."

  use AllbertAssist.SecurityEvalCase, async: false, lane: :app_env_serial

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Channels.NotifyConsentCallback
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Execution.CancellationProof
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Steering
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.TestSupport.ShippedRegistries

  @ids ~w[
    fanout-decomposition-advisory-001
    fanout-notify-default-off-001
    fanout-notify-cross-user-001
    fanout-notify-redaction-001
    fanout-steer-no-approve-001
    fanout-steer-cross-user-001
    fanout-cancel-kill-scope-001
    fanout-ack-cross-user-001
    fanout-report-ack-cross-user-001
    fanout-notify-origin-ref-cross-account-001
    fanout-notify-consent-free-text-001
  ]

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_runtime = Application.get_env(:allbert_assist, Runtime)
    root = Path.join(System.tmp_dir!(), "allbert-v11-eval-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok, %{message: "single: #{request.text}", status: :completed}}
      end
    )

    ShippedRegistries.restore!()
    Fragments.clear_cache()

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Runtime, original_runtime)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "§I inventory is exact and every scenario has a distinct behavioral binding" do
    rows = EvalInventory.rows_for_milestone(:v11)
    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new(@ids)
    assert length(rows) == 11
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
    assert Enum.all?(rows, &(length(&1.assert) == 3))
    assert rows |> Enum.map(&MapSet.new(&1.assert)) |> Enum.uniq() |> length() == 11
  end

  test "fanout-decomposition-advisory-001" do
    put!("objectives.fanout.rollout_mode", "automatic")
    put!("objectives.fanout.confirm_before_start", true)

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Research alpha and then draft beta",
               channel: :test,
               user_id: "alice"
             })

    assert response.status == :needs_confirmation
    assert is_binary(response.approval_handoff.confirmation_id)
    assert Enum.all?(Fanout.children(response.fanout.parent_id), &(&1.run_attempt_count == 0))

    bind("fanout-decomposition-advisory-001", [
      :proposal_is_advisory,
      :children_remain_unstarted,
      :confirmation_state_persisted
    ])
  end

  test "fanout-notify-default-off-001" do
    parent = notify_parent!("alice", "1001")

    assert {:ok, delivery} =
             Notify.deliver(parent, :completion, "done",
               outbound_fun: fn _, _, _, _ -> flunk("transport must remain closed") end
             )

    assert delivery.state == "suppressed"
    assert delivery.error_class =~ "notify_disabled"

    bind("fanout-notify-default-off-001", [
      :all_channels_default_off,
      :transport_not_called,
      :suppression_audited
    ])
  end

  test "fanout-notify-cross-user-001" do
    parent = notify_parent!("alice", "1002")
    enable_notify!("mallory-ext", "mallory")

    assert {:ok, delivery} =
             Notify.deliver(parent, :completion, "done",
               outbound_fun: fn _, _, _, _ -> flunk("wrong identity must not reach transport") end
             )

    assert delivery.state == "suppressed"
    assert delivery.error_class =~ "identity_not_mapped"

    bind("fanout-notify-cross-user-001", [
      :mapped_user_reproved,
      :wrong_user_rejected,
      :no_transport_side_effect
    ])
  end

  test "fanout-notify-redaction-001" do
    parent = notify_parent!("alice", "1003")
    enable_notify!("alice-ext", "alice")
    test_pid = self()

    assert {:ok, delivery} =
             Notify.deliver(parent, :completion, "api_key=sk-test-1234567890123456",
               outbound_fun: fn _, _, body, _ ->
                 send(test_pid, {:body, body})
                 {:ok, %{message_id: "provider-1"}}
               end
             )

    assert delivery.state == "delivered"
    assert_receive {:body, body}
    refute body =~ "sk-test"

    bind("fanout-notify-redaction-001", [
      :exact_origin_authorized,
      :secret_redacted_before_transport,
      :delivery_record_terminal
    ])
  end

  test "fanout-steer-no-approve-001" do
    refute NotifyConsentCallback.typed_command?("yes, go ahead and adjust it")
    refute NotifyConsentCallback.typed_command?("please enable ALLBERT:NOTIFY:ON")
    assert {:ok, false} = Settings.get("channels.telegram.autonomous_notify.enabled")

    bind("fanout-steer-no-approve-001", [
      :free_text_not_typed_confirmation,
      :pending_confirmation_unchanged,
      :directive_has_no_authority
    ])
  end

  test "fanout-steer-cross-user-001" do
    {:ok, %{children: [child | _]}} =
      Fanout.frame(%{user_id: "alice", title: "Work", objective: "Work"}, ["One", "Two"])

    original = child.objective
    assert {:error, :not_found} = Steering.steer("mallory", child.id, "Replace it")
    assert {:ok, unchanged} = Objectives.get_objective(child.id)
    assert unchanged.objective == original

    bind("fanout-steer-cross-user-001", [
      :owner_lookup_scoped,
      :cross_user_returns_not_found,
      :objective_unchanged
    ])
  end

  @tag :external_runtime_serial
  test "fanout-cancel-kill-scope-001" do
    assert {:ok, %{status: :passed} = proof} = CancellationProof.run("cancel")
    assert proof.target_tree_dead? and proof.sibling_survived? and proof.cleanup_complete?

    bind("fanout-cancel-kill-scope-001", [
      :owned_tree_terminated,
      :sibling_survives,
      :proof_cleanup_complete
    ])
  end

  test "fanout-ack-cross-user-001" do
    {:ok, %{parent: parent, fanout_start_receipt: receipt}} = bound_fanout!()

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, bound_context("mallory"))

    assert {:ok, unchanged} = Objectives.get_objective(parent.id)
    assert unchanged.kickoff_delivery_state == "pending"

    bind("fanout-ack-cross-user-001", [
      :receipt_digest_matched,
      :delivery_identity_reproved,
      :kickoff_remains_pending
    ])
  end

  test "fanout-report-ack-cross-user-001" do
    {:ok, %{parent: parent, children: children}} = bound_fanout!()

    Enum.each(children, fn child ->
      {:ok, _} =
        Objectives.update_objective(child, %{
          status: "completed",
          completed_at: DateTime.utc_now()
        })
    end)

    assert {:ok, %{report_delivery_receipt: receipt}} = Fanout.finalize_join(parent)

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_report(receipt, bound_context("mallory"))

    assert {:ok, unchanged} = Objectives.get_objective(parent.id)
    assert unchanged.report_delivery_state == "pending"

    bind("fanout-report-ack-cross-user-001", [
      :report_receipt_matched,
      :report_identity_reproved,
      :report_remains_pending
    ])
  end

  test "fanout-notify-origin-ref-cross-account-001" do
    {:ok, %{parent: parent, fanout_start_receipt: receipt}} = bound_fanout!()

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, %{
               bound_context("alice")
               | origin_receiver_account_ref: "account-2"
             })

    assert {:ok, unchanged} = Objectives.get_objective(parent.id)
    assert unchanged.kickoff_delivery_state == "pending"

    bind("fanout-notify-origin-ref-cross-account-001", [
      :origin_digest_reproved,
      :receiver_account_reproved,
      :delivery_state_unchanged
    ])
  end

  test "fanout-notify-consent-free-text-001" do
    refute NotifyConsentCallback.typed_command?("turn notifications on")
    refute NotifyConsentCallback.typed_command?("allbert:notify:on")
    refute NotifyConsentCallback.typed_command?("please ALLBERT:NOTIFY:ON")
    assert {:ok, false} = Settings.get("channels.telegram.autonomous_notify.enabled")

    bind("fanout-notify-consent-free-text-001", [
      :typed_command_required,
      :lowercase_or_embedded_rejected,
      :setting_remains_disabled
    ])
  end

  defp bound_fanout! do
    Fanout.frame(
      %{
        user_id: "alice",
        title: "Bound",
        objective: "Bound",
        source_channel: "telegram",
        source_surface: "channel",
        source_thread_id: "thread-1",
        origin_thread_ref_digest: "digest-1",
        origin_receiver_account_ref: "account-1"
      },
      ["One", "Two"]
    )
  end

  defp bound_context(user_id),
    do: %{
      user_id: user_id,
      channel: "telegram",
      thread_id: "thread-1",
      origin_thread_ref_digest: "digest-1",
      origin_receiver_account_ref: "account-1"
    }

  defp notify_parent!(user_id, chat_id) do
    {:ok, thread} = Conversations.create_general_thread(user_id, "notify")

    {:ok, ref} =
      ChannelThread.link_thread(%{
        canonical_thread_id: thread.id,
        channel: "telegram",
        receiver_account_ref: "telegram:bot:test",
        provider_thread_ref: %{
          "provider" => "telegram",
          "chat_id" => chat_id,
          "origin_identity_digest" => ChannelThread.identity_digest("alice-ext")
        }
      })

    ref_map = %{
      id: to_string(ref.id),
      owner_scope: ref.owner_scope,
      channel: ref.channel,
      receiver_account_ref: ref.receiver_account_ref,
      provider_thread_key: ref.provider_thread_key,
      provider_thread_ref: ref.provider_thread_ref,
      trust_class: ref.trust_class
    }

    digest =
      ref_map
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, %{parent: parent}} =
      Fanout.frame(
        %{
          user_id: user_id,
          title: "Notify",
          objective: "Notify",
          source_thread_id: thread.id,
          source_channel: "telegram",
          source_surface: "channel",
          origin_thread_ref_id: to_string(ref.id),
          origin_thread_ref_digest: digest,
          origin_receiver_account_ref: ref.receiver_account_ref
        },
        ["One", "Two"]
      )

    parent
  end

  defp enable_notify!(external_user_id, user_id) do
    put!("channels.telegram.identity_map", [
      %{"external_user_id" => external_user_id, "user_id" => user_id, "enabled" => true}
    ])

    put!("channels.telegram.autonomous_notify.enabled", true)
  end

  defp put!(key, value), do: assert({:ok, _} = Settings.put(key, value, %{audit?: false}))
  defp bind(id, assertions), do: AssertBinding.check!(id, assertions)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
