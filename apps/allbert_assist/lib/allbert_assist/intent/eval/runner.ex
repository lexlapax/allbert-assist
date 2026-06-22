defmodule AllbertAssist.Intent.Eval.Runner do
  @moduledoc """
  Deterministic replay runner for the committed intent eval corpus.

  M1 deliberately exercises the real Stage-1 ranking math with a frozen fake
  embedder seam. Later milestones can layer action-backed CLI/TUI surfaces and
  live-provider lanes on top of this stable core.
  """

  alias AllbertAssist.Intent.Eval.Corpus
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.Disambiguator
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.Prefilter

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
        actual = route_case(case, ranked, opts)

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
        DescriptorResolver.resolve() |> entries_from_descriptors(embedder)
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
      Prefilter.rank(query_vector, entries, top_k)
    else
      _error -> %{shortlist: [], margin: 0.0}
    end
  end

  defp route_case(case, ranked, opts) do
    case Keyword.get(opts, :selector) do
      selector when is_function(selector, 2) ->
        selector.(case, ranked.shortlist) |> normalize_actual(ranked)

      _other ->
        opts
        |> Keyword.get(:disambiguator, :top_ranked_fake)
        |> select(case, ranked, opts)
        |> outcome(case, ranked, opts)
    end
  end

  defp select(
         :top_ranked_fake,
         _case,
         %{shortlist: [%{action_name: action} = top | _rest]},
         _opts
       ) do
    {:ok,
     %{
       selected: action,
       confidence: 1.0,
       slots: Map.get(top, :extracted_slots, %{})
     }}
  end

  defp select(:top_ranked_fake, _case, %{shortlist: []}, _opts) do
    {:ok, %{selected: "__none__", confidence: 1.0, slots: %{}}}
  end

  defp select(module, case, ranked, opts) when is_atom(module) do
    module.select(case.utterance, ranked.shortlist, case.context, opts)
  end

  defp outcome({:ok, selection}, case, ranked, opts) do
    decision_opts =
      opts
      |> Keyword.put_new(:query, case.utterance)
      |> Keyword.put_new(:min_confidence, 0.0)

    selection
    |> Disambiguator.decide(ranked.shortlist, ranked.margin, decision_opts)
    |> normalize_actual(ranked)
  end

  defp outcome({:error, reason}, _case, ranked, _opts) do
    normalize_actual(
      %{kind: :defer, action: nil, slots: %{}, confidence: nil, reason: reason},
      ranked
    )
  end

  defp normalize_actual(%Outcome{} = outcome, ranked) do
    %{
      kind: outcome.kind,
      action: outcome.action_name,
      slots: outcome.slots || %{},
      confidence: outcome.confidence,
      shortlist: ranked.shortlist,
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
end
