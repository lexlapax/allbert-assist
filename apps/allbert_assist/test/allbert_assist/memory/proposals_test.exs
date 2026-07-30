defmodule AllbertAssist.Memory.ProposalsTest do
  use AllbertAssist.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Memory.Proposals.Suppression
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_home = System.get_env("ALLBERT_HOME")

    root =
      Path.join(System.tmp_dir!(), "allbert-proposals-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    System.put_env("ALLBERT_HOME", root)

    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)

    assert {:ok, _setting} =
             Settings.put("memory.collection.origin_grants", ["local_operator"])

    on_exit(fn ->
      restore_env(Settings, original_settings)
      restore_system_env("ALLBERT_HOME", original_home)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "ordinary proposal stores a normalized claim and evidence, not a transcript" do
    {source, content} = source("I prefer tea with breakfast.")

    assert {:ok, %{outcome: :created, proposal: proposal}} =
             Proposals.propose(source, ordinary_attrs(content, "tea"))

    assert proposal.kind == "ordinary"
    assert proposal.status == "pending"
    assert proposal.proposed_claim["value"] == "tea"
    assert proposal.source_evidence["source_id"] == source.source_id
    assert proposal.source_evidence["content_digest"] == source.content_digest
    assert proposal.span_provenance["fields"] != []
    refute inspect(proposal.source_evidence) =~ content
    assert Proposals.pending_count("alice") == 1

    assert {:ok, %{outcome: :existing, proposal: same}} =
             Proposals.propose(source, ordinary_attrs(content, "tea"))

    assert same.id == proposal.id
    assert Repo.aggregate(Proposal, :count) == 1
  end

  test "protected proposals are content-free stubs and cannot carry claim fields" do
    {source, content} = source("My dependent has a private appointment.")
    classifier_digest = digest("protected-dependent-v1")

    attrs = %{
      classification: "protected_dependent",
      classifier_digest: classifier_digest,
      category: "notes",
      namespace: "default",
      run_id: "run-protected",
      extractor_profile: "deterministic_v1",
      extractor_version: 1
    }

    assert {:ok, %{outcome: :created, proposal: proposal}} =
             Proposals.propose_protected(source, attrs)

    assert proposal.kind == "protected_stub"
    assert proposal.classification == "protected_dependent"
    assert is_nil(proposal.proposed_claim)
    assert is_nil(proposal.span_provenance)
    assert is_nil(proposal.applying_payload)
    refute inspect(proposal) =~ content

    assert {:error, database_error} =
             SQL.query(
               Repo,
               "UPDATE memory_proposals SET proposed_claim = ? WHERE id = ?",
               [Jason.encode!(%{"value" => "database bypass"}), proposal.id]
             )

    assert Exception.message(database_error) =~ "memory_proposals_protected_stub_content_check"

    assert {:error, :protected_stub_content_forbidden} =
             Proposals.propose_protected(
               source,
               Map.put(attrs, :proposed_claim, %{"value" => "must not persist"})
             )
  end

  test "current Corpus source and grant authority is required at admission" do
    {source, content} = source("I prefer metric units.")

    stale = %{source | content_digest: digest("changed")}

    assert {:error, :digest_mismatch} =
             Proposals.propose(stale, ordinary_attrs(content, "metric"))

    assert {:ok, _setting} = Settings.put("memory.collection.origin_grants", [])

    assert {:error, :origin_grant_required} =
             Proposals.propose(source, ordinary_attrs(content, "metric"))

    assert Repo.aggregate(Proposal, :count) == 0
  end

  test "assistant sources and credential-shaped values produce no proposal" do
    {operator_source, content} = source("The operator prefers tea.")
    source = %{operator_source | author: :assistant, role: "assistant"}

    assert {:error, :ineligible_memory_source} =
             Proposals.propose(source, ordinary_attrs(content, "tea"))

    {operator_source, operator_content} = source("Remember token=abcdefghijklmnopqrstuvwxyz")

    assert {:error, :secret_filtered} =
             Proposals.propose(
               operator_source,
               ordinary_attrs(operator_content, "token=abcdefghijklmnopqrstuvwxyz")
             )

    assert Repo.aggregate(Proposal, :count) == 0
  end

  test "exact rejected evidence and pending backpressure suppress inert writes" do
    {source, content} = source("I prefer item zero.")
    attrs = ordinary_attrs(content, "item zero")
    proposal_digest = Proposals.proposal_digest("default", stringify(attrs.proposed_claim))

    assert {:ok, _suppression} =
             %Suppression{}
             |> Suppression.changeset(%{
               id: Ecto.UUID.generate(),
               operator_id: "alice",
               namespace: "default",
               proposal_digest: proposal_digest,
               source_digest: source.content_digest,
               normalizer_version: 1,
               reason: "operator_rejected"
             })
             |> Repo.insert()

    assert {:error, :unchanged_reject_suppressed} = Proposals.propose(source, attrs)

    for index <- 1..50 do
      value = "bounded item #{index}"

      assert {:ok, %{outcome: :created}} =
               Proposals.propose(source, ordinary_attrs(content, value))
    end

    assert Proposals.pending_count("alice") == 50

    assert {:error, :pending_cap_reached} =
             Proposals.propose(source, ordinary_attrs(content, "one item too many"))
  end

  defp source(content), do: envelope(content, &Conversations.append_user_message/3)

  defp envelope(content, append) do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Proposal source")
    assert {:ok, message} = append.(thread, content, metadata: %{"channel" => "tui"})

    policy = %{consumer: :memory, origin_scope: :local_operator, e2ee?: false}
    assert {:ok, snapshot} = Corpus.snapshot("alice", policy)
    assert {:ok, page} = Corpus.page(snapshot, nil, 100)
    source = Enum.find(page.items, &(&1.source_id == message.id))
    assert source
    {source, content}
  end

  defp ordinary_attrs(content, value) do
    start = byte_offset(content, value)

    %{
      proposed_claim: %{
        subject: "operator:alice",
        predicate: "preference",
        value: value,
        valid_from: nil,
        valid_to: nil,
        relationship: nil
      },
      span_provenance: %{
        fields: [
          %{
            field: "value",
            byte_start: start,
            byte_end: start + byte_size(value),
            raw_span_digest: digest(value),
            normalized_value: value,
            transform: "identity_v1"
          }
        ]
      },
      category: "preferences",
      namespace: "default",
      run_id: "run-ordinary",
      extractor_profile: "deterministic_v1",
      extractor_version: 1
    }
  end

  defp byte_offset(content, value) do
    case :binary.match(content, value) do
      {offset, _length} -> offset
      :nomatch -> 0
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
