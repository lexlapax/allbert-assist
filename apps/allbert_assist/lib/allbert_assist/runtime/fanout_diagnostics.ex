defmodule AllbertAssist.Runtime.FanoutDiagnostics do
  @moduledoc """
  Content-free observability facts for manager planning and fan-out admission.

  These facts are safe to place in conversation action-log diagnostics. They
  deliberately exclude operator/model text, child plans, provider payloads,
  and raw errors.
  """

  @manager_results [:answer, :fanout, :clarify]
  @manager_fields [:outcome, :policy_outcome, :join_role]
  @admission_outcomes [:admitted, :rejected, :single_turn_fallback, :shadow_only]
  @admission_reasons [
    :fanout_already_active,
    :fanout_budget_exhausted,
    :fanout_budget_unavailable,
    :fanout_frame_failed,
    :fanout_plan_deadline_exhausted,
    :plan_request_binding_mismatch,
    :plan_revalidation_failed
  ]

  @doc "Build a bounded fact for a successful manager result."
  @spec manager(:answer | :fanout | :clarify, map()) :: map()
  def manager(result, diagnostic) when result in @manager_results and is_map(diagnostic) do
    %{source: :fanout_manager, result: result, outcome: default_manager_outcome(result)}
    |> copy_atom_fields(diagnostic, @manager_fields)
    |> copy_bounded_integer(diagnostic, :attempts, 0, 2)
    |> copy_bounded_integer(diagnostic, :work_unit_count, 0, 64)
    |> copy_boolean(diagnostic, :reviewed?, :reviewed)
  end

  @doc "Build the intentionally reason-free fact for a failed manager call."
  @spec manager_error() :: map()
  def manager_error do
    %{source: :fanout_manager, result: :error, outcome: :manager_unavailable}
  end

  @doc "Build a bounded fact for the Runtime admission decision."
  @spec admission(:admitted | :rejected | :single_turn_fallback | :shadow_only, atom() | nil) ::
          map()
  def admission(outcome, reason \\ nil) when outcome in @admission_outcomes do
    %{source: :fanout_admission, outcome: outcome}
    |> maybe_put_admission_reason(reason)
  end

  @doc "Return the first already-sanitized manager fact on a response."
  @spec manager_fact(map() | nil) :: map() | nil
  def manager_fact(%{diagnostics: diagnostics}) when is_list(diagnostics) do
    Enum.find_value(diagnostics, fn diagnostic ->
      case sanitize_fact(diagnostic) do
        %{source: :fanout_manager} = fact -> fact
        _other -> nil
      end
    end)
  end

  def manager_fact(_response), do: nil

  @doc "Rebuild fan-out facts from their allow-listed fields and retain unrelated diagnostics."
  @spec sanitize(list()) :: list()
  def sanitize(diagnostics) when is_list(diagnostics) do
    Enum.flat_map(diagnostics, fn diagnostic ->
      case sanitize_fact(diagnostic) do
        :drop -> []
        fact -> [fact]
      end
    end)
  end

  defp sanitize_fact(diagnostic) when is_map(diagnostic) do
    case normalize_closed(value(diagnostic, :source), [:fanout_manager, :fanout_admission]) do
      :fanout_manager -> sanitize_manager_fact(diagnostic)
      :fanout_admission -> sanitize_admission_fact(diagnostic)
      nil -> diagnostic
    end
  end

  defp sanitize_fact(diagnostic), do: diagnostic

  defp sanitize_manager_fact(diagnostic) do
    case normalize_closed(value(diagnostic, :result), @manager_results ++ [:error]) do
      :error -> manager_error()
      result when result in @manager_results -> manager(result, diagnostic)
      nil -> :drop
    end
  end

  defp sanitize_admission_fact(diagnostic) do
    case normalize_closed(value(diagnostic, :outcome), @admission_outcomes) do
      outcome when outcome in @admission_outcomes ->
        reason = normalize_closed(value(diagnostic, :reason), @admission_reasons)
        admission(outcome, reason)

      nil ->
        :drop
    end
  end

  defp default_manager_outcome(:answer), do: :answered
  defp default_manager_outcome(:fanout), do: :planned
  defp default_manager_outcome(:clarify), do: :overflow

  defp copy_atom_fields(target, source, keys) do
    Enum.reduce(keys, target, fn key, acc ->
      case value(source, key) do
        value when is_atom(value) and not is_nil(value) -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp copy_bounded_integer(target, source, key, minimum, maximum) do
    case value(source, key) do
      value when is_integer(value) and value >= minimum and value <= maximum ->
        Map.put(target, key, value)

      _other ->
        target
    end
  end

  defp copy_boolean(target, source, source_key, target_key) do
    case value(source, source_key) do
      value when is_boolean(value) -> Map.put(target, target_key, value)
      _other -> target
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp normalize_closed(value, allowed) when is_atom(value) do
    if value in allowed, do: value
  end

  defp normalize_closed(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp normalize_closed(_value, _allowed), do: nil

  defp maybe_put_admission_reason(fact, reason) when reason in @admission_reasons,
    do: Map.put(fact, :reason, reason)

  defp maybe_put_admission_reason(fact, _reason), do: fact
end
