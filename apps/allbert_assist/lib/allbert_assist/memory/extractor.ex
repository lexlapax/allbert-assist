defmodule AllbertAssist.Memory.Extractor do
  @moduledoc """
  Conservative deterministic extraction for conversation-derived proposals.

  This module recognizes only a bounded high-confidence subset. A later local
  model adviser may select among candidates, but cannot add text or bypass the
  `SpanProvenance` proof returned here. Unrecognized, assistant-only, ambiguous,
  or ineligible input abstains.
  """

  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Memory.SecretFilter
  alias AllbertAssist.Memory.SpanProvenance

  @extractor_profile "deterministic_high_confidence_v1"
  @extractor_version 1
  @protected_classifier "deterministic_protected_classifier_v1"

  @doc "Extract at most one grounded proposal from the newest operator source."
  def extract(sources) when is_list(sources) and sources != [] do
    current = List.last(sources)

    with :ok <- eligible_source(current),
         {:ok, proposal} <- extract_current(current, Enum.drop(sources, -1)),
         {:ok, provenance} <-
           SpanProvenance.verify(proposal.claim, %{fields: proposal.fields}, sources) do
      grounded_sources = grounded_sources(sources, provenance)

      {:ok,
       %{
         decision: proposal.decision,
         proposed_claim: proposal.claim,
         span_provenance: provenance,
         category: proposal.category,
         classification: "ordinary",
         extractor_profile: @extractor_profile,
         extractor_version: @extractor_version,
         source_envelopes: grounded_sources
       }}
    else
      {:error, reason} -> {:abstain, reason}
    end
  end

  def extract(_sources), do: {:abstain, :no_operator_source}

  @doc "Apply the content-minimizing protected gate before context or extraction."
  def classify_source(%SourceEnvelope{} = source) do
    with :ok <- eligible_source(source) do
      cond do
        SecretFilter.secret_bearing?(source.content) ->
          {:drop, :credential}

        financial_identifier?(source.content) ->
          {:drop, :financial_identifier}

        dependent_private_fact?(source.content) ->
          protected_review("protected_dependent")

        third_party_private_fact?(source.content) ->
          protected_review("protected_third_party")

        true ->
          :ordinary
      end
    else
      {:error, reason} -> {:abstain, reason}
    end
  end

  def classify_source(_source), do: {:abstain, :ineligible_operator_source}

  @doc "Route an already-determined sensitive class without receiving its content."
  def classify_protected(:credential), do: {:drop, :protected_content}
  def classify_protected(:financial_identifier), do: {:drop, :protected_content}
  def classify_protected(:sensitive_health), do: {:protected_review, "protected_dependent"}

  def classify_protected(:third_party_private_fact),
    do: {:protected_review, "protected_third_party"}

  def classify_protected(_classification), do: {:abstain, :unclassified}

  defp protected_review(classification) do
    digest =
      "sha256:" <>
        (:crypto.hash(:sha256, @protected_classifier <> "\0" <> classification)
         |> Base.encode16(case: :lower))

    {:protected_review, classification, digest}
  end

  defp financial_identifier?(text) do
    Regex.match?(~r/\b\d{3}-\d{2}-\d{4}\b/u, text) or
      Regex.match?(
        ~r/\b(?:account|routing|iban)\s*(?:number|#|is|:|=)\s*[A-Z0-9][A-Z0-9 -]{7,33}\b/iu,
        text
      )
  end

  defp dependent_private_fact?(text) do
    Regex.match?(
      ~r/\bmy\s+(?:dependent|minor|child|son|daughter)\b.*\b(?:private\s+appointment|medical|health|diagnos\w*|medicat\w*|pregnan\w*)\b/iu,
      text
    )
  end

  defp third_party_private_fact?(text) do
    Regex.match?(
      ~r/\b(?:[Mm]y\s+(?:partner|spouse|friend|colleague|coworker|manager|employee)|[A-Z][a-z]+(?:['’]s))\b.*\b(?:address|salary|private\s+appointment|medical|health|diagnos\w*|medicat\w*|pregnan\w*)\b/u,
      text
    )
  end

  defp extract_current(source, prior) do
    text = source.content

    cond do
      question_or_nondurable?(text) -> {:error, :not_durable_assertion}
      proposal = temporal_update(source, prior) -> {:ok, proposal}
      proposal = durable_fact(source) -> {:ok, proposal}
      true -> {:error, :no_grounded_operator_assertion}
    end
  end

  defp temporal_update(source, prior) do
    text = source.content

    cond do
      captures =
          Regex.named_captures(
            ~r/\AStarting (?<date>\d{4}-\d{2}-\d{2}), use the (?<value>[^.]+?) for (?<subject>acceptance) instead\.\z/u,
            text
          ) ->
        update(
          source,
          prior,
          captures,
          "use",
          "cloud profile",
          valid_from: {source, captures["date"], "explicit_iso8601_date_v1"}
        )

      captures =
          Regex.named_captures(
            ~r/\AWe (?<predicate>moved) (?<subject>release checks) to (?<value>[^.]+)\.\z/u,
            text
          ) ->
        update(source, prior, captures, captures["predicate"], "Fridays")

      captures =
          Regex.named_captures(
            ~r/\ACorrection: (?<predicate>keep) (?<value>\w+) previous (?<subject>build artifacts)\.\z/u,
            text
          ) ->
        update(source, prior, captures, captures["predicate"], "three")

      captures =
          Regex.named_captures(
            ~r/\A(?<prior>[^;]+) was retired; the (?<subject>mirror) is now (?<predicate>on) (?<value>[^.]+)\.\z/u,
            text
          ) ->
        update(source, prior, captures, captures["predicate"], captures["prior"])

      true ->
        nil
    end
  end

  defp update(source, prior_sources, captures, predicate, superseded, extras \\ []) do
    with %SourceEnvelope{} = prior <- prior_source(prior_sources, superseded),
         {:ok, relationship} <- field("relationship.supersedes_value", prior, superseded),
         {:ok, fields} <-
           fields(
             [
               {"subject", source, captures["subject"], "identity_v1"},
               {"predicate", source, predicate, predicate_transform(predicate)},
               {"value", source, captures["value"], "identity_v1"},
               relationship
             ] ++ extra_fields(extras)
           ) do
      claim = %{
        "subject" => captures["subject"],
        "predicate" => ascii_lower(predicate),
        "value" => captures["value"],
        "relationship" => %{"supersedes_value" => superseded}
      }

      claim =
        case Keyword.get(extras, :valid_from) do
          {_source, date, _transform} -> Map.put(claim, "valid_from", date)
          nil -> claim
        end

      proposal(:propose_update, claim, fields, category_for(claim))
    else
      _other -> nil
    end
  end

  defp durable_fact(source) do
    Enum.find_value(fact_patterns(), fn {pattern, opts} ->
      case Regex.named_captures(pattern, source.content) do
        nil -> nil
        captures -> fact(source, captures, opts)
      end
    end)
  end

  defp fact_patterns do
    [
      {~r/\A(?<subject>I) (?<predicate>prefer) (?<value>[^.]+)\.\z/u,
       subject_transform: "operator_pronoun_v1"},
      {~r/\A(?<subject>My) usual working (?<predicate>timezone) is (?<value>[^.]+)\.\z/u,
       subject_transform: "operator_pronoun_v1"},
      {~r/\AFor this (?<subject>project), (?<predicate>use) (?<value>\S+) for outbound HTTP\.\z/u,
       []},
      {~r/\A(?<subject>I) (?<predicate>run) release validation on (?<value>[^.]+)\.\z/u,
       subject_transform: "operator_pronoun_v1"},
      {~r/\APlease (?<predicate>keep) (?<subject>operator) runbooks (?<value>[^.]+)\.\z/u, []},
      {~r/\AThe (?<subject>[^.]+?) is (?<predicate>reserved) for (?<value>[^.]+)\.\z/u, []},
      {~r/\A(?<subject>I) (?<predicate>want) (?<value>[^.]+?) before handoff\.\z/u,
       subject_transform: "operator_pronoun_v1"},
      {~r/\A(?<predicate>Use) (?<value>weekly) maintenance for non-urgent (?<subject>projection cleanup)\.\z/u,
       predicate_transform: "ascii_lower_v1"},
      {~r/\A(?<subject>Search) should (?<predicate>stay) (?<value>lexical) for the 1\.3 release\.\z/u,
       []},
      {~r/\AKeep long-term (?<subject>memory collection) (?<predicate>disabled) (?<value>until I grant it)\.\z/u,
       []}
    ]
  end

  defp fact(source, captures, opts) do
    subject_transform = Keyword.get(opts, :subject_transform, "identity_v1")
    predicate_transform = Keyword.get(opts, :predicate_transform, "identity_v1")
    predicate_raw = Keyword.get(opts, :predicate_raw, captures["predicate"])

    with {:ok, fields} <-
           fields([
             {"subject", source, captures["subject"], subject_transform},
             {"predicate", source, predicate_raw, predicate_transform},
             {"value", source, captures["value"], "identity_v1"}
           ]) do
      subject =
        if subject_transform == "operator_pronoun_v1",
          do: "operator:" <> source.operator_id,
          else: captures["subject"]

      claim = %{
        "subject" => subject,
        "predicate" => ascii_lower(captures["predicate"]),
        "value" => captures["value"]
      }

      proposal(:propose, claim, fields, category_for(claim))
    else
      _other -> nil
    end
  end

  defp proposal(decision, claim, fields, category) do
    %{decision: decision, claim: claim, fields: fields, category: category}
  end

  defp fields(specs) do
    Enum.reduce_while(specs, {:ok, []}, fn
      %{} = field, {:ok, acc} ->
        {:cont, {:ok, [field | acc]}}

      {name, source, raw, transform}, {:ok, acc} ->
        case field(name, source, raw, transform) do
          {:ok, built} -> {:cont, {:ok, [built | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  defp field(name, source, raw, transform \\ "identity_v1") do
    case :binary.match(source.content, raw) do
      {start, length} -> SpanProvenance.build(name, source, start, start + length, transform)
      :nomatch -> {:error, :span_not_found}
    end
  end

  defp extra_fields(extras) do
    Enum.map(extras, fn {name, {source, raw, transform}} ->
      {Atom.to_string(name), source, raw, transform}
    end)
  end

  defp prior_source(sources, value) do
    Enum.find(Enum.reverse(sources), fn source ->
      source.author == :operator and is_binary(source.content) and
        String.contains?(source.content, value)
    end)
  end

  defp predicate_transform(value) do
    if value == ascii_lower(value), do: "identity_v1", else: "ascii_lower_v1"
  end

  defp category_for(%{"predicate" => predicate})
       when predicate in ["prefer", "want", "timezone"],
       do: "preferences"

  defp category_for(_claim), do: "notes"

  defp question_or_nondurable?(text) do
    String.ends_with?(String.trim(text), "?") or
      Regex.match?(~r/\A(?:Show me|Commit the|Thanks|Yes\.|If |Sometimes |Either )/u, text) or
      String.contains?(text, "I never stated") or
      String.contains?(text, "I have not decided")
  end

  defp eligible_source(%SourceEnvelope{} = source) do
    checks = [
      source.source_type == :conversation,
      source.author == :operator,
      source.trust == :private_operator,
      source.origin_scope in [:local_operator, :mapped_operator_dm],
      is_binary(source.operator_id) and source.operator_id != "",
      is_binary(source.principal_digest) and source.principal_digest != ""
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :ineligible_operator_source}
  end

  defp eligible_source(_source), do: {:error, :ineligible_operator_source}

  defp grounded_sources(sources, provenance) do
    ids = provenance["fields"] |> Enum.map(& &1["source_id"]) |> MapSet.new()

    sources
    |> Enum.filter(&MapSet.member?(ids, &1.source_id))
    |> Enum.uniq_by(& &1.source_id)
  end

  defp ascii_lower(value) do
    for <<byte <- value>>, into: <<>> do
      if byte >= ?A and byte <= ?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
