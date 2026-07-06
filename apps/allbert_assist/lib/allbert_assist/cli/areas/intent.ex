defmodule AllbertAssist.CLI.Areas.Intent do
  @moduledoc """
  Release-safe `intent` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.intent` and `allbert admin intent`:
  `dispatch/2` parses the sub-argv, routes to the same registered actions (and
  the live `Intent.Bench`) the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Intent` is a thin wrapper that prints the
  output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Intent.Bench
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage "Usage: mix allbert.intent doctor | bench [--subset|--holdout] | " <>
           "coverage | eval run [--surface SURFACE|--by-surface] | eval baseline|capture|add | " <>
           "optimize [--heuristic] | reindex | " <>
           "list | show ACTION | edit ACTION | disable ACTION | enable ACTION | promote ACTION | review"

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin intent")

  defp route(["doctor"], ctx), do: {:ok, {:message, message("intent_doctor", %{}, ctx)}}

  defp route(["coverage"], ctx),
    do: {:ok, {:message, message("intent_coverage", operator_report_params(), ctx)}}

  defp route(["eval", "run" | rest], ctx) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [surface: :string, by_surface: :boolean])

    {:ok, {:message, message("intent_eval_run", Map.new(opts), ctx)}}
  end

  defp route(["eval", "baseline" | rest], ctx) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [id: :string, fixture_root: :string])

    {:ok, {:message, message("intent_eval_baseline", Map.new(opts), ctx)}}
  end

  defp route(["eval", "capture" | rest], ctx) do
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

    {:ok, {:message, message("intent_eval_capture", params, ctx)}}
  end

  defp route(["eval", "add" | rest], ctx) do
    {opts, refs, _invalid} =
      OptionParser.parse(rest,
        strict: [id: :string, path: :string, fixture_root: :string, force: :boolean]
      )

    params =
      opts
      |> Map.new()
      |> maybe_put_id(refs)

    {:ok, {:message, message("intent_eval_add", params, ctx)}}
  end

  defp route(["bench" | rest], _ctx) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [subset: :boolean, holdout: :boolean])

    {:ok, {:bench, Bench.run(opts)}}
  end

  defp route(["optimize" | rest], ctx) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [heuristic: :boolean])

    {:ok, {:message, message("optimize_intent_descriptors", Map.new(opts), ctx)}}
  end

  defp route(["reindex"], ctx),
    do: {:ok, {:message, message("reindex_intent_descriptors", %{}, ctx)}}

  defp route(["list"], ctx),
    do: {:ok, {:message, message("intent_list_descriptors", operator_report_params(), ctx)}}

  defp route(["show", action], ctx),
    do: {:ok, {:message, message("intent_show_descriptor", %{action: action}, ctx)}}

  defp route(["edit", action], ctx),
    do: {:ok, {:message, message("edit_intent_descriptor", %{action: action}, ctx)}}

  defp route(["disable", action], ctx),
    do: {:ok, {:message, message("disable_intent_descriptor", %{action: action}, ctx)}}

  defp route(["enable", action], ctx),
    do: {:ok, {:message, message("enable_intent_descriptor", %{action: action}, ctx)}}

  defp route(["promote", action | rest], ctx) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [from: :string, to: :string],
        aliases: [f: :from, t: :to]
      )

    {:ok,
     {:message,
      message("promote_intent_descriptor", Map.merge(Map.new(opts), %{action: action}), ctx)}}
  end

  defp route(["review"], ctx),
    do: {:ok, {:message, message("intent_list_review", operator_report_params(), ctx)}}

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:message, message}}), do: Render.ok(message)
  defp render({:ok, {:bench, %{summary: summary}}}), do: Render.ok(bench_lines(summary))
  defp render({:usage, usage}), do: Render.usage(usage)

  defp message(name, params, ctx) do
    %{message: message} = completed_action(name, params, ctx)
    message
  end

  defp completed_action(name, params, ctx) do
    case ActionHelper.completed_action(name, params, ctx, error: :response) do
      {:ok, response} -> response
      {:error, %{message: _message} = response} -> response
      {:error, reason} -> %{message: "intent action #{name} failed: #{inspect(reason)}"}
    end
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp bench_lines(s) do
    header =
      "intent bench strategy=#{s.router_strategy} accuracy=#{s.accuracy} " <>
        "(#{s.passed}/#{s.total}) avg=#{s.avg_ms}ms max=#{s.max_ms}ms"

    category_lines =
      s.by_category
      |> Enum.sort()
      |> Enum.map(fn {cat, %{passed: p, total: t}} -> "  #{cat}: #{p}/#{t}" end)

    failure_lines =
      if s.failures != [] do
        ["", "failures:"] ++
          Enum.map(s.failures, fn f ->
            "  #{f.id}: expected=#{inspect(f.expected)} actual=#{inspect(f.actual)}"
          end)
      else
        []
      end

    [header, "" | category_lines] ++ failure_lines
  end

  defp maybe_put_ref(params, [ref | _rest]), do: Map.put(params, :ref, ref)
  defp maybe_put_ref(params, _refs), do: params

  defp maybe_put_id(params, [id | _rest]), do: Map.put_new(params, :id, id)
  defp maybe_put_id(params, _refs), do: params
end
