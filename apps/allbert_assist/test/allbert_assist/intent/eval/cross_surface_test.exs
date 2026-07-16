defmodule AllbertAssist.Intent.Eval.CrossSurfaceTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Intent.Eval.{Corpus, Runner, Scorer}

  @surfaces Corpus.surfaces() -- [:any]
  @representative_ids ~w(
    notes-create-001
    stocks-analyze-001
    settings-model-ambiguous-001
    answer-001
    slash-intents-negative-001
    planned-operator-intent-doctor-negative-001
  )

  test "representative routes are identical across deterministic surfaces" do
    {:ok, cases} = Corpus.load()
    cases_by_id = Map.new(cases, &{&1.id, &1})

    for id <- @representative_ids do
      case = Map.fetch!(cases_by_id, id)
      expected = route_label(Runner.run([case], disambiguation_margin: 0.12).results)

      for surface <- @surfaces do
        surface_case = %{case | id: "#{case.id}-#{surface}", surface: surface}

        assert route_label(
                 Runner.run([surface_case], surface: surface, disambiguation_margin: 0.12).results
               ) == expected,
               "#{case.id} drifted on #{surface}"
      end
    end
  end

  test "committed surface-specific cases pass on every deterministic surface" do
    {:ok, cases} = Corpus.load()
    score = Scorer.score(Runner.run(cases))

    for surface <- @surfaces do
      surface_stats = Map.fetch!(score.per_surface, to_string(surface))

      assert score.negative_violations == []
      assert score.overall_accuracy == 1.0
      assert surface_stats.total >= 1
      assert surface_stats.passed == surface_stats.total
    end
  end

  defp route_label([%{actual: actual}]) do
    {actual.kind, actual.action}
  end
end
