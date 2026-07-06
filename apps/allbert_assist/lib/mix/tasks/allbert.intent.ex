defmodule Mix.Tasks.Allbert.Intent do
  @moduledoc """
  Inspect the intent router (v0.54).

  ## Usage

      mix allbert.intent doctor
      mix allbert.intent coverage
      mix allbert.intent list
      mix allbert.intent show ACTION
      mix allbert.intent review
      mix allbert.intent eval run [--surface SURFACE | --by-surface]
      mix allbert.intent eval baseline [--id ID]
      mix allbert.intent eval capture [REF] --domain DOMAIN --utterance TEXT --kind KIND [--action ACTION]
      mix allbert.intent eval add ID [--fixture-root PATH]
      mix allbert.intent bench [--subset | --holdout]
      mix allbert.intent edit ACTION
      mix allbert.intent disable ACTION
      mix allbert.intent enable ACTION
      mix allbert.intent promote ACTION [--from TIER] [--to TIER]
      mix allbert.intent optimize [--heuristic]
      mix allbert.intent reindex

  `doctor` probes the local embedder and reports the router strategy, configured
  profiles, and utterance-index state in a redacted ADR 0047 envelope.

  `bench` (v0.54 M9.2) replays the golden-set anchor cases through the **live**
  router and reports per-category accuracy + latency. `--subset` runs the tuning
  split (drops holdout cases); `--holdout` runs only the reserved holdout split.
  Requires a live local model (Ollama).
  """
  @shortdoc "Inspect the intent router (doctor / bench)"

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Intent, args)
  end
end
