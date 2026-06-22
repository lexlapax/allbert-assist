defmodule AllbertAssist.Intent.Eval.Gate do
  @moduledoc """
  Blocking routing-accuracy gate for descriptor promotion and release checks.
  """

  alias AllbertAssist.Intent.Eval.Scorer
  alias AllbertAssist.Settings

  @spec check(map(), map() | nil) :: :ok | {:error, [map()]}
  def check(run_or_score, baseline \\ nil) do
    score = ensure_score(run_or_score, baseline)
    regressions = failures(score, baseline)

    if regressions == [] do
      :ok
    else
      {:error, regressions}
    end
  end

  defp ensure_score(%{overall_accuracy: _} = score, _baseline), do: score
  defp ensure_score(run, baseline), do: Scorer.score(run, baseline)

  defp failures(score, baseline) do
    []
    |> maybe_negative_violations(score)
    |> maybe_accuracy_floor(score)
    |> maybe_domain_floor(score)
    |> maybe_blocked_regressions(score, baseline)
    |> Enum.reverse()
  end

  defp maybe_negative_violations(acc, %{negative_violations: []}), do: acc

  defp maybe_negative_violations(acc, %{negative_violations: violations}) do
    [%{reason: :negative_route_violation, violations: violations} | acc]
  end

  defp maybe_accuracy_floor(acc, score) do
    floor = setting_float("intent.eval.min_accuracy", 0.85)

    if score.overall_accuracy < floor do
      [
        %{
          reason: :accuracy_below_floor,
          metric: :overall_accuracy,
          floor: floor,
          actual: score.overall_accuracy
        }
        | acc
      ]
    else
      acc
    end
  end

  defp maybe_domain_floor(acc, score) do
    floor = setting_float("intent.eval.min_per_domain_accuracy", 0.8)

    score.per_domain
    |> Enum.filter(fn {_domain, stats} -> stats.accuracy < floor end)
    |> Enum.reduce(acc, fn {domain, stats}, acc ->
      [
        %{
          reason: :domain_accuracy_below_floor,
          domain: domain,
          floor: floor,
          actual: stats.accuracy
        }
        | acc
      ]
    end)
  end

  defp maybe_blocked_regressions(acc, score, _baseline) do
    if setting_bool("intent.eval.block_on_regression", true) do
      regressions = get_in(score, [:gate, :regressions]) || []

      Enum.reduce(regressions, acc, fn regression, acc ->
        [Map.put(regression, :reason, :regression) | acc]
      end)
    else
      acc
    end
  end

  defp setting_float(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_number(value) -> value
      _other -> default
    end
  end

  defp setting_bool(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_boolean(value) -> value
      _other -> default
    end
  end
end
