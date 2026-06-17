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

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Intent.Bench
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Intent.Router.Doctor
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Intent.Router.Optimizer

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
    DescriptorResolver.resolve()
    |> Enum.sort_by(& &1.action_name)
    |> Enum.each(fn d ->
      Mix.shell().info("  #{d.action_name} [#{d.source}] #{d.app_id}")
    end)
  end

  defp dispatch(["show", action]) do
    case Enum.find(DescriptorResolver.resolve(), &(&1.action_name == action)) do
      nil ->
        Mix.shell().info("no resolved descriptor for #{action}")

      d ->
        override_path =
          case DescriptorStore.path(:overrides, d.app_id, action) do
            {:ok, path} -> path
            {:error, reason} -> inspect(reason)
          end

        Mix.shell().info("""
        #{d.action_name} [#{d.source}] app_id=#{d.app_id}
          label: #{d.label}
          examples: #{inspect(d.examples)}
          synonyms: #{inspect(d.synonyms)}
          override file: #{override_path}
        """)
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

  defp dispatch(["promote", action | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [from: :string, to: :string],
        aliases: [f: :from, t: :to]
      )

    from = tier_option(opts[:from], :review)
    to = tier_option(opts[:to], :generated)

    case DescriptorStore.promote(from, to, descriptor_app_id(action), action) do
      {:ok, path} ->
        Mix.shell().info(
          "promoted #{action} -> #{path}; run `mix allbert.intent reindex` to apply"
        )

      {:error, reason} ->
        Mix.shell().info("could not promote #{action}: #{inspect(reason)}")
    end
  end

  defp dispatch(["review"]) do
    case DescriptorStore.read_attrs(:review) do
      [] ->
        Mix.shell().info("no descriptors pending review")

      attrs ->
        Enum.each(attrs, fn a ->
          Mix.shell().info(
            "  #{Map.get(a, :action_name) || Map.get(a, "action_name")} " <>
              "app_id=#{Map.get(a, :app_id) || Map.get(a, "app_id")}"
          )
        end)
    end
  end

  defp dispatch(_args),
    do:
      Mix.raise(
        "Usage: mix allbert.intent doctor | bench [--subset|--holdout] | " <>
          "optimize [--heuristic] | reindex | list | show ACTION | disable ACTION | " <>
          "promote ACTION | review"
      )

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

  defp print_coverage(c) do
    Mix.shell().info(
      "coverage: routable=#{c.routable}/#{c.agent_exposed} missing=#{c.missing} " <>
        "generated=#{c.generated} learned_review=#{c.review_pending} overridden=#{c.overridden}"
    )
  end

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

    print_coverage(Optimizer.coverage())
  end
end
