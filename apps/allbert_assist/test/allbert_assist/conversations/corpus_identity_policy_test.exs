defmodule AllbertAssist.Conversations.CorpusIdentityPolicyTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ReadyEffectContext

  setup do
    original_runtime = Application.get_env(:allbert_assist, Runtime)
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-corpus-identity-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Runtime, agent_runner: &runtime_response/2)

    on_exit(fn ->
      restore_env(Runtime, original_runtime)
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "remote admission freezes exact principal and origin while assistant remains distinct" do
    link_identity("U_ALICE")

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :search,
               :mapped_operator_dm,
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "verified remote input",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: slack_ref("1718040000.000100"),
               provider_message_id: "remote-message-1"
             })

    user_message = Repo.get!(Message, response.user_message_id)
    assistant_message = Repo.get!(Message, response.assistant_message_id)
    assert user_message.origin_thread_ref_id
    assert assistant_message.origin_thread_ref_id == user_message.origin_thread_ref_id
    assert assistant_message.origin_principal_digest == user_message.origin_principal_digest
    assert user_message.principal_normalizer_version == "principal-v1"

    assert %ConversationMessageRef{thread_channel_ref_id: thread_ref_id} =
             Repo.get_by!(ConversationMessageRef, provider_message_id: "remote-message-1")

    assert thread_ref_id == user_message.origin_thread_ref_id

    policy = mapped_search_policy()
    assert {:ok, snapshot} = Corpus.snapshot("alice", policy)
    assert {:ok, %{items: envelopes}} = Corpus.page(snapshot, nil, 20)

    assert Enum.map(envelopes, & &1.author) == [:operator, :assistant]
    assert Enum.all?(envelopes, &(&1.origin_scope == :mapped_operator_dm))
    assert Enum.all?(envelopes, &(&1.origin.thread_channel_ref_id == to_string(thread_ref_id)))

    assert {:error, :consumer_disabled} =
             Corpus.snapshot("alice", %{policy | consumer: :memory})

    assert {:ok, _setting} =
             Settings.put(
               "memory.consolidation.enabled",
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :memory,
               :mapped_operator_dm,
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, memory_snapshot} = Corpus.snapshot("alice", %{policy | consumer: :memory})
    assert {:ok, %{items: memory_items}} = Corpus.page(memory_snapshot, nil, 20)
    assert Enum.map(memory_items, & &1.author) == [:operator]
  end

  test "role alone cannot establish remote operator authorship" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Spoof")

    assert {:ok, spoofed} =
             Conversations.append_user_message(thread, "role says user",
               metadata: %{"channel" => "slack"}
             )

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :search,
               :mapped_operator_dm,
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, [{:error, :legacy_principal_unverified}]} =
             Corpus.rehydrate_and_authorize("alice", [spoofed.id], mapped_search_policy())
  end

  test "verified mapped identity does not turn a shared provider conversation into a DM" do
    link_identity("U_ALICE")

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :search,
               :mapped_operator_dm,
               true,
               ReadyEffectContext.context()
             )

    shared_ref = Map.put(slack_ref("1718040000.000150"), :conversation_scope, :shared)

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "shared room content",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: shared_ref,
               provider_message_id: "shared-message-1"
             })

    assert {:ok, [{:error, :scope_denied}]} =
             Corpus.rehydrate_and_authorize(
               "alice",
               [response.user_message_id],
               mapped_search_policy()
             )
  end

  test "one exact legacy ref and current principal can be backfilled, ambiguity cannot" do
    link_identity("U_ALICE")

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :search,
               :mapped_operator_dm,
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, thread} = Conversations.create_general_thread("alice", "Legacy")
    assert {:ok, message} = Conversations.append_user_message(thread, "legacy remote")
    ref = slack_ref("1718040000.000200")

    assert {:ok, thread_ref} =
             ref |> Map.put(:canonical_thread_id, thread.id) |> ChannelThread.link_thread()

    assert {:ok, _message_ref} =
             ref
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: message.id,
               provider_message_id: "legacy-message-1",
               direction: :in
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, [{:ok, envelope}]} =
             Corpus.rehydrate_and_authorize("alice", [message.id], mapped_search_policy())

    assert envelope.origin.thread_channel_ref_id == to_string(thread_ref.id)
    assert Repo.get!(Message, message.id).origin_thread_ref_id == thread_ref.id

    assert {:ok, ambiguous} = Conversations.append_user_message(thread, "ambiguous remote")

    assert {:ok, _message_ref} =
             ref
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: ambiguous.id,
               provider_message_id: "legacy-message-2",
               direction: :in
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _second_thread_ref} =
             slack_ref("1718040000.000201")
             |> Map.put(:canonical_thread_id, thread.id)
             |> ChannelThread.link_thread()

    assert {:ok, [{:error, :legacy_principal_unverified}]} =
             Corpus.rehydrate_and_authorize("alice", [ambiguous.id], mapped_search_policy())
  end

  test "principal remap suppresses already projected source at rehydration" do
    link_identity("U_ALICE")

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :search,
               :mapped_operator_dm,
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "identity changes later",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: slack_ref("1718040000.000300"),
               provider_message_id: "remote-message-3"
             })

    assert {:ok, [{:ok, envelope}]} =
             Corpus.rehydrate_and_authorize(
               "alice",
               [response.user_message_id],
               mapped_search_policy()
             )

    assert {:ok, snapshot_before_remap} = Corpus.snapshot("alice", mapped_search_policy())

    assert {:ok, _removed} = ChannelThread.unlink_identity(identity_attrs("U_ALICE"))
    link_identity("U_ALICE_REPLACED")

    assert {:error, :eligibility_changed} = Corpus.page(snapshot_before_remap, nil, 20)

    assert {:ok, [{:error, :legacy_principal_unverified}]} =
             Corpus.rehydrate_and_authorize(
               "alice",
               [%{source_id: response.user_message_id, content_digest: envelope.content_digest}],
               mapped_search_policy()
             )
  end

  defp runtime_response(_signal, request) do
    {:ok, %{message: "Runtime response: #{request.text}", status: :completed, actions: []}}
  end

  defp link_identity(external_user_id) do
    assert {:ok, _link} = ChannelThread.link_identity(identity_attrs(external_user_id))
  end

  defp identity_attrs(external_user_id) do
    %{
      owner_scope: "local",
      link_id: "operator-alice",
      user_id: "alice",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      external_user_id: external_user_id
    }
  end

  defp slack_ref(thread_ts) do
    %{
      owner_scope: "local",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        team_id: "T0123",
        channel_id: "C0123",
        thread_ts: thread_ts
      },
      trust_class: :server_readable,
      conversation_scope: :direct
    }
  end

  defp mapped_search_policy do
    %{consumer: :search, origin_scope: :mapped_operator_dm, e2ee?: false}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
