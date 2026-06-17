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
  def rank(query_vector, entries, k) when is_list(entries) and is_integer(k) and k > 0 do
    rank(query_vector, entries, k, "")
  end

  defp rank(query_vector, entries, k, query) when is_list(entries) and is_integer(k) and k > 0 do
    ranked =
      entries
      |> Enum.map(fn entry ->
        slots = extracted_slots(entry, query)
        required_slots = Map.get(entry, :required_slots, [])
        base_score = Embedder.cosine(query_vector, entry.vector)

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
end
