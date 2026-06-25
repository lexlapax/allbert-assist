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
      mix allbert.intent enable ACTION

  `doctor` probes the local embedder and reports the router strategy, configured
  profiles, and utterance-index state in a redacted ADR 0047 envelope.

  `bench` (v0.54 M9.2) replays the golden-set anchor cases through the **live**
  router and reports per-category accuracy + latency. `--subset` runs the tuning
  split (drops holdout cases); `--holdout` runs only the reserved holdout split.
  Requires a live local model (Ollama).
  """
  @shortdoc "Inspect the intent router (doctor / bench)"

  use Mix.Task

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Intent.Bench
  alias AllbertAssist.Surfaces.ContextBuilder

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    dispatch(args)
  end

  defp dispatch(["doctor"]) do
    "intent_doctor"
    |> completed_action(%{})
    |> print_message()
  end

  defp dispatch(["coverage"]) do
    "intent_coverage"
    |> completed_action(%{})
    |> print_message()
  end

  defp dispatch(["eval", "run" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [surface: :string, by_surface: :boolean])

    "intent_eval_run"
    |> completed_action(Map.new(opts))
    |> print_message()
  end

  defp dispatch(["eval", "baseline" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [id: :string, fixture_root: :string])

    "intent_eval_baseline"
    |> completed_action(Map.new(opts))
    |> print_message()
  end

  defp dispatch(["eval", "capture" | rest]) do
    {opts, refs, _invalid} =
      OptionParser.parse(rest,
        strict: [
          id: :string,
          domain: :string,
          surface: :string,
          utterance: :string,
          kind: :string,
          action: :string,
          negative: :boolean,
          holdout: :boolean,
          rationale: :string
        ]
      )

    params =
      opts
      |> Map.new()
      |> maybe_put_ref(refs)

    "intent_eval_capture"
    |> completed_action(params)
    |> print_message()
  end

  defp dispatch(["eval", "add" | rest]) do
    {opts, refs, _invalid} =
      OptionParser.parse(rest,
        strict: [id: :string, path: :string, fixture_root: :string, force: :boolean]
      )

    params =
      opts
      |> Map.new()
      |> maybe_put_id(refs)

    "intent_eval_add"
    |> completed_action(params)
    |> print_message()
  end

  defp dispatch(["bench" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [subset: :boolean, holdout: :boolean])

    Bench.run(opts) |> print_bench()
  end

  defp dispatch(["optimize" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [heuristic: :boolean])

    "optimize_intent_descriptors"
    |> completed_action(Map.new(opts))
    |> print_message()
  end

  defp dispatch(["reindex"]) do
    "reindex_intent_descriptors"
    |> completed_action(%{})
    |> print_message()
  end

  defp dispatch(["list"]) do
    "intent_list_descriptors"
    |> completed_action(%{})
    |> print_message()
  end

  defp dispatch(["show", action]) do
    "intent_show_descriptor"
    |> completed_action(%{action: action})
    |> print_message()
  end

  defp dispatch(["edit", action]) do
    "edit_intent_descriptor"
    |> completed_action(%{action: action})
    |> print_message()
  end

  defp dispatch(["disable", action]) do
    "disable_intent_descriptor"
    |> completed_action(%{action: action})
    |> print_message()
  end

  defp dispatch(["enable", action]) do
    "enable_intent_descriptor"
    |> completed_action(%{action: action})
    |> print_message()
  end

  defp dispatch(["promote", action | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [from: :string, to: :string],
        aliases: [f: :from, t: :to]
      )

    "promote_intent_descriptor"
    |> completed_action(Map.merge(Map.new(opts), %{action: action}))
    |> print_message()
  end

  defp dispatch(["review"]) do
    "intent_list_review"
    |> completed_action(%{})
    |> print_message()
  end

  defp dispatch(_args),
    do:
      Mix.raise(
        "Usage: mix allbert.intent doctor | bench [--subset|--holdout] | " <>
          "coverage | eval run [--surface SURFACE|--by-surface] | eval baseline|capture|add | " <>
          "optimize [--heuristic] | reindex | " <>
          "list | show ACTION | edit ACTION | disable ACTION | enable ACTION | promote ACTION | review"
      )

  defp completed_action(name, params) do
    {:ok, response} = ActionHelper.completed_action(name, params, operator_context())
    response
  end

  defp operator_context do
    ContextBuilder.cli_context(
      actor: "local",
      operator_id: "local",
      channel: :mix,
      surface: "mix allbert.intent",
      source: "mix allbert.intent"
    )
  end

  defp print_message(%{message: message}), do: Mix.shell().info(message)

  defp print_bench(%{summary: s}) do
    Mix.shell().info("""
    intent bench strategy=#{s.router_strategy} accuracy=#{s.accuracy} (#{s.passed}/#{s.total}) avg=#{s.avg_ms}ms max=#{s.max_ms}ms
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

  defp maybe_put_ref(params, [ref | _rest]), do: Map.put(params, :ref, ref)
  defp maybe_put_ref(params, _refs), do: params

  defp maybe_put_id(params, [id | _rest]), do: Map.put_new(params, :id, id)
  defp maybe_put_id(params, _refs), do: params
end
