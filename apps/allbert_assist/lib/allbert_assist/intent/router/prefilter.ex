defmodule AllbertAssist.Intent.Router.Prefilter do
  @moduledoc """
  Stage 1 of the two-stage intent router (ADR 0060): narrow the action surface to
  a small shortlist by embedding the utterance and ranking the in-memory
  utterance index by cosine similarity. Returns the top-K (`intent.router_top_k`)
  plus a similarity **margin** (top1 − top2) for the confidence gate.

  Local-only via `Intent.Router.Embedder`. When embeddings or the index are
  unavailable it returns `{:fallback, reason}` so the router defers to the
  deterministic ladder. The index is built lazily on first use (it is not built
  at boot, so a default `:deterministic` install never embeds).
  """
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Router.Embedder
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Settings

  @complete_required_slots_boost 0.35
  @missing_required_slots_penalty 0.25
  @descriptor_text_match_boost 0.35
  @descriptor_text_match_token_boost 0.04
  @descriptor_text_match_cap 0.25

  @type ranked :: %{
          action_name: String.t(),
          app_id: term(),
          label: String.t(),
          score: float()
        }

  @spec shortlist(String.t(), keyword()) ::
          {:ok, %{shortlist: [ranked()], margin: float(), query_vector: [float()]}}
          | {:fallback, term()}
  def shortlist(query, opts \\ []) when is_binary(query) do
    with {:ok, entries} <- ensure_index(),
         {:ok, [query_vector | _]} <- Embedder.embed([query], opts) do
      ranked = rank(query_vector, entries, top_k(opts), query)
      {:ok, Map.put(ranked, :query_vector, query_vector)}
    else
      {:fallback, _reason} = fallback -> fallback
      {:ok, _unexpected} -> {:fallback, :embed_failed}
      {:error, reason} -> {:fallback, reason}
    end
  end

  @doc "Pure cosine ranking of `entries` against `query_vector`; top-`k` + margin."
  @spec rank([float()], [map()], pos_integer()) :: %{shortlist: [ranked()], margin: float()}
  @spec rank([float()], [map()], pos_integer(), String.t()) :: %{
          shortlist: [ranked()],
          margin: float()
        }
  def rank(query_vector, entries, k) when is_list(entries) and is_integer(k) and k > 0 do
    rank(query_vector, entries, k, "")
  end

  def rank(query_vector, entries, k, query)
      when is_list(entries) and is_integer(k) and k > 0 and is_binary(query) do
    ranked =
      entries
      |> Enum.map(fn entry ->
        slots = extracted_slots(entry, query)
        required_slots = Map.get(entry, :required_slots, [])

        base_score =
          Embedder.cosine(query_vector, entry.vector) + descriptor_text_boost(entry, query)

        %{
          action_name: entry.action_name,
          app_id: entry.app_id,
          label: entry.label,
          required_slots: required_slots,
          optional_slots: Map.get(entry, :optional_slots, []),
          extracted_slots: slots.extracted_slots,
          missing_slots: slots.missing_slots,
          score: slot_adjusted_score(base_score, required_slots, slots)
        }
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(k)

    %{shortlist: ranked, margin: margin(ranked)}
  end

  defp margin([%{score: s1}, %{score: s2} | _rest]), do: s1 - s2
  defp margin([%{score: s1}]), do: s1
  defp margin([]), do: 0.0

  defp extracted_slots(%{descriptor: %Descriptor{} = descriptor}, query) do
    Descriptor.extract_slots(descriptor, query)
  end

  defp extracted_slots(_entry, _query), do: %{extracted_slots: %{}, missing_slots: []}

  defp descriptor_text_boost(%{descriptor: %Descriptor{} = descriptor} = entry, query) do
    descriptor_text_match_score(entry, descriptor, query)
    |> case do
      score when score > 0 ->
        @descriptor_text_match_boost +
          min(score * @descriptor_text_match_token_boost, @descriptor_text_match_cap)

      _score ->
        0.0
    end
  end

  defp descriptor_text_boost(_entry, _query), do: 0.0

  defp descriptor_text_match_score(entry, descriptor, query) do
    vocabulary = Map.get(descriptor, :vocabulary, %{}) || %{}
    allow_single? = field(vocabulary, :allow_single_token_match, true) != false

    negative_values = field(vocabulary, :negative_phrases, []) || []

    if Enum.any?(negative_values, &(descriptor_phrase_match_score(query, &1, true) > 0)) do
      0
    else
      descriptor_values(entry, descriptor, vocabulary)
      |> Enum.map(&descriptor_phrase_match_score(query, &1, allow_single?))
      |> Enum.max(fn -> 0 end)
    end
  end

  defp descriptor_values(entry, descriptor, vocabulary) do
    [
      Map.get(entry, :label),
      Map.get(entry, :action_name),
      Map.get(descriptor, :label),
      Map.get(descriptor, :action_name)
    ] ++
      Map.get(descriptor, :examples, []) ++
      Map.get(descriptor, :synonyms, []) ++
      (field(vocabulary, :phrases, []) || [])
  end

  defp descriptor_phrase_match_score(text, value, allow_single?) when is_binary(value) do
    normalized_text = normalize_text(text)
    normalized_value = normalize_text(value)
    text_tokens = String.split(normalized_text, " ", trim: true)
    value_tokens = String.split(normalized_value, " ", trim: true)
    token_count = length(value_tokens)

    cond do
      normalized_value == "" ->
        0

      phrase_token_match?(normalized_text, normalized_value) ->
        token_count

      token_count > 1 and ordered_token_match?(text_tokens, value_tokens) ->
        token_count

      single_token_match?(allow_single?, value_tokens, text_tokens) ->
        1

      true ->
        0
    end
  end

  defp descriptor_phrase_match_score(_text, _value, _allow_single?), do: 0

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp phrase_token_match?(normalized_text, normalized_value) do
    text_tokens = String.split(normalized_text, " ", trim: true)
    value_tokens = String.split(normalized_value, " ", trim: true)

    value_tokens != [] and
      text_tokens
      |> Enum.chunk_every(length(value_tokens), 1, :discard)
      |> Enum.any?(&(&1 == value_tokens))
  end

  defp ordered_token_match?(_text_tokens, []), do: false
  defp ordered_token_match?(text_tokens, tokens), do: do_ordered_token_match?(text_tokens, tokens)

  defp do_ordered_token_match?(_text_tokens, []), do: true

  defp do_ordered_token_match?(text_tokens, [token | rest]) do
    case Enum.drop_while(text_tokens, &(&1 != token)) do
      [_matched | remaining] -> do_ordered_token_match?(remaining, rest)
      [] -> false
    end
  end

  defp single_token_match?(true, [token], text_tokens),
    do: String.length(token) >= 4 and token in text_tokens

  defp single_token_match?(_allow_single?, _value_tokens, _text_tokens), do: false

  defp slot_adjusted_score(score, [], _slots), do: score

  defp slot_adjusted_score(score, required_slots, slots) when is_list(required_slots) do
    cond do
      slots.missing_slots == [] and map_size(slots.extracted_slots) > 0 ->
        score + @complete_required_slots_boost

      slots.missing_slots != [] ->
        max(score - @missing_required_slots_penalty, 0.0)

      true ->
        score
    end
  end

  defp ensure_index do
    case index_state() do
      %{status: :built, entries: entries} -> {:ok, entries}
      %{status: :not_built} -> rebuild_then_entries()
      %{status: status} -> {:fallback, {:index, status}}
    end
  end

  defp rebuild_then_entries do
    case Index.rebuild() do
      %{status: :built, entries: entries} -> {:ok, entries}
      %{status: status} -> {:fallback, {:index, status}}
    end
  catch
    :exit, reason -> {:fallback, {:index_down, reason}}
  end

  defp index_state do
    case Process.whereis(Index) do
      nil -> %{status: :not_started}
      _pid -> Index.state()
    end
  catch
    :exit, _reason -> %{status: :down}
  end

  defp top_k(opts) do
    Keyword.get(opts, :top_k) || setting_int("intent.router_top_k", 5)
  end

  defp setting_int(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_integer(value) -> value
      _other -> default
    end
  end

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
