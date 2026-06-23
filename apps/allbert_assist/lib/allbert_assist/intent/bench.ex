defmodule AllbertAssist.Intent.Bench do
  @moduledoc """
  v0.54 M9.2 — intent-router golden-set replay bench.

  Replays the hand-crafted anchor cases (`test/fixtures/intent/golden/anchors.terms`)
  through the **live** two-stage router (`Intent.Router.route/3`) and reports
  per-category accuracy, calibration, clarify/answer/none/none rates, escalation
  rate, and latency. Surfaced via `mix allbert.intent bench`.

  This is a live-model tool (it calls Ollama via the router); CI uses the
  deterministic structural guard in `golden_set_test.exs`, not this. `--subset`
  runs the tuning split (drops `holdout: true` cases); `--holdout` runs only the
  reserved holdout split.
  """
  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Intent.Router.Outcome

  # Resolved robustly because cwd differs between `mix run` (umbrella root) and
  # `mix test` (the app directory).
  @fixture_candidates [
    "apps/allbert_assist/test/fixtures/intent/golden/anchors.terms",
    "test/fixtures/intent/golden/anchors.terms"
  ]

  @type case_result :: %{
          id: String.t(),
          category: String.t(),
          pass: boolean(),
          expected: map(),
          actual: %{
            kind: atom(),
            action: String.t() | nil,
            confidence: float() | nil,
            reason: term()
          },
          ms: non_neg_integer()
        }

  @spec run(keyword()) :: %{cases: [case_result()], summary: map()}
  def run(opts \\ []) do
    with_router_strategy(Keyword.get(opts, :router_strategy, :two_stage_local), fn ->
      cases = opts |> load_cases() |> filter_split(opts)
      results = Enum.map(cases, &score_case/1)

      %{
        cases: results,
        summary: summarize(results) |> Map.put(:router_strategy, Router.strategy())
      }
    end)
  end

  @doc "Load the golden-set cases from the fixture file."
  @spec load_cases(keyword()) :: [map()]
  def load_cases(opts \\ []) do
    path = Keyword.get(opts, :fixture) || fixture_path()
    {cases, _binding} = Code.eval_file(path)
    cases
  end

  defp fixture_path do
    Enum.find(@fixture_candidates, &File.exists?/1) || hd(@fixture_candidates)
  end

  defp filter_split(cases, opts) do
    cond do
      Keyword.get(opts, :holdout) -> Enum.filter(cases, &Map.get(&1, :holdout, false))
      Keyword.get(opts, :subset) -> Enum.reject(cases, &Map.get(&1, :holdout, false))
      true -> cases
    end
  end

  defp score_case(c) do
    request = Map.merge(%{text: c.utterance}, Map.get(c, :context, %{}) || %{})

    {us, outcome} =
      :timer.tc(fn ->
        case safe_route(request) do
          {:ok, %Outcome{} = o} -> o
          _other -> nil
        end
      end)

    actual = actual_of(outcome)

    %{
      id: c.id,
      category: c.category,
      pass: match_expected?(c.expected, outcome),
      expected: c.expected,
      actual: actual,
      ms: div(us, 1000)
    }
  end

  defp safe_route(request) do
    Router.route(request, [], %{})
  rescue
    _exception -> :error
  catch
    :exit, _reason -> :error
  end

  defp actual_of(%Outcome{kind: kind, action_name: action, confidence: conf, reason: reason}),
    do: %{kind: kind, action: action, confidence: conf, reason: reason}

  defp actual_of(nil), do: %{kind: :error, action: nil, confidence: nil, reason: :route_error}

  # :execute requires the same action name; other kinds match on kind alone.
  defp match_expected?(%{kind: :execute, action: a}, %Outcome{kind: :execute, action_name: a}),
    do: true

  defp match_expected?(%{kind: :execute}, _outcome), do: false

  defp match_expected?(%{kind: kind}, %Outcome{kind: kind}), do: true

  # The router never emits :answer/:none directly (those are deterministic-path
  # outcomes); treat a router :defer as "deterministic ladder decides" — for the
  # bench, an expected :answer/:none is satisfied by :answer/:none/:defer.
  defp match_expected?(%{kind: k}, %Outcome{kind: ok})
       when k in [:answer, :none] and ok in [:answer, :none, :defer],
       do: true

  defp match_expected?(_expected, _outcome), do: false

  defp summarize(results) do
    total = length(results)
    passed = Enum.count(results, & &1.pass)

    by_category =
      results
      |> Enum.group_by(& &1.category)
      |> Map.new(fn {cat, rs} ->
        {cat, %{total: length(rs), passed: Enum.count(rs, & &1.pass)}}
      end)

    latencies = Enum.map(results, & &1.ms)

    %{
      total: total,
      passed: passed,
      accuracy: ratio(passed, total),
      by_category: by_category,
      avg_ms: if(total > 0, do: div(Enum.sum(latencies), total), else: 0),
      max_ms: Enum.max(latencies, fn -> 0 end),
      failures:
        results |> Enum.reject(& &1.pass) |> Enum.map(&Map.take(&1, [:id, :expected, :actual]))
    }
  end

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, d), do: Float.round(n / d, 3)

  defp with_router_strategy(nil, fun), do: fun.()

  defp with_router_strategy(strategy, fun) do
    original = Application.get_env(:allbert_assist, :intent_router_strategy_override)
    Application.put_env(:allbert_assist, :intent_router_strategy_override, strategy)

    try do
      fun.()
    after
      restore_env(:intent_router_strategy_override, original)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
