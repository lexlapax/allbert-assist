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

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Runner, as: ActionsRunner
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Intent.Bench
  alias AllbertAssist.Intent.Eval.Gate
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Intent.Router.Optimizer

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

  defp dispatch(["bench" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [subset: :boolean, holdout: :boolean])

    Bench.run(opts) |> print_bench()
  end

  defp dispatch(["optimize" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [heuristic: :boolean])

    strategy = if opts[:heuristic], do: :heuristic, else: :model
    result = Optimizer.optimize(strategy: strategy)

    Mix.shell().info(
      "generated=#{length(result.generated)} review_pending=#{length(result.reviewed)}"
    )

    print_coverage(result.coverage)
  end

  defp dispatch(["reindex"]) do
    state = Index.rebuild()
    Mix.shell().info("index status=#{state.status} size=#{length(state.entries)}")
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
    case descriptor_for_action(action) do
      nil ->
        Mix.raise("no resolved descriptor for #{action}")

      descriptor ->
        {:ok, path} = DescriptorStore.put(:overrides, override_attrs(descriptor))

        Mix.shell().info(
          "override #{action} -> #{path}; edit this YAML and run `mix allbert.intent reindex` to apply"
        )
    end
  end

  defp dispatch(["disable", action]) do
    {:ok, path} =
      DescriptorStore.put(:overrides, %{
        app_id: descriptor_app_id(action),
        action_name: action,
        disabled: true
      })

    Mix.shell().info("disabled #{action} (#{path}); run `mix allbert.intent reindex` to apply")
  end

  defp dispatch(["enable", action]) do
    {:ok, path} = DescriptorStore.delete(:overrides, descriptor_app_id(action), action)

    Mix.shell().info(
      "enabled #{action} (removed override #{path}); run `mix allbert.intent reindex` to apply"
    )
  end

  defp dispatch(["promote", action | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [from: :string, to: :string],
        aliases: [f: :from, t: :to]
      )

    from = tier_option(opts[:from], :review)
    to = tier_option(opts[:to], :generated)

    app_id = descriptor_app_id(action)

    with {:ok, attrs} <- promotion_attrs(from, app_id, action),
         :ok <- Gate.check_promotion(attrs),
         {:ok, path} <- DescriptorStore.promote(from, to, to_string(app_id), action) do
      Mix.shell().info("promoted #{action} -> #{path}; run `mix allbert.intent reindex` to apply")
    else
      {:error, failures} when is_list(failures) ->
        Mix.shell().info("could not promote #{action}: gate failed #{inspect(failures)}")

      {:error, reason} ->
        Mix.shell().info("could not promote #{action}: #{inspect(reason)}")
    end
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
          "coverage | eval run [--surface SURFACE|--by-surface] | optimize [--heuristic] | reindex | " <>
          "list | show ACTION | edit ACTION | disable ACTION | enable ACTION | promote ACTION | review"
      )

  defp completed_action(name, params) do
    {:ok, response} = ActionsRunner.run(name, params, operator_context())
    response
  end

  defp operator_context do
    %{
      actor: "local",
      operator_id: "local",
      channel: :mix,
      request: %{operator_id: "local", channel: :mix, source: "mix allbert.intent"}
    }
  end

  defp print_message(%{message: message}), do: Mix.shell().info(message)

  defp descriptor_app_id(action) do
    case ActionsRegistry.capability(action) do
      {:ok, capability} -> capability.app_id || :allbert
      _other -> :allbert
    end
  end

  defp tier_option(nil, default), do: default
  defp tier_option("learned", _default), do: :review
  defp tier_option("learned-review", _default), do: :review
  defp tier_option("review", _default), do: :review
  defp tier_option("generated", _default), do: :generated
  defp tier_option("overrides", _default), do: :overrides
  defp tier_option("override", _default), do: :overrides
  defp tier_option(_value, default), do: default

  defp descriptor_for_action(action) do
    Enum.find(DescriptorResolver.resolve(), &(&1.action_name == action))
  end

  defp promotion_attrs(tier, app_id, action) do
    DescriptorStore.read_attrs(tier)
    |> Enum.find(fn attrs ->
      normalize_app_id(field(attrs, :app_id)) == app_id and
        to_string(field(attrs, :action_name)) == action
    end)
    |> case do
      nil -> {:error, :not_found}
      attrs -> {:ok, attrs}
    end
  end

  defp override_attrs(descriptor) do
    %{
      app_id: descriptor.app_id,
      action_name: descriptor.action_name,
      label: descriptor.label,
      destination: descriptor.destination,
      examples: descriptor.examples,
      synonyms: descriptor.synonyms,
      required_slots: descriptor.required_slots,
      optional_slots: descriptor.optional_slots,
      slot_extractors: descriptor.slot_extractors,
      vocabulary: descriptor.vocabulary,
      handoff_required?: descriptor.handoff_required?,
      disabled: false
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp print_coverage(c), do: Mix.shell().info(OperatorSupport.render_coverage(c))

  defp normalize_app_id(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_app_id(value), do: value

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

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
