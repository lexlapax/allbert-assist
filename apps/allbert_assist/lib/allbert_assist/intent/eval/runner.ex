defmodule AllbertAssist.Intent.Eval.Runner do
  @moduledoc """
  Deterministic replay runner for the committed intent eval corpus.

  M1 deliberately exercises the real Stage-1 ranking math with a frozen fake
  embedder seam. Later milestones can layer action-backed CLI/TUI surfaces and
  live-provider lanes on top of this stable core.
  """

  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Eval.Corpus
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.Disambiguator
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Intent.Router.InputGuard
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.Prefilter
  alias AllbertAssist.Intent.SelectionPolicy

  @type run_result :: %{
          case: Corpus.t(),
          actual: map(),
          shortlist: [map()],
          margin: float()
        }

  @spec run([Corpus.t()], keyword()) :: %{results: [run_result()], metadata: map()}
  def run(corpus, opts \\ []) when is_list(corpus) do
    embedder = Keyword.get(opts, :embedder, FakeEmbedder)
    entries = entries(opts, embedder)
    top_k = Keyword.get(opts, :top_k, 5)
    cases = filter_surface(corpus, Keyword.get(opts, :surface, :any))

    results =
      Enum.map(cases, fn case ->
        ranked = rank_case(case, entries, embedder, top_k)
        actual = route_case(case, ranked, entries, opts)

        %{case: case, actual: actual, shortlist: ranked.shortlist, margin: ranked.margin}
      end)

    %{
      results: results,
      metadata: %{
        total: length(results),
        surface: Keyword.get(opts, :surface, :any),
        disambiguator: inspect(Keyword.get(opts, :disambiguator, :top_ranked_fake)),
        embedder: inspect(embedder),
        top_k: top_k
      }
    }
  end

  defp filter_surface(cases, :any), do: cases

  defp filter_surface(cases, surface) do
    Enum.filter(cases, &(&1.surface in [:any, surface]))
  end

  defp entries(opts, embedder) do
    cond do
      Keyword.has_key?(opts, :entries) ->
        normalize_entries(Keyword.fetch!(opts, :entries), embedder)

      Keyword.has_key?(opts, :descriptors) ->
        entries_from_descriptors(Keyword.fetch!(opts, :descriptors), embedder)

      true ->
        DescriptorResolver.resolve(availability: :deterministic_eval)
        |> entries_from_descriptors(embedder)
    end
  end

  defp entries_from_descriptors(descriptors, embedder) do
    texts = Enum.map(descriptors, &Index.utterance_text/1)
    {:ok, vectors} = embedder.embed(texts, [])

    descriptors
    |> Enum.zip(vectors)
    |> Enum.map(fn {descriptor, vector} ->
      %{
        action_name: descriptor.action_name,
        app_id: descriptor.app_id,
        label: to_string(descriptor.label),
        text: Index.utterance_text(descriptor),
        descriptor: descriptor,
        required_slots: descriptor.required_slots,
        optional_slots: descriptor.optional_slots,
        vector: vector
      }
    end)
  end

  defp normalize_entries(entries, embedder) do
    missing_vectors = Enum.filter(entries, &(not Map.has_key?(&1, :vector)))

    vector_by_text =
      case missing_vectors do
        [] ->
          %{}

        entries ->
          texts = Enum.map(entries, &entry_text/1)
          {:ok, vectors} = embedder.embed(texts, [])
          texts |> Enum.zip(vectors) |> Map.new()
      end

    Enum.map(entries, fn entry ->
      entry
      |> Map.put_new(:text, entry_text(entry))
      |> Map.put_new(:label, Map.get(entry, :action_name, ""))
      |> Map.put_new(:app_id, nil)
      |> Map.put_new(:required_slots, [])
      |> Map.put_new(:optional_slots, [])
      |> put_vector(vector_by_text)
    end)
  end

  defp put_vector(%{vector: _vector} = entry, _vector_by_text), do: entry

  defp put_vector(entry, vector_by_text) do
    Map.put(entry, :vector, Map.fetch!(vector_by_text, entry_text(entry)))
  end

  defp entry_text(entry) do
    [
      Map.get(entry, :text),
      Map.get(entry, :label),
      Map.get(entry, :action_name),
      Map.get(entry, :examples, [])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" ; ")
  end

  defp rank_case(%Corpus.Case{utterance: utterance}, entries, embedder, top_k) do
    with {:ok, [query_vector]} <- embedder.embed([utterance], []) do
      Prefilter.rank(query_vector, entries, top_k, utterance)
    else
      _error -> %{shortlist: [], margin: 0.0}
    end
  end

  defp route_case(case, ranked, entries, opts) do
    case Keyword.get(opts, :selector) do
      selector when is_function(selector, 2) ->
        selector.(case, ranked.shortlist)
        |> normalize_actual(ranked)
        |> apply_normalized_selection_policy(case.utterance, ranked.shortlist, entries)

      _other ->
        opts
        |> Keyword.get(:disambiguator, :top_ranked_fake)
        |> select(case, ranked, opts)
        |> outcome(case, ranked, entries, opts)
    end
  end

  defp select(
         :top_ranked_fake,
         %Corpus.Case{utterance: utterance},
         ranked,
         _opts
       ) do
    semantic_fake_selection(utterance, ranked)
  end

  defp select(module, case, ranked, opts) when is_atom(module) do
    module.select(case.utterance, ranked.shortlist, case.context, opts)
  end

  defp semantic_fake_selection(utterance, ranked) do
    case InputGuard.sentinel_selection(utterance) do
      {:ok, selection} ->
        {:ok, selection}

      :continue ->
        cond do
          unsafe_or_noisy_none?(utterance) ->
            {:ok, %{selected: "__none__", confidence: 1.0, slots: %{}}}

          general_answer_question?(utterance) ->
            {:ok, %{selected: "__answer__", confidence: 1.0, slots: %{}}}

          ambiguous_operator_noun_phrase?(utterance, ranked.shortlist) ->
            {:ok, %{selected: "__clarify__", confidence: 0.7, slots: %{}}}

          true ->
            top_ranked_selection(ranked)
        end
    end
  end

  defp top_ranked_selection(%{shortlist: [%{action_name: action} = top | _rest]}) do
    {:ok,
     %{
       selected: action,
       confidence: 1.0,
       slots: Map.get(top, :extracted_slots, %{})
     }}
  end

  defp top_ranked_selection(%{shortlist: []}) do
    {:ok, %{selected: "__none__", confidence: 1.0, slots: %{}}}
  end

  defp outcome({:ok, selection}, case, ranked, entries, opts) do
    decision_opts =
      opts
      |> Keyword.put_new(:query, case.utterance)
      |> Keyword.put_new(:min_confidence, 0.0)

    selection
    |> Disambiguator.decide(ranked.shortlist, ranked.margin, decision_opts)
    |> apply_selection_policy(case.utterance, entries)
    |> normalize_actual(ranked)
  end

  defp outcome({:error, reason}, _case, ranked, _entries, _opts) do
    normalize_actual(
      %{kind: :defer, action: nil, slots: %{}, confidence: nil, reason: reason},
      ranked
    )
  end

  defp apply_selection_policy(%Outcome{kind: :execute} = outcome, utterance, entries) do
    action_names = proposal_action_names(outcome)
    descriptors = Enum.flat_map(entries, &entry_descriptor/1)

    if SelectionPolicy.accept_all?(action_names, utterance, descriptors: descriptors) do
      outcome
    else
      Outcome.answer(Map.put(outcome.diagnostics, :selection_rejected?, true))
    end
  end

  defp apply_selection_policy(%Outcome{kind: :clarify} = outcome, utterance, entries) do
    descriptors = Enum.flat_map(entries, &entry_descriptor/1)

    case SelectionPolicy.grounded_shortlist(outcome.shortlist, utterance,
           descriptors: descriptors
         ) do
      {:ok, shortlist} ->
        %{outcome | shortlist: shortlist}

      :error ->
        Outcome.answer(Map.put(outcome.diagnostics, :selection_rejected?, true))
    end
  end

  defp apply_selection_policy(outcome, _utterance, _entries), do: outcome

  defp apply_normalized_selection_policy(
         %{kind: :execute, action: action_name} = actual,
         utterance,
         _shortlist,
         entries
       )
       when is_binary(action_name) do
    descriptors = Enum.flat_map(entries, &entry_descriptor/1)

    if SelectionPolicy.evaluate(action_name, utterance, descriptors: descriptors).accepted? do
      actual
    else
      Map.merge(actual, %{kind: :answer, action: nil, diagnostics: %{selection_rejected?: true}})
    end
  end

  defp apply_normalized_selection_policy(
         %{kind: :clarify} = actual,
         utterance,
         ranked_shortlist,
         entries
       ) do
    descriptors = Enum.flat_map(entries, &entry_descriptor/1)
    proposed_shortlist = Map.get(actual, :shortlist, ranked_shortlist)

    case SelectionPolicy.grounded_shortlist(proposed_shortlist, utterance,
           descriptors: descriptors
         ) do
      {:ok, shortlist} ->
        Map.put(actual, :shortlist, shortlist)

      :error ->
        Map.merge(actual, %{kind: :answer, action: nil, diagnostics: %{selection_rejected?: true}})
    end
  end

  defp apply_normalized_selection_policy(actual, _utterance, _shortlist, _entries), do: actual

  defp proposal_action_names(%Outcome{kind: :execute, action_name: action_name}),
    do: List.wrap(action_name)

  defp entry_descriptor(%{descriptor: %Descriptor{} = descriptor}), do: [descriptor]

  # Explicit `entries:` is a deterministic runner test seam. Give those entries
  # the same semantic-default descriptor shape instead of bypassing policy.
  defp entry_descriptor(%{action_name: action_name} = entry) when is_binary(action_name) do
    [
      %Descriptor{
        id: "eval-entry:#{action_name}",
        app_id: Map.get(entry, :app_id) || :allbert,
        action_name: action_name,
        label: to_string(Map.get(entry, :label, action_name)),
        selection_policy: Map.get(entry, :selection_policy, :semantic),
        examples: Map.get(entry, :examples, []),
        synonyms: Map.get(entry, :synonyms, []),
        required_slots: Map.get(entry, :required_slots, []),
        optional_slots: Map.get(entry, :optional_slots, []),
        slot_extractors: Map.get(entry, :slot_extractors, %{}),
        vocabulary: Map.get(entry, :vocabulary, %{})
      }
    ]
  end

  defp entry_descriptor(_entry), do: []

  defp normalize_actual(%Outcome{} = outcome, ranked) do
    %{
      kind: outcome.kind,
      action: outcome.action_name,
      slots: outcome.slots || %{},
      confidence: outcome.confidence,
      shortlist: normalized_shortlist(outcome, ranked),
      reason: outcome.reason,
      diagnostics: outcome.diagnostics
    }
  end

  defp normalize_actual(%{kind: kind} = actual, ranked) do
    actual
    |> Map.put_new(:action, Map.get(actual, :action_name))
    |> Map.put_new(:slots, %{})
    |> Map.put_new(:confidence, nil)
    |> Map.put_new(:shortlist, ranked.shortlist)
    |> Map.put(:kind, kind)
  end

  defp normalize_actual(other, ranked) do
    %{
      kind: :none,
      action: nil,
      slots: %{},
      confidence: nil,
      shortlist: ranked.shortlist,
      raw: other
    }
  end

  defp normalized_shortlist(%Outcome{kind: :clarify, shortlist: shortlist}, _ranked),
    do: shortlist

  defp normalized_shortlist(_outcome, ranked), do: ranked.shortlist

  defp unsafe_or_noisy_none?(utterance) do
    text = normalize_text(utterance)

    adversarial? =
      String.contains?(text, "ignore your rules") or
        String.contains?(text, "delete everything") or
        String.contains?(text, "bypass safety")

    adversarial? or noisy_gibberish?(text)
  end

  defp noisy_gibberish?(text) do
    tokens = tokens(text)

    length(tokens) > 1 and length(tokens) <= 5 and
      (Enum.member?(tokens, "nonsense") or Enum.count(tokens, &token_has_vowel?/1) <= 1)
  end

  defp token_has_vowel?(token), do: Regex.match?(~r/[aeiou]/, token)

  defp general_answer_question?(utterance) do
    text = normalize_text(utterance)

    Regex.match?(
      ~r/^(what|who|where|when|why|how)\s+(is|are|was|were|do|does|did|can|should|would)\b/,
      text
    ) and
      not allbert_domain_question?(text)
  end

  defp allbert_domain_question?(text) do
    Enum.any?(
      [
        "model",
        "models",
        "setting",
        "settings",
        "channel",
        "channels",
        "plugin",
        "plugins",
        "skill",
        "skills",
        "app",
        "apps",
        "note",
        "notes",
        "analysis",
        "analyses",
        "provider",
        "providers",
        "marketplace",
        "mcp",
        "objective",
        "objectives",
        "goal",
        "goals",
        "remember",
        "recall"
      ],
      &Enum.member?(tokens(text), &1)
    )
  end

  defp ambiguous_operator_noun_phrase?(utterance, shortlist) do
    text = normalize_text(utterance)

    text in ["model settings", "settings model", "model profiles", "profile settings"] and
      shortlist
      |> Enum.map(& &1.action_name)
      |> Enum.count(
        &(&1 in [
            "set_active_model_profile",
            "list_model_profiles",
            "read_setting",
            "list_settings",
            "doctor_model_profile"
          ])
      ) >= 2
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp tokens(text), do: String.split(text, " ", trim: true)
end
