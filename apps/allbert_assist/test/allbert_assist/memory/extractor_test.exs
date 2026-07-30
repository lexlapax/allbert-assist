defmodule AllbertAssist.Memory.ExtractorTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Memory.Extractor
  alias AllbertAssist.Memory.SpanProvenance

  @fixture Path.expand("../../fixtures/v1.3/memory/calibration.json", __DIR__)

  test "M1 calibration floors are met by grounded deterministic extraction" do
    calibration = @fixture |> File.read!() |> Jason.decode!()
    cases = calibration["cases"]

    eligible = Enum.filter(cases, &(&1["kind"] in ["eligible_fact", "temporal_update"]))
    abstention = Enum.filter(cases, &String.starts_with?(&1["id"], "mem-abstain"))

    eligible_results = Enum.map(eligible, &score_eligible/1)
    abstention_results = Enum.map(abstention, &score_abstention/1)

    failed_eligible_ids =
      eligible
      |> Enum.zip(eligible_results)
      |> Enum.reject(fn {_test_case, matched?} -> matched? end)
      |> Enum.map(fn {test_case, _matched?} -> test_case["id"] end)

    true_positive = Enum.count(eligible_results, & &1)
    false_positive = Enum.count(abstention_results, &(not &1))
    precision = true_positive / max(true_positive + false_positive, 1)
    recall = true_positive / length(eligible)
    abstention_rate = Enum.count(abstention_results, & &1) / length(abstention)
    scoring = calibration["scoring"]

    assert failed_eligible_ids == []
    assert true_positive == 14
    assert false_positive == 0
    assert Enum.count(abstention_results, & &1) == 18
    assert precision >= scoring["eligible_precision_floor"]
    assert recall >= scoring["eligible_recall_floor"]
    assert abstention_rate >= scoring["required_abstention_floor"]
  end

  test "protected classes drop credentials and identifiers or route content-free individual review" do
    assert {:drop, :protected_content} = Extractor.classify_protected(:credential)
    assert {:drop, :protected_content} = Extractor.classify_protected(:financial_identifier)

    assert {:protected_review, "protected_dependent"} =
             Extractor.classify_protected(:sensitive_health)

    assert {:protected_review, "protected_third_party"} =
             Extractor.classify_protected(:third_party_private_fact)
  end

  test "source classifier is narrow, deterministic, and content minimizing" do
    assert {:drop, :credential} =
             Extractor.classify_source(source("password=abcdefghijklmnopqrstuvwxyz", "operator"))

    assert {:drop, :financial_identifier} =
             Extractor.classify_source(source("My routing number is 123456789.", "operator"))

    assert {:protected_review, "protected_dependent", dependent_digest} =
             Extractor.classify_source(
               source("My dependent has a private appointment.", "operator")
             )

    assert {:protected_review, "protected_third_party", third_party_digest} =
             Extractor.classify_source(
               source("My colleague has a private medical diagnosis.", "operator")
             )

    assert dependent_digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert third_party_digest =~ ~r/^sha256:[0-9a-f]{64}$/
    refute dependent_digest == third_party_digest
    assert :ordinary = Extractor.classify_source(source("I prefer tea.", "operator"))
  end

  test "every emitted semantic field re-verifies against operator sources" do
    sources = [source("I prefer concise evidence.", "operator")]
    assert {:ok, result} = Extractor.extract(sources)

    assert {:ok, _verified} =
             SpanProvenance.verify(
               result.proposed_claim,
               result.span_provenance,
               result.source_envelopes
             )

    assistant = %{hd(sources) | author: :assistant, role: "assistant"}
    assert {:abstain, :ineligible_operator_source} = Extractor.extract([assistant])
  end

  defp score_eligible(test_case) do
    sources = sources(test_case)
    expected = test_case["expected"]

    case Extractor.extract(sources) do
      {:ok, result} -> expected_match?(result, expected)
      {:abstain, _reason} -> false
    end
  end

  defp score_abstention(test_case) do
    case Extractor.extract(sources(test_case)) do
      {:abstain, _reason} -> true
      {:ok, _proposal} -> false
    end
  end

  defp expected_match?(result, expected) do
    claim = result.proposed_claim

    decision_matches?(result.decision, expected["decision"]) and
      expected_claim_matches?(claim, expected)
  end

  defp decision_matches?(:propose, "propose"), do: true
  defp decision_matches?(:propose_update, "propose_update"), do: true
  defp decision_matches?(_decision, _expected), do: false

  defp expected_claim_matches?(claim, expected) do
    subject = normalized_subject(claim["subject"])

    subject == Map.get(expected, "subject", subject) and
      claim["predicate"] == Map.get(expected, "predicate", claim["predicate"]) and
      claim["value"] == expected["object"] and
      claim["valid_from"] == Map.get(expected, "valid_from") and
      get_in(claim, ["relationship", "supersedes_value"]) == Map.get(expected, "supersedes")
  end

  defp normalized_subject("operator:" <> _operator_id), do: "operator"
  defp normalized_subject(value), do: value

  defp sources(test_case) do
    metadata = Map.get(test_case, "source", %{})

    test_case["turns"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {turn, index} ->
      case turn["text"] do
        text when is_binary(text) -> [source(text, turn["author"], metadata, index)]
        nil -> []
      end
    end)
  end

  defp source(content, author, metadata \\ %{}, index \\ 0) do
    {author_atom, role} = source_author(author)
    origin_scope = source_origin(metadata["origin"])

    %SourceEnvelope{
      source_type: :conversation,
      source_id: Ecto.UUID.generate(),
      thread_id: Ecto.UUID.generate(),
      operator_id: "alice",
      user_id: "alice",
      principal_digest: source_principal(metadata),
      role: role,
      author: author_atom,
      trust: :private_operator,
      origin_scope: origin_scope,
      origin_overlays: if(metadata["e2ee"], do: [:e2ee_operator], else: []),
      surface: "tui",
      thread_kind: "general",
      content: content,
      content_digest: digest(content),
      inserted_at: DateTime.add(~U[2026-07-30 00:00:00Z], index, :second),
      source_version: 1,
      origin: nil,
      trace_refs: []
    }
  end

  defp source_author("operator"), do: {:operator, "user"}
  defp source_author("assistant"), do: {:assistant, "assistant"}
  defp source_author(_author), do: {:trace, "trace"}

  defp source_origin("mapped_operator_dm"), do: :mapped_operator_dm
  defp source_origin(nil), do: :local_operator
  defp source_origin(origin), do: String.to_atom(origin)

  defp source_principal(metadata) do
    invalid? =
      metadata["principal"] == "unknown" or
        metadata["principal_mapping"] == "unverified_remap" or
        metadata["grant"] == false

    if invalid?, do: nil, else: digest("alice")
  end

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end
end
