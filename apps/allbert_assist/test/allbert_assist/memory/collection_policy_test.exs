defmodule AllbertAssist.Memory.CollectionPolicyTest do
  @moduledoc """
  v1.3 M9.b.13.a — the gate deciding whether conversation content may become Memory.

  This module had no direct coverage. It is the only place the Memory-specific
  collection grant is evaluated, so an over-permissive eligibility check would
  collect content Allbert is not allowed to collect — assistant output, another
  principal's messages, or a channel outside the operator's grant — and nothing
  downstream would notice, because everything after this point treats an
  admitted source as authorized.

  These rows exercise refusal on each eligibility dimension independently.
  Asserting only the happy path would leave every individual gate untested,
  since one satisfied condition masks another.
  """

  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Memory.CollectionPolicy

  defp eligible_envelope(overrides \\ []) do
    struct!(
      %SourceEnvelope{
        source_type: :conversation,
        source_id: "msg_#{System.unique_integer([:positive])}",
        thread_id: "thr_#{System.unique_integer([:positive])}",
        operator_id: "local",
        principal_digest: "sha256:" <> String.duplicate("a", 64),
        author: :operator,
        trust: :private_operator,
        origin_scope: :local_operator,
        origin_overlays: [],
        content: "I prefer Friday at 09:00.",
        content_digest: "sha256:" <> String.duplicate("b", 64),
        user_id: "local",
        role: "user",
        surface: "cli",
        thread_kind: "general",
        inserted_at: ~U[2026-08-03 12:00:00Z],
        source_version: 1,
        origin: nil,
        trace_refs: []
      },
      overrides
    )
  end

  describe "policy/1" do
    test "derives the memory consumer and carries the source's origin scope" do
      policy = CollectionPolicy.policy(eligible_envelope())

      assert policy.consumer == :memory
      assert policy.origin_scope == :local_operator
      assert policy.e2ee? == false
    end

    test "reports e2ee when the source carries the operator overlay" do
      policy =
        CollectionPolicy.policy(eligible_envelope(origin_overlays: [:e2ee_operator]))

      assert policy.e2ee? == true,
             "an E2EE source must be declared as such so Corpus can refuse it"
    end

    test "a mapped DM keeps its own scope rather than being normalised to local" do
      policy = CollectionPolicy.policy(eligible_envelope(origin_scope: :mapped_operator_dm))
      assert policy.origin_scope == :mapped_operator_dm
    end
  end

  describe "reauthorize/1 input refusal" do
    test "a non-envelope is refused" do
      assert {:error, :invalid_source_envelope} = CollectionPolicy.reauthorize(nil)
      assert {:error, :invalid_source_envelope} = CollectionPolicy.reauthorize(%{})
      assert {:error, :invalid_source_envelope} = CollectionPolicy.reauthorize("msg_1")
    end
  end

  describe "reauthorize/1 eligibility, one dimension at a time" do
    test "assistant-authored content is refused" do
      assert {:error, :ineligible_memory_source} =
               CollectionPolicy.reauthorize(eligible_envelope(author: :assistant))
    end

    test "content above private-operator trust is refused" do
      assert {:error, :ineligible_memory_source} =
               CollectionPolicy.reauthorize(eligible_envelope(trust: :shared))
    end

    test "an origin scope outside the Memory grant is refused" do
      assert {:error, :ineligible_memory_source} =
               CollectionPolicy.reauthorize(eligible_envelope(origin_scope: :external_history))

      assert {:error, :ineligible_memory_source} =
               CollectionPolicy.reauthorize(eligible_envelope(origin_scope: nil))
    end

    test "a non-conversation source type is refused" do
      assert {:error, :ineligible_memory_source} =
               CollectionPolicy.reauthorize(eligible_envelope(source_type: :trace))
    end

    test "a missing operator, principal, or content digest is refused" do
      for override <- [
            [operator_id: nil],
            [operator_id: ""],
            [principal_digest: nil],
            [principal_digest: ""],
            [content_digest: nil],
            [content_digest: ""]
          ] do
        assert {:error, :ineligible_memory_source} =
                 CollectionPolicy.reauthorize(eligible_envelope(override)),
               "expected refusal for #{inspect(override)}"
      end
    end
  end

  describe "reauthorize_evidence/2 input refusal" do
    test "a non-binary operator or non-map evidence is refused" do
      assert {:error, :invalid_source_evidence} =
               CollectionPolicy.reauthorize_evidence(nil, %{})

      assert {:error, :invalid_source_evidence} =
               CollectionPolicy.reauthorize_evidence("local", nil)

      assert {:error, :invalid_source_evidence} =
               CollectionPolicy.reauthorize_evidence("local", "refs")
    end

    test "evidence carrying neither a refs list nor a valid inline ref is refused" do
      # `evidence_refs/1` treats a map without "refs" as one inline ref, so an
      # empty map is a malformed ref rather than zero refs. It fails closed on
      # the origin scope, which is the right direction: rehydrating nothing and
      # reporting success would let a proposal claim provenance it never had.
      assert {:error, :invalid_origin_scope} =
               CollectionPolicy.reauthorize_evidence("local", %{})
    end

    test "an unknown origin scope is refused rather than downgraded" do
      assert {:error, :invalid_origin_scope} =
               CollectionPolicy.reauthorize_evidence("local", %{
                 "refs" => [%{"origin_scope" => "external_history", "source_id" => "msg_1"}]
               })
    end
  end
end
