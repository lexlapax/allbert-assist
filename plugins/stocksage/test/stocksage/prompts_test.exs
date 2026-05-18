defmodule StockSage.PromptsTest do
  use ExUnit.Case, async: true

  @prompt_names ~w[
    bear_thesis.md
    bull_thesis.md
    decision_synthesizer.md
    fundamentals.md
    market_context.md
    news_sentiment.md
    quality_gate.md
    research_manager.md
    risk_aggressive.md
    risk_conservative.md
    risk_neutral.md
    trader_plan.md
  ]

  @recognized_licenses ~w[Apache-2.0 MIT BSD-2-Clause BSD-3-Clause]

  test "native agent prompt inventory is complete" do
    assert @prompt_names ==
             prompt_root()
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".md"))
             |> Enum.sort()
  end

  test "every native agent prompt has attribution and body text" do
    for path <- prompt_paths() do
      text = File.read!(path)
      [first_line | rest] = String.split(text, "\n")

      assert String.starts_with?(first_line, "## Attribution"),
             "#{path} must start with an attribution header"

      assert String.trim(Enum.join(rest, "\n")) != "",
             "#{path} must include a non-empty prompt body"

      assert valid_attribution?(first_line),
             "#{path} must use Allbert-authored attribution or a recognized upstream license"
    end
  end

  defp valid_attribution?(line) do
    String.contains?(line, "Allbert-authored") ||
      Enum.any?(@recognized_licenses, &String.contains?(line, &1))
  end

  defp prompt_paths do
    Enum.map(@prompt_names, &Path.join(prompt_root(), &1))
  end

  defp prompt_root do
    Path.join(repo_root(), "plugins/stocksage/priv/prompts/native_agents")
  end

  defp repo_root, do: Path.expand("../../../../", __DIR__)
end
