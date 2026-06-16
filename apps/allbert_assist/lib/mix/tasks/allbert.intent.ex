defmodule Mix.Tasks.Allbert.Intent do
  @moduledoc """
  Inspect the intent router (v0.54).

  ## Usage

      mix allbert.intent doctor
      mix allbert.intent bench [--subset | --holdout]

  `doctor` probes the local embedder and reports the router strategy, configured
  profiles, and utterance-index state in a redacted ADR 0047 envelope.

  `bench` (v0.54 M9.2) replays the golden-set anchor cases through the **live**
  router and reports per-category accuracy + latency. `--subset` runs the tuning
  split (drops holdout cases); `--holdout` runs only the reserved holdout split.
  Requires a live local model (Ollama).
  """
  @shortdoc "Inspect the intent router (doctor / bench)"

  use Mix.Task

  alias AllbertAssist.Intent.Bench
  alias AllbertAssist.Intent.Router.Doctor

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    dispatch(args)
  end

  defp dispatch(["doctor"]) do
    {:ok, envelope} = Doctor.diagnose()
    print_doctor(envelope)
  end

  defp dispatch(["bench" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [subset: :boolean, holdout: :boolean])

    Bench.run(opts) |> print_bench()
  end

  defp dispatch(_args),
    do: Mix.raise("Usage: mix allbert.intent doctor | bench [--subset|--holdout]")

  defp print_bench(%{summary: s}) do
    Mix.shell().info("""
    intent bench accuracy=#{s.accuracy} (#{s.passed}/#{s.total}) avg=#{s.avg_ms}ms max=#{s.max_ms}ms
    """)

    s.by_category
    |> Enum.sort()
    |> Enum.each(fn {cat, %{passed: p, total: t}} ->
      Mix.shell().info("  #{cat}: #{p}/#{t}")
    end)

    if s.failures != [] do
      Mix.shell().info("\nfailures:")

      Enum.each(s.failures, fn f ->
        Mix.shell().info("  #{f.id}: expected=#{inspect(f.expected)} actual=#{inspect(f.actual)}")
      end)
    end
  end

  defp print_doctor(e) do
    Mix.shell().info("""
    intent router doctor status=#{e.status}
    strategy=#{e.strategy}
    embedding_profile=#{e.embedding_profile} endpoint=#{e.embedding_endpoint} dim=#{e.embedding_dim}
    model_profile=#{e.model_profile} escalation=#{e.escalation_profile}
    index status=#{e.index_status} size=#{e.index_size} built_at=#{e.index_built_at}
    """)
  end
end
