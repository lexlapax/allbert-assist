defmodule AllbertAssist.Actions.Conversations.DeleteConversationTargetTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Conversations.DeleteConversationContent
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.Thread
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.SpanProvenance
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-delete-conversation-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    KeyCustody.invalidate(:all)

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      File.rm_rf!(home)
      restore_system_env(original_env)
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
    end)

    :ok
  end

  test "registered generic-resume action deletes a message, repairs recency, and retains title" do
    assert {:ok, capability} = Registry.capability("delete_conversation_content")
    assert capability.confirmation == :required
    assert capability.resumable?

    assert {:ok, thread} = Conversations.create_general_thread("local", "Retained title")
    assert {:ok, first} = local_message(thread, "keep me")
    assert {:ok, second} = local_message(thread, "delete me")
    add_provider_refs(thread, second)

    assert {:ok, pending} =
             DeleteConversationContent.run(
               %{target_kind: :message, target_id: second.id},
               operator_context()
             )

    assert pending.status == :needs_confirmation
    assert pending.preview.message_count == 1
    assert pending.preview.reference_count == 1
    assert pending.preview.retained_thread_title?
    assert pending.preview.preview_binding =~ ~r/^hmac-sha256:[0-9a-f]{64}$/

    assert pending.confirmation["resume_params_ref"]["key_ref"] ==
             "secret://system/integrity_v1"

    assert pending.confirmation["resume_params_ref"]["user_id"] == "local"
    refute inspect(pending.confirmation) =~ "delete me"
    refute inspect(pending.confirmation) =~ content_digest("delete me")

    assert {:ok, _managed} = Managed.reconcile("local")
    dirty_before = managed_search().metadata["dirty_seq"]

    wrong_user_context = Map.put(approved_context(), :user_id, "alice")

    assert {:ok, unauthorized} =
             DeleteConversationContent.run(resume_params(pending), wrong_user_context)

    assert unauthorized.status == :failed
    assert unauthorized.error == :unauthorized
    assert Repo.get(Message, second.id)

    assert {:ok, approved} =
             ApproveConfirmation.run(
               %{id: pending.confirmation_id, reason: "remove exact message"},
               operator_context()
             )

    assert approved.status == :completed
    assert approved.confirmation["operator_resolution"]["target_status"] == "completed"
    assert Repo.get(Message, second.id) == nil
    assert Repo.get(Message, first.id)
    assert Repo.get!(Thread, thread.id).title == "Retained title"
    assert Repo.get!(Thread, thread.id).last_message_at == first.inserted_at
    assert Repo.get_by(ConversationMessageRef, canonical_message_id: second.id) == nil
    assert managed_search().metadata["dirty_seq"] == dirty_before + 1

    assert {:ok, [{:error, :missing}]} =
             Corpus.rehydrate_and_authorize("local", [second.id], local_search_policy())
  end

  test "changed cascade makes an approved preview stale and leaves rows untouched" do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Stale preview")
    assert {:ok, source} = local_message(thread, "original")

    assert {:ok, pending} =
             DeleteConversationContent.run(
               %{target_kind: :thread, target_id: thread.id},
               operator_context()
             )

    assert {:ok, added} = local_message(thread, "concurrent append")

    assert {:ok, stale} =
             DeleteConversationContent.run(
               resume_params(pending),
               approved_context()
             )

    assert stale.status == :failed
    assert stale.error == :stale
    assert Repo.get(Thread, thread.id)
    assert Repo.get(Message, source.id)
    assert Repo.get(Message, added.id)
  end

  test "thread deletion blocks live work, then preserves historical rows and cascades refs" do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Dependent thread")
    assert {:ok, message} = local_message(thread, "thread body")
    add_provider_refs(thread, message)

    assert {:ok, live_job} =
             Jobs.create_job(%{
               name: "live thread work",
               target_type: "runtime_prompt",
               target: %{text: "continue"},
               schedule: %{kind: "daily", at: "08:00"},
               timezone: "UTC",
               status: "active",
               user_id: "local",
               thread_id: thread.id,
               thread_mode: "origin_thread"
             })

    assert {:ok, blocked} =
             DeleteConversationContent.run(
               %{target_kind: :thread, target_id: thread.id},
               operator_context()
             )

    assert blocked.status == :failed
    assert {:live_dependency, %{active_jobs: 1}} = blocked.error
    assert Repo.get(Thread, thread.id)

    assert {:ok, paused_job} = Jobs.pause_job(live_job)

    assert {:ok, pending} =
             DeleteConversationContent.run(
               %{target_kind: :thread, target_id: thread.id},
               operator_context()
             )

    assert pending.preview.message_count == 1
    assert pending.preview.reference_count == 2
    assert pending.preview.survivor_counts.historical_jobs == 1
    refute pending.preview.retained_thread_title?

    assert {:ok, deleted} =
             DeleteConversationContent.run(resume_params(pending), approved_context())

    assert deleted.status == :completed
    assert deleted.output_data.outcome == :deleted
    assert Repo.get(Thread, thread.id) == nil
    assert Repo.get(Message, message.id) == nil
    assert Repo.get_by(ThreadChannelRef, canonical_thread_id: thread.id) == nil
    assert Repo.get_by(ConversationMessageRef, canonical_thread_id: thread.id) == nil
    assert Repo.get!(Jobs.Job, paused_job.id)
  end

  test "pending approval is the retry key after commit and a fresh absent request is not found" do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Crash retry")
    assert {:ok, message} = local_message(thread, "one shot")

    assert {:ok, pending} =
             DeleteConversationContent.run(
               %{target_kind: :message, target_id: message.id},
               operator_context()
             )

    resume = resume_params(pending)
    assert {:ok, first} = DeleteConversationContent.run(resume, approved_context())
    assert first.output_data.outcome == :deleted
    assert pending.confirmation["status"] == "pending"

    assert {:ok, replay} = DeleteConversationContent.run(resume, approved_context())
    assert replay.output_data.outcome == :already_deleted
    assert replay.output_data.deleted_message_count == 1

    assert {:ok, resolved} =
             ApproveConfirmation.run(
               %{id: pending.confirmation_id, reason: "resume after commit"},
               operator_context()
             )

    assert resolved.status == :completed
    assert resolved.confirmation["status"] == "approved"

    assert {:ok, absent} =
             DeleteConversationContent.run(
               %{target_kind: :message, target_id: message.id},
               operator_context()
             )

    assert absent.status == :failed
    assert absent.error == :not_found
  end

  test "canonical deletion scrubs matching proposal and legacy draft payloads idempotently" do
    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)

    assert {:ok, _setting} =
             Settings.put("memory.collection.origin_grants", ["local_operator"])

    assert {:ok, thread} = Conversations.create_general_thread("local", "Derived content")
    assert {:ok, message} = local_message(thread, "I prefer deletion-safe evidence.")
    proposal = proposal_for(message.id, "deletion-safe evidence")

    assert {:ok, draft} =
             Store.create_memory_draft(%{
               id: "deleted_source_draft",
               kind: "memory_promotion",
               summary: "Derived private draft",
               body: "Derived private draft body",
               provenance: %{
                 operator_id: "local",
                 source_thread_id: thread.id
               }
             })

    assert {:ok, pending} =
             DeleteConversationContent.run(
               %{target_kind: :thread, target_id: thread.id},
               operator_context()
             )

    resume = resume_params(pending)
    assert {:ok, deleted} = DeleteConversationContent.run(resume, approved_context())
    assert deleted.output_data.outcome == :deleted

    stale = Repo.get!(Proposal, proposal.id)
    assert stale.status == "stale"
    assert stale.proposed_claim == %{"content_scrubbed" => true}
    assert stale.span_provenance == %{"content_scrubbed" => true}
    refute inspect(stale) =~ "deletion-safe evidence"

    assert {:ok, scrubbed} = Store.show_draft(draft.id, kind: draft.kind)
    assert scrubbed.tier == "discarded"
    assert scrubbed.payload == %{"content_scrubbed" => true}
    assert scrubbed.provenance == %{"content_scrubbed" => true}
    refute inspect(scrubbed) =~ "Derived private draft"

    assert {:ok, replay} = DeleteConversationContent.run(resume, approved_context())
    assert replay.output_data.outcome == :already_deleted
    assert Repo.get!(Proposal, proposal.id).status == "stale"
    assert {:ok, replayed_draft} = Store.show_draft(draft.id, kind: draft.kind)
    assert replayed_draft.payload == %{"content_scrubbed" => true}
  end

  test "ownership and optional expected digest fail closed before confirmation" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Private")
    assert {:ok, message} = local_message(thread, "private statement")

    assert {:ok, unauthorized} =
             DeleteConversationContent.run(
               %{target_kind: :message, target_id: message.id},
               operator_context()
             )

    assert unauthorized.status == :failed
    assert unauthorized.error == :unauthorized

    assert {:ok, stale} =
             DeleteConversationContent.run(
               %{
                 target_kind: :message,
                 target_id: message.id,
                 expected_digest: "sha256:" <> String.duplicate("0", 64)
               },
               Map.put(operator_context(), :user_id, "alice")
             )

    assert stale.status == :failed
    assert stale.error == :stale
  end

  defp local_message(thread, content) do
    Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp proposal_for(message_id, value) do
    policy = %{consumer: :memory, origin_scope: :local_operator, e2ee?: false}
    assert {:ok, snapshot} = Corpus.snapshot("local", policy)
    assert {:ok, page} = Corpus.page(snapshot, nil, 100)
    source = Enum.find(page.items, &(&1.source_id == message_id))

    assert {:ok, subject} = proposal_span("subject", source, "I", "operator_pronoun_v1")
    assert {:ok, predicate} = proposal_span("predicate", source, "prefer", "identity_v1")
    assert {:ok, object} = proposal_span("value", source, value, "identity_v1")

    assert {:ok, %{proposal: proposal}} =
             Proposals.propose(source, %{
               proposed_claim: %{
                 subject: "operator:local",
                 predicate: "prefer",
                 value: value
               },
               span_provenance: %{fields: [subject, predicate, object]},
               category: "preferences",
               namespace: "default",
               run_id: "canonical-delete",
               extractor_profile: "deterministic_v1",
               extractor_version: 1
             })

    proposal
  end

  defp proposal_span(field, source, raw, transform) do
    {start, length} = :binary.match(source.content, raw)
    SpanProvenance.build(field, source, start, start + length, transform)
  end

  defp add_provider_refs(thread, message) do
    ref = %{
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        team_id: "T0123",
        channel_id: "C0123",
        thread_ts: "1718040000.000100"
      },
      trust_class: :server_readable
    }

    assert {:ok, _thread_ref} =
             ref |> Map.put(:canonical_thread_id, thread.id) |> ChannelThread.link_thread()

    assert {:ok, _message_ref} =
             ref
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: message.id,
               provider_message_id: "provider-#{message.id}",
               direction: :in
             })
             |> ChannelThread.record_message_ref()
  end

  defp resume_params(pending), do: pending.confirmation["resume_params_ref"]

  defp operator_context do
    %{user_id: "local", actor: "local", channel: :cli, surface: "test"}
  end

  defp approved_context,
    do: Map.put(operator_context(), :confirmation, %{approved?: true})

  defp local_search_policy,
    do: %{consumer: :search, origin_scope: :local_operator, e2ee?: false}

  defp managed_search do
    Jobs.list_jobs("local", limit: 100)
    |> Enum.find(&(&1.name == "search-index"))
  end

  defp content_digest(content) do
    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  defp restore_system_env(original) do
    Enum.each(original, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
