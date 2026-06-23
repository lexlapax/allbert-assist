defmodule AllbertAssist.Intent.Eval.Scorer do
  @moduledoc """
  Computes the redacted eval-result DTO used by the v0.56 routing gate.
  """

  @spec score(map(), map() | nil) :: map()
  def score(run, baseline \\ nil) do
    results = Map.get(run, :results, Map.get(run, "results", []))
    scored = Enum.map(results, &score_result/1)
    total = length(scored)
    passed = Enum.count(scored, & &1.pass?)

    score = %{
      total: total,
      passed: passed,
      overall_accuracy: ratio(passed, total),
      per_domain: grouped_accuracy(scored, & &1.case.domain),
      per_surface: grouped_accuracy(scored, &to_string(&1.case.surface)),
      confusion: confusion(scored),
      slot_accuracy: slot_accuracy(scored),
      clarify_vs_execute: clarify_vs_execute(scored),
      negative_violations: negative_violations(scored)
    }

    Map.put(score, :gate, gate_summary(score, baseline))
  end

  defp score_result(%{case: case, actual: actual} = result) do
    Map.merge(result, %{
      pass?: pass?(case, actual),
      expected_label: expected_label(case),
      actual_label: actual_label(actual)
    })
  end

  defp pass?(%{negative?: true} = case, actual), do: not negative_violation?(case, actual)

  defp pass?(%{expected: %{kind: :execute, action: action, slots: slots}}, actual) do
    actual_kind(actual) == :execute and actual_action(actual) == action and
      slots_match?(slots, actual_slots(actual))
  end

  defp pass?(%{expected: %{kind: kind}}, actual), do: actual_kind(actual) == kind

  defp slots_match?(expected, _actual) when expected in [%{}, nil], do: true

  defp slots_match?(expected, actual) when is_map(expected) do
    Enum.all?(expected, fn {slot, value} ->
      actual_value = slot_value(actual, slot)

      case value do
        :present -> present?(actual_value)
        _other -> actual_value == value
      end
    end)
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp grouped_accuracy(scored, key_fun) do
    scored
    |> Enum.group_by(key_fun)
    |> Map.new(fn {key, group} ->
      total = length(group)
      passed = Enum.count(group, & &1.pass?)
      {key, %{total: total, passed: passed, accuracy: ratio(passed, total)}}
    end)
  end

  defp confusion(scored) do
    scored
    |> Enum.group_by(&{&1.expected_label, &1.actual_label})
    |> Enum.map(fn {{expected, actual}, group} ->
      %{expected: expected, actual: actual, count: length(group)}
    end)
    |> Enum.sort_by(&{&1.expected, &1.actual})
  end

  defp slot_accuracy(scored) do
    slot_checks = Enum.flat_map(scored, &slot_checks/1)

    total = length(slot_checks)
    passed = Enum.count(slot_checks, & &1)
    %{total: total, passed: passed, accuracy: ratio(passed, total)}
  end

  defp slot_checks(%{case: case, actual: actual}) do
    case Map.get(case.expected, :slots, %{}) do
      slots when slots in [%{}, nil] ->
        []

      slots ->
        Enum.map(slots, fn {slot, value} ->
          actual_value = slot_value(actual_slots(actual), slot)
          (value == :present && present?(actual_value)) || actual_value == value
        end)
    end
  end

  defp clarify_vs_execute(scored) do
    cases = Enum.filter(scored, &(&1.case.expected.kind in [:clarify, :execute]))
    total = length(cases)
    passed = Enum.count(cases, & &1.pass?)
    %{total: total, passed: passed, accuracy: ratio(passed, total)}
  end

  defp negative_violations(scored) do
    scored
    |> Enum.filter(&negative_violation?(&1.case, &1.actual))
    |> Enum.map(fn %{case: case, actual: actual} ->
      %{
        id: case.id,
        expected_action: Map.get(case.expected, :action),
        actual_action: actual_action(actual)
      }
    end)
  end

  defp negative_violation?(%{negative?: true, expected: expected}, actual) do
    actual_kind(actual) == :execute and
      (is_nil(Map.get(expected, :action)) or actual_action(actual) == Map.get(expected, :action))
  end

  defp negative_violation?(_case, _actual), do: false

  defp gate_summary(score, baseline) do
    %{
      pass?: score.negative_violations == [],
      regressions: regressions(score, baseline),
      floor: nil,
      baseline: baseline_id(baseline)
    }
  end

  defp regressions(_score, nil), do: []

  defp regressions(score, baseline) do
    []
    |> maybe_regression(
      :overall_accuracy,
      score.overall_accuracy,
      metric(baseline, :overall_accuracy)
    )
    |> maybe_regression(
      :slot_accuracy,
      metric(score.slot_accuracy, :accuracy),
      nested_metric(baseline, :slot_accuracy, :accuracy)
    )
    |> maybe_regression(
      :clarify_vs_execute_accuracy,
      metric(score.clarify_vs_execute, :accuracy),
      nested_metric(baseline, :clarify_vs_execute, :accuracy)
    )
    |> Kernel.++(domain_regressions(score.per_domain, metric(baseline, :per_domain) || %{}))
  end

  defp maybe_regression(acc, _name, _current, nil), do: acc

  defp maybe_regression(acc, name, current, previous) when current < previous,
    do: [%{metric: name, previous: previous, current: current} | acc]

  defp maybe_regression(acc, _name, _current, _previous), do: acc

  defp domain_regressions(current, previous) do
    Enum.flat_map(previous, fn {domain, baseline_stats} ->
      current_accuracy =
        get_in(current, [domain, :accuracy]) || get_in(current, [domain, "accuracy"])

      baseline_accuracy = metric(baseline_stats, :accuracy)

      if is_number(current_accuracy) and is_number(baseline_accuracy) and
           current_accuracy < baseline_accuracy do
        [
          %{
            metric: :per_domain_accuracy,
            domain: domain,
            previous: baseline_accuracy,
            current: current_accuracy
          }
        ]
      else
        []
      end
    end)
  end

  defp baseline_id(nil), do: nil
  defp baseline_id(baseline), do: metric(baseline, :id) || metric(baseline, :baseline)

  defp nested_metric(map, key, nested_key), do: map |> metric(key) |> metric(nested_key)

  defp metric(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp metric(_map, _key), do: nil

  defp expected_label(%{expected: %{kind: :execute, action: action}}), do: "execute:#{action}"
  defp expected_label(%{expected: %{kind: kind}}), do: to_string(kind)

  defp actual_label(actual) do
    case {actual_kind(actual), actual_action(actual)} do
      {:execute, action} when is_binary(action) -> "execute:#{action}"
      {kind, _action} -> to_string(kind)
    end
  end

  defp actual_kind(actual), do: Map.get(actual, :kind, Map.get(actual, "kind"))

  defp actual_action(actual),
    do: Map.get(actual, :action, Map.get(actual, :action_name, Map.get(actual, "action")))

  defp actual_slots(actual), do: Map.get(actual, :slots, Map.get(actual, "slots", %{})) || %{}

  defp slot_value(slots, slot) when is_map(slots) do
    expected = to_string(slot)

    Enum.find_value(slots, fn {key, value} ->
      if to_string(key) == expected, do: value
    end)
  end

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, d), do: Float.round(n / d, 4)
end
