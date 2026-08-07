defmodule AllbertAssist.Memory.ConsolidatorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Memory.ConsolidateMemory
  alias AllbertAssist.Conversations
  alias AllbertAssist.Memory.ConsolidationControl
  alias AllbertAssist.Memory.Consolidator
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-consolidator-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "disabled and ungranted runs perform no Corpus inventory and persist no cursor" do
    assert {:ok, disabled} = Consolidator.run("alice")
    assert disabled.status == "no_op"
    assert disabled.stopped_reason == "disabled"
    assert disabled.scanned == 0
    assert Repo.aggregate(ConsolidationControl, :count) == 0

    assert {:ok, _setting} =
             Settings.put(
               "memory.consolidation.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, ungranted} = Consolidator.run("alice")
    assert ungranted.stopped_reason == "origin_grant_required"
    assert Repo.aggregate(ConsolidationControl, :count) == 0
  end

  test "bounded cursor runs create at most twenty grounded proposals and resume the remainder" do
    enable!()

    for index <- 1..25 do
      append!("I prefer bounded item #{index}.")
    end

    assert {:ok, first} = Consolidator.run("alice")
    assert first.created == 20
    assert first.hosted_transport_count == 0
    assert first.stopped_reason == "run_proposal_cap"
    assert first.pending_after == 20

    control = Repo.one!(ConsolidationControl)
    assert control.cursor_source_id
    refute inspect(control.last_run) =~ "bounded item"
    assert control.last_run["hosted_transport_count"] == 0

    assert {:ok, second} = Consolidator.run("alice")
    assert second.created == 5
    assert second.pending_after == 25
    assert Proposals.pending_count("alice") == 25

    resumed = Repo.one!(ConsolidationControl)
    assert resumed.run_sequence == 2
    assert is_nil(resumed.cursor_source_id)
  end

  test "registered action has proposal-only authority and reports redacted counters" do
    enable!()
    append!("I prefer concise evidence.")
    append!("Could this be a question?")

    context = %{user_id: "alice", request: %{user_id: "alice", channel: :job}}
    assert {:ok, response} = ConsolidateMemory.run(%{}, context)
    assert response.status == :completed
    assert response.permission_decision.permission == :memory_propose
    assert response.result.created == 1
    assert response.result.abstained == 1
    assert response.result.hosted_transport_count == 0
    refute inspect(response.result) =~ "concise evidence"

    assert {:ok, _setting} =
             Settings.put(
               "permissions.memory_propose",
               "denied",
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, denied} = ConsolidateMemory.run(%{}, context)
    assert denied.status == :denied
  end

  test "assistant context is transient and cannot become proposal evidence" do
    enable!()
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Transient context")

    assert {:ok, assistant} =
             Conversations.append_assistant_message(
               thread,
               "The operator prefers assistant text.",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, operator} =
             Conversations.append_user_message(thread, "I prefer operator evidence.",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, result} = Consolidator.run("alice")
    assert result.created == 1
    assert [proposal] = Proposals.list("alice")
    assert Enum.map(proposal.source_evidence["refs"], & &1["source_id"]) == [operator.id]
    refute inspect(proposal) =~ assistant.id
    refute inspect(proposal) =~ "assistant text"
  end

  test "managed ingestion drops identifiers and stores only protected stubs" do
    enable!()
    append!("password=abcdefghijklmnopqrstuvwxyz")
    append!("My routing number is 123456789.")
    append!("My dependent has a private appointment.")
    append!("My colleague has a private medical diagnosis.")

    assert {:ok, result} = Consolidator.run("alice")
    assert result.secret_dropped == 1
    assert result.protected_dropped == 1
    assert result.protected_routed == 2
    assert result.created == 2

    proposals = Proposals.list("alice")

    assert Enum.map(proposals, & &1.classification) |> Enum.sort() ==
             ["protected_dependent", "protected_third_party"]

    assert Enum.all?(proposals, &(&1.kind == "protected_stub"))
    assert Enum.all?(proposals, &is_nil(&1.proposed_claim))
    assert Enum.all?(proposals, &is_nil(&1.span_provenance))

    stored = inspect(proposals)
    refute stored =~ "abcdefghijklmnopqrstuvwxyz"
    refute stored =~ "123456789"
    refute stored =~ "private appointment"
    refute stored =~ "medical diagnosis"
  end

  defp enable! do
    assert {:ok, _setting} =
             Settings.put(
               "memory.consolidation.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, _setting} =
             Settings.put(
               "memory.collection.origin_grants",
               ["local_operator"],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )
  end

  defp append!(content) do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Consolidation")

    assert {:ok, _message} =
             Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
