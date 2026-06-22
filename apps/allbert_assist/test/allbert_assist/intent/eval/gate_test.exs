defmodule AllbertAssist.Intent.Eval.GateTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Intent.Eval.Gate
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-intent-eval-gate-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      restore(Paths, original_paths)
      restore(Settings, original_settings)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "passes a score above floors with no negatives" do
    assert :ok =
             Gate.check(%{
               overall_accuracy: 1.0,
               per_domain: %{"notes" => %{accuracy: 1.0}},
               negative_violations: [],
               gate: %{regressions: []}
             })
  end

  test "fails below floors and on negative-route violations" do
    assert {:error, failures} =
             Gate.check(%{
               overall_accuracy: 0.5,
               per_domain: %{"notes" => %{accuracy: 0.5}},
               negative_violations: [%{id: "operator-negative-001"}],
               gate: %{regressions: []}
             })

    assert Enum.any?(failures, &(&1.reason == :accuracy_below_floor))
    assert Enum.any?(failures, &(&1.reason == :domain_accuracy_below_floor))
    assert Enum.any?(failures, &(&1.reason == :negative_route_violation))
  end

  test "blocks regressions while block_on_regression is enabled" do
    assert {:error, failures} =
             Gate.check(%{
               overall_accuracy: 1.0,
               per_domain: %{"notes" => %{accuracy: 1.0}},
               negative_violations: [],
               gate: %{regressions: [%{metric: :overall_accuracy, previous: 1.0, current: 0.9}]}
             })

    assert [%{reason: :regression, metric: :overall_accuracy}] = failures
  end

  defp restore(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
