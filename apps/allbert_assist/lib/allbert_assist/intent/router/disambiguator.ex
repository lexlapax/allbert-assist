defmodule AllbertAssist.Intent.Router.Disambiguator do
  @moduledoc """
  Stage 2 of the two-stage intent router (ADR 0060): given the Stage 1 shortlist,
  ask the configured `intent.router_model_profile` to select exactly one
  shortlisted action **or** one of the sentinels `__clarify__` / `__answer__` /
  `__none__`, with extracted slots and a confidence. A **confidence gate** then
  maps the selection to a `Router.Outcome`:

    * a real shortlisted action with confidence ≥ `intent.router_min_confidence`
      and a non-ambiguous margin → `:execute`
    * low confidence, ambiguous margin, or a selection outside the shortlist →
      `:clarify` (a targeted question scoped to the shortlist)
    * `__answer__` / `__none__` → `:answer` / `:none`
    * model unavailable / timeout → `:defer` (the router uses the deterministic
      ladder)

  The selection model boundary is swappable via
  `Application.put_env(:allbert_assist, :intent_router_disambiguator, impl)`
  (tests use `Disambiguator.FakeDisambiguator`). The gate is pure (`decide/4`).
  """
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Settings

  @answer "__answer__"
  @none "__none__"
  @clarify "__clarify__"

  defmodule Behaviour do
    @moduledoc "Behaviour for the Stage 2 selection model boundary (ADR 0060)."
    @callback select(
                query :: String.t(),
                shortlist :: [map()],
                context :: map(),
                opts :: keyword()
              ) ::
                {:ok,
                 %{
                   required(:selected) => String.t(),
                   optional(:reason) => String.t() | nil,
                   optional(:confidence) => float(),
                   optional(:slots) => map()
                 }}
                | {:error, term()}
  end

  @default_impl AllbertAssist.Intent.Router.Disambiguator.ReqLLMDisambiguator

  @spec disambiguate(String.t(), [map()], float(), map(), keyword()) :: {:ok, Outcome.t()}
  def disambiguate(query, shortlist, margin, context, opts \\ []) do
    case impl().select(query, shortlist, context, opts) do
      {:ok, selection} -> {:ok, decide(selection, shortlist, margin, opts)}
      {:error, reason} -> {:ok, Outcome.defer(:disambiguator_unavailable, %{reason: inspect(reason)})}
    end
  end

  @doc "Pure confidence gate mapping a selection to an Outcome."
  @spec decide(map(), [map()], float(), keyword()) :: Outcome.t()
  def decide(selection, shortlist, margin, opts) do
    selected = selection |> Map.get(:selected) |> to_string()
    confidence = normalize_confidence(Map.get(selection, :confidence))
    min_conf = min_confidence(opts)
    diag = base_diag(selection, confidence, margin)

    cond do
      selected == @answer -> Outcome.answer(diag)
      selected == @none -> Outcome.none(diag)
      selected == @clarify -> clarify(shortlist, Map.put(diag, :note, :model_requested_clarify))
      not in_shortlist?(selected, shortlist) -> clarify(shortlist, Map.put(diag, :note, :selection_not_in_shortlist))
      confidence < min_conf -> clarify(shortlist, Map.put(diag, :note, :low_confidence))
      ambiguous?(margin, shortlist, opts) -> clarify(shortlist, Map.put(diag, :note, :ambiguous_margin))
      true -> Outcome.execute(selected, Map.get(selection, :slots, %{}), confidence, diag)
    end
  end

  # ── gate helpers ─────────────────────────────────────────────────────────────

  defp clarify(shortlist, diag), do: Outcome.clarify(shortlist, clarify_question(shortlist), diag)

  @doc "Build a targeted either/or question from the top shortlist labels."
  @spec clarify_question([map()]) :: String.t()
  def clarify_question(shortlist) do
    labels = shortlist |> Enum.take(3) |> Enum.map(&Map.get(&1, :label)) |> Enum.reject(&is_nil/1)

    case labels do
      [] -> "Could you say a bit more about what you'd like to do?"
      [one] -> "Did you want to: #{one}?"
      many -> "Did you want to: #{Enum.join(many, ", or ")}?"
    end
  end

  defp in_shortlist?(selected, shortlist),
    do: Enum.any?(shortlist, &(to_string(Map.get(&1, :action_name)) == selected))

  defp ambiguous?(margin, shortlist, opts) do
    length(shortlist) >= 2 and margin < disambiguation_margin(opts)
  end

  defp base_diag(selection, confidence, margin) do
    %{confidence: confidence, margin: margin, reason: Map.get(selection, :reason)}
  end

  defp normalize_confidence(value) when is_number(value), do: value * 1.0 |> max(0.0) |> min(1.0)
  defp normalize_confidence(_value), do: 0.0

  defp min_confidence(opts),
    do: Keyword.get(opts, :min_confidence) || setting_float("intent.router_min_confidence", 0.6)

  defp disambiguation_margin(opts),
    do: Keyword.get(opts, :disambiguation_margin) || setting_float("intent.disambiguation_margin", 0.12)

  defp setting_float(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_number(value) -> value
      _other -> default
    end
  end

  defp impl, do: Application.get_env(:allbert_assist, :intent_router_disambiguator, @default_impl)
end
