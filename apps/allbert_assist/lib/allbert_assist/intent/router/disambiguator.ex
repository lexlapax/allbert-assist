defmodule AllbertAssist.Intent.Router.Disambiguator do
  @moduledoc """
  Stage 2 of the two-stage intent router (ADR 0060): given the Stage 1 shortlist,
  ask the configured `intent.router_model_profile` to select exactly one
  shortlisted action **or** one of the sentinels `__clarify__` / `__answer__` /
  `__none__`, with extracted slots and a confidence. A **confidence gate** then
  maps the selection to a `Router.Outcome`:

    * a real shortlisted action with confidence ≥ `intent.router_min_confidence`
      → `:execute`. A tight Stage-1 margin (< `intent.disambiguation_margin`)
      does **not** veto a *decisive* selection (confidence ≥ `@decisive_confidence`):
      Stage 2 is the selection authority (ADR 0060) and the embedding margin is a
      noisy, length-sensitive signal, so a confident Stage-2 pick wins.
    * a tight margin with only borderline confidence, plain low confidence, or a
      selection outside the shortlist → `:clarify` (a targeted question scoped to
      the shortlist), which may escalate to a higher-tier model
    * `__answer__` / `__none__` → `:answer` / `:none`
    * model unavailable / timeout → `:defer` (the router uses the deterministic
      ladder)

  The selection model boundary is swappable via
  `Application.put_env(:allbert_assist, :intent_router_disambiguator, impl)`
  (tests use `Disambiguator.FakeDisambiguator`). The gate is pure (`decide/4`).
  """
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Slots
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  require Logger

  @answer "__answer__"
  @none "__none__"
  @clarify "__clarify__"
  @escalatable_notes [:low_confidence, :ambiguous_margin, :selection_not_in_shortlist]
  # A Stage-2 selection at/above this confidence overrides a tight Stage-1 margin
  # (the embedding margin is noisy and length-sensitive; Stage 2 is the authority).
  @decisive_confidence 0.8

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
      {:ok, selection} ->
        decision_opts = Keyword.put(opts, :query, query)
        outcome = decide(selection, shortlist, margin, decision_opts)
        {:ok, maybe_escalate(outcome, query, shortlist, margin, context, opts)}

      {:error, reason} ->
        {:ok, Outcome.defer(:disambiguator_unavailable, %{reason: inspect(reason)})}
    end
  end

  # ── escalation to a higher-tier profile (ADR 0061) ───────────────────────────
  # Default `intent.router_escalation_profile` is a local higher-tier model
  # (`router_escalation_local`, gemma4:26b). A low-confidence / ambiguous /
  # out-of-shortlist selection by the primary router model escalates once to the
  # escalation profile (which may also be hosted). Always audited.

  defp maybe_escalate(
         %Outcome{kind: :clarify, diagnostics: %{note: note}} = outcome,
         query,
         shortlist,
         margin,
         context,
         opts
       )
       when note in @escalatable_notes do
    cond do
      Keyword.get(opts, :escalated) ->
        outcome

      profile = escalation_profile(opts) ->
        audit_escalation(query, profile, context, note)
        escalate(query, shortlist, margin, context, opts, profile, outcome)

      true ->
        outcome
    end
  end

  defp maybe_escalate(outcome, _query, _shortlist, _margin, _context, _opts), do: outcome

  defp escalate(query, shortlist, margin, context, opts, profile, fallback) do
    esc_opts = opts |> Keyword.put(:model_profile, profile) |> Keyword.put(:escalated, true)

    case impl().select(query, shortlist, context, esc_opts) do
      {:ok, selection} -> decide(selection, shortlist, margin, esc_opts)
      {:error, _reason} -> fallback
    end
  end

  defp escalation_profile(opts) do
    case Keyword.get(opts, :escalation_profile) ||
           setting_string("intent.router_escalation_profile") do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp audit_escalation(query, profile, context, note) do
    Logger.warning(
      "[intent_router_escalation] low-confidence (#{note}) routed to profile=#{profile} " <>
        "thread=#{inspect(Map.get(context, :thread_id) || Map.get(context, "thread_id"))} " <>
        "text=#{query |> to_string() |> Redactor.redact() |> String.slice(0, 120)}"
    )
  end

  defp setting_string(key) do
    case Settings.get(key) do
      {:ok, value} when is_binary(value) -> value
      _other -> nil
    end
  end

  @doc "Pure confidence gate mapping a selection to an Outcome."
  @spec decide(map(), [map()], float(), keyword()) :: Outcome.t()
  def decide(selection, shortlist, margin, opts) do
    selected = selection |> Map.get(:selected) |> to_string()
    confidence = normalize_confidence(Map.get(selection, :confidence))
    min_conf = min_confidence(opts)
    diag = base_diag(selection, confidence, margin)
    query = Keyword.get(opts, :query)
    selected_item = shortlist_item(selected, shortlist)
    slots = merged_slots(selection, selected_item)
    missing_slots = missing_required_slots(selected_item, slots)

    case selection_outcome(
           selected,
           selected_item,
           query,
           shortlist,
           confidence,
           min_conf,
           margin,
           opts
         ) do
      :answer ->
        Outcome.answer(diag)

      :none ->
        Outcome.none(diag)

      {:clarify, note} ->
        clarify(shortlist, Map.put(diag, :note, note))

      :execute ->
        execute_or_clarify_missing_slots(
          selected,
          slots,
          confidence,
          diag,
          shortlist,
          missing_slots
        )
    end
  end

  defp selection_outcome(
         selected,
         selected_item,
         query,
         shortlist,
         confidence,
         min_conf,
         margin,
         opts
       ) do
    sentinel_outcome(selected) ||
      routed_selection_outcome(
        selected_item,
        query,
        shortlist,
        confidence,
        min_conf,
        margin,
        opts
      )
  end

  defp sentinel_outcome(@answer), do: :answer
  defp sentinel_outcome(@none), do: :none
  defp sentinel_outcome(@clarify), do: {:clarify, :model_requested_clarify}
  defp sentinel_outcome(_selected), do: nil

  defp routed_selection_outcome(
         selected_item,
         query,
         shortlist,
         confidence,
         min_conf,
         margin,
         opts
       ) do
    cond do
      is_nil(selected_item) ->
        {:clarify, :selection_not_in_shortlist}

      low_information_query?(query, shortlist) ->
        {:clarify, :low_information_query}

      confidence < min_conf ->
        {:clarify, :low_confidence}

      ambiguous?(margin, shortlist, opts) and confidence < @decisive_confidence ->
        {:clarify, :ambiguous_margin}

      true ->
        :execute
    end
  end

  defp execute_or_clarify_missing_slots(selected, slots, confidence, diag, _shortlist, []) do
    Outcome.execute(selected, slots, confidence, diag)
  end

  defp execute_or_clarify_missing_slots(
         _selected,
         _slots,
         _confidence,
         diag,
         shortlist,
         missing_slots
       ) do
    clarify(
      shortlist,
      diag
      |> Map.put(:note, :missing_required_slots)
      |> Map.put(:missing_slots, missing_slots)
    )
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

  defp shortlist_item(selected, shortlist),
    do: Enum.find(shortlist, &(to_string(Map.get(&1, :action_name)) == selected))

  defp merged_slots(selection, shortlist_item) do
    %{}
    |> Slots.merge(Map.get(shortlist_item || %{}, :extracted_slots, %{}),
      key_mode: :lenient,
      overwrite: true
    )
    |> Slots.merge(Map.get(selection, :slots, %{}), key_mode: :lenient, overwrite: true)
  end

  defp missing_required_slots(nil, _slots), do: []

  defp missing_required_slots(shortlist_item, slots) do
    shortlist_item
    |> Map.get(:required_slots, [])
    |> Enum.reject(&present_slot?(slots, &1))
  end

  defp present_slot?(slots, slot) do
    Enum.any?([slot, to_string(slot)], fn key ->
      case Map.get(slots, key) do
        value when is_binary(value) -> String.trim(value) != ""
        nil -> false
        _value -> true
      end
    end)
  end

  defp ambiguous?(margin, shortlist, opts) do
    length(shortlist) >= 2 and margin < disambiguation_margin(opts)
  end

  defp low_information_query?(query, shortlist) when is_binary(query) do
    tokens =
      query
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/u, trim: true)

    length(tokens) == 1 and length(shortlist) >= 2
  end

  defp low_information_query?(_query, _shortlist), do: false

  defp base_diag(selection, confidence, margin) do
    %{confidence: confidence, margin: margin, reason: Map.get(selection, :reason)}
  end

  defp normalize_confidence(value) when is_number(value),
    do: (value * 1.0) |> max(0.0) |> min(1.0)

  defp normalize_confidence(_value), do: 0.0

  defp min_confidence(opts),
    do: Keyword.get(opts, :min_confidence) || setting_float("intent.router_min_confidence", 0.6)

  defp disambiguation_margin(opts),
    do:
      Keyword.get(opts, :disambiguation_margin) ||
        setting_float("intent.disambiguation_margin", 0.12)

  defp setting_float(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_number(value) -> value
      _other -> default
    end
  end

  defp impl, do: Application.get_env(:allbert_assist, :intent_router_disambiguator, @default_impl)
end
