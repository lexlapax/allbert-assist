defmodule AllbertAssist.Intent.Ranker do
  @moduledoc """
  Deterministic scoring helpers for intent candidates.

  v0.19 keeps scoring conservative and context-only. `active_app` and surface
  text matches can move a candidate up, but they do not grant execution
  authority.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Candidate

  @spec rank([Candidate.t() | map()], map()) :: [Candidate.t() | map()]
  def rank(candidates, context \\ %{}) when is_list(candidates) do
    ranking_context = ranking_context(context)

    candidates
    |> Enum.map(&score_candidate(&1, ranking_context))
    |> Enum.sort_by(&score_for_sort/1, :desc)
  end

  @spec selected([Candidate.t() | map()]) :: Candidate.t() | map() | nil
  def selected(candidates) when is_list(candidates) do
    candidates
    |> rank(%{})
    |> Enum.find(fn candidate ->
      field(candidate, :status) in [:selected, :candidate]
    end)
  end

  @spec score(term()) :: float()
  def score(candidate), do: normalize_score(field(candidate, :score, 0.0))

  @spec exact_text_match?(String.t(), String.t() | nil) :: boolean()
  def exact_text_match?(text, value) when is_binary(text) and is_binary(value) do
    text
    |> String.downcase()
    |> String.contains?(String.downcase(value))
  end

  def exact_text_match?(_text, _value), do: false

  defp score_candidate(candidate, context) do
    candidate
    |> apply_active_app_affinity(context)
    |> apply_surface_text_match(context)
  end

  defp apply_active_app_affinity(candidate, %{active_app: active_app})
       when is_atom(active_app) and active_app not in [nil, :allbert] do
    if field(candidate, :app_id) == active_app do
      boost(candidate, 0.35, :app_affinity, "Active app #{active_app} matched candidate app.")
    else
      candidate
    end
  end

  defp apply_active_app_affinity(candidate, _context), do: candidate

  defp apply_surface_text_match(candidate, %{text: text}) do
    if field(candidate, :kind) == :surface and surface_text_match?(candidate, text) do
      boost(candidate, 0.45, :surface_text_match, "Request text matched a registered surface.")
    else
      candidate
    end
  end

  defp surface_text_match?(candidate, text) when is_binary(text) do
    navigation_request?(text) and
      Enum.any?(
        [
          field(candidate, :label),
          field(candidate, :surface_id),
          field(candidate, :app_id),
          get_in_trace(candidate, :path)
        ],
        &text_match?(text, &1)
      )
  end

  defp surface_text_match?(_candidate, _text), do: false

  defp navigation_request?(text) do
    normalized = String.downcase(text)

    Enum.any?(["open", "show", "go to", "take me to", "navigate"], fn word ->
      String.contains?(normalized, word)
    end)
  end

  defp text_match?(text, value) when is_atom(value), do: text_match?(text, Atom.to_string(value))
  defp text_match?(text, value) when is_binary(value), do: exact_text_match?(text, value)
  defp text_match?(_text, _value), do: false

  defp boost(candidate, amount, kind, reason) do
    candidate
    |> put_field(:score, score(candidate) + amount)
    |> put_trace(:ranking_reason, kind)
    |> put_trace(:ranking_reason_text, reason)
  end

  defp score_for_sort(candidate) do
    selected_boost = if field(candidate, :selected?) == true, do: 1.0, else: 0.0
    status_boost = if field(candidate, :status) == :selected, do: 0.5, else: 0.0
    score(candidate) + selected_boost + status_boost
  end

  defp ranking_context(context) do
    request = request_from_context(context)

    %{
      text: field(request, :text) || field(context, :text),
      active_app: normalize_active_app(field(request, :active_app) || field(context, :active_app))
    }
  end

  defp request_from_context(%{request: request}) when is_map(request), do: request
  defp request_from_context(%{"request" => request}) when is_map(request), do: request
  defp request_from_context(context) when is_map(context), do: context
  defp request_from_context(_context), do: %{}

  defp normalize_active_app(nil), do: :allbert

  defp normalize_active_app(active_app) do
    case AppRegistry.normalize_app_id(active_app) do
      {:ok, nil} -> :allbert
      {:ok, app_id} -> app_id
      {:error, _reason} -> :allbert
    end
  catch
    :exit, _reason -> :allbert
  end

  defp normalize_score(value) when is_integer(value), do: normalize_score(value / 1)
  defp normalize_score(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_score(_value), do: 0.0

  defp field(value, key, default \\ nil)

  defp field(%_struct{} = struct, key, default), do: Map.get(struct, key, default)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_value, _key, default), do: default

  defp put_field(%_struct{} = struct, key, value), do: Map.put(struct, key, value)
  defp put_field(%{} = map, key, value), do: Map.put(map, key, value)

  defp put_trace(candidate, key, value) do
    trace_metadata = field(candidate, :trace_metadata, %{}) || %{}
    put_field(candidate, :trace_metadata, Map.put(trace_metadata, key, value))
  end

  defp get_in_trace(candidate, key) do
    candidate
    |> field(:trace_metadata, %{})
    |> field(key)
  end
end
