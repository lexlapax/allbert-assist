defmodule AllbertAssist.Actions.Intent.OperatorSupport do
  @moduledoc false

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Intent.Eval.{Corpus, Gate, Runner, Scorer}
  alias AllbertAssist.Intent.Router.{DescriptorResolver, DescriptorStore}

  @baseline_candidates [
    "apps/allbert_assist/test/fixtures/intent/eval/baseline.yaml",
    "test/fixtures/intent/eval/baseline.yaml"
  ]

  @spec descriptors() :: [map()]
  def descriptors do
    DescriptorResolver.resolve()
    |> Enum.map(&descriptor_dto/1)
    |> Enum.sort_by(& &1.action_name)
  end

  @spec descriptor(String.t()) :: map() | nil
  def descriptor(action) when is_binary(action) do
    Enum.find(descriptors(), &(&1.action_name == action))
  end

  def descriptor(_action), do: nil

  @spec coverage() :: map()
  def coverage do
    agent_names =
      ActionsRegistry.agent_modules()
      |> Enum.map(& &1.name())
      |> MapSet.new()

    resolved_names =
      DescriptorResolver.resolve()
      |> Enum.map(& &1.action_name)
      |> MapSet.new()

    overrides = DescriptorStore.read_attrs(:overrides)
    generated = DescriptorStore.read_attrs(:generated)
    review = DescriptorStore.read_attrs(:review)
    missing = agent_names |> MapSet.difference(resolved_names) |> MapSet.to_list() |> Enum.sort()
    routable = MapSet.size(MapSet.intersection(agent_names, resolved_names))

    %{
      agent_exposed: MapSet.size(agent_names),
      routable: routable,
      covered: routable,
      missing: missing,
      generated: length(generated),
      review: length(review),
      review_pending: length(review),
      overridden: length(overrides),
      disabled: Enum.count(overrides, &truthy?(field(&1, :disabled))),
      per_domain: %{}
    }
  end

  @spec review_proposals() :: [map()]
  def review_proposals do
    DescriptorStore.read_attrs(:review)
    |> Enum.map(&proposal_dto/1)
    |> Enum.sort_by(&{&1.app_id, &1.action_name})
  end

  @spec baseline_summary() :: map() | nil
  def baseline_summary do
    with path when is_binary(path) <- Enum.find(@baseline_candidates, &File.exists?/1),
         {:ok, %{} = baseline} <- YamlElixir.read_from_file(path) do
      %{
        id: field(baseline, :id),
        corpus_case_count: field(baseline, :corpus_case_count),
        overall_accuracy: field(baseline, :overall_accuracy),
        gate_status: baseline |> field(:gate, %{}) |> field(:status),
        path: Path.relative_to_cwd(path),
        raw: baseline
      }
    else
      _other -> nil
    end
  end

  @spec eval_result(keyword()) :: {:ok, map()} | {:error, term()}
  def eval_result(opts \\ []) do
    surface = Keyword.get(opts, :surface, :any)

    with {:ok, cases} <- Corpus.load() do
      run = Runner.run(cases, surface: surface)
      baseline = baseline_summary()
      baseline_raw = if baseline, do: baseline.raw
      score = Scorer.score(run, baseline_raw)

      {:ok,
       %{
         corpus_case_count: length(cases),
         run_metadata: run.metadata,
         baseline: public_baseline(baseline),
         score: score_dto(score),
         gate: gate_dto(score, baseline_raw)
       }}
    end
  end

  @spec render_doctor(map(), map(), map() | nil) :: String.t()
  def render_doctor(router, coverage, baseline) do
    [
      "intent router doctor status=#{field(router, :status)}",
      "strategy=#{field(router, :strategy)}",
      "embedding_profile=#{field(router, :embedding_profile)} endpoint=#{field(router, :embedding_endpoint)} dim=#{field(router, :embedding_dim)}",
      "model_profile=#{field(router, :model_profile)} escalation=#{field(router, :escalation_profile)}",
      "index status=#{field(router, :index_status)} size=#{field(router, :index_size)} built_at=#{field(router, :index_built_at)}",
      render_coverage(coverage),
      render_baseline_line(baseline)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec render_descriptors([map()]) :: String.t()
  def render_descriptors([]), do: "no resolved descriptors"

  def render_descriptors(descriptors) do
    descriptors
    |> Enum.map(fn descriptor ->
      "  #{descriptor.action_name} source=#{descriptor.source_label} app_id=#{descriptor.app_id}"
    end)
    |> Enum.join("\n")
  end

  @spec render_descriptor(map() | nil, String.t()) :: String.t()
  def render_descriptor(nil, action), do: "no resolved descriptor for #{action}"

  def render_descriptor(descriptor, _action) do
    """
    #{descriptor.action_name} [#{descriptor.source_label}] app_id=#{descriptor.app_id}
      label: #{descriptor.label}
      examples: #{descriptor.examples_count}
      synonyms: #{descriptor.synonyms_count}
      required_slots: #{inspect(descriptor.required_slots)}
      optional_slots: #{inspect(descriptor.optional_slots)}
      override file: #{descriptor.override_ref}
    """
    |> String.trim()
  end

  @spec render_coverage(map()) :: String.t()
  def render_coverage(coverage) do
    "coverage: routable=#{coverage.routable}/#{coverage.agent_exposed} " <>
      "missing=#{missing_count(coverage.missing)} generated=#{coverage.generated} " <>
      "learned_review=#{review_count(coverage)} overridden=#{coverage.overridden} " <>
      "disabled=#{Map.get(coverage, :disabled, 0)}"
  end

  @spec render_review([map()]) :: String.t()
  def render_review([]), do: "no descriptors pending review"

  def render_review(proposals) do
    proposals
    |> Enum.map(fn proposal -> "  #{proposal.action_name} app_id=#{proposal.app_id}" end)
    |> Enum.join("\n")
  end

  @spec render_eval_result(map()) :: String.t()
  def render_eval_result(eval_result) do
    score = eval_result.score
    gate = eval_result.gate

    [
      "intent eval run total=#{score.total} passed=#{score.passed} accuracy=#{score.overall_accuracy} gate=#{gate.status}",
      "negative_violations=#{length(score.negative_violations)} baseline=#{baseline_id(eval_result.baseline)}",
      render_domain_scores(score.per_domain)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp descriptor_dto(descriptor) do
    %{
      app_id: app_id_label(field(descriptor, :app_id)),
      action_name: field(descriptor, :action_name),
      label: field(descriptor, :label),
      source: field(descriptor, :source),
      source_label: source_label(field(descriptor, :source)),
      examples_count: descriptor |> field(:examples, []) |> length(),
      synonyms_count: descriptor |> field(:synonyms, []) |> length(),
      required_slots: field(descriptor, :required_slots, []),
      optional_slots: field(descriptor, :optional_slots, []),
      disabled?: truthy?(field(descriptor, :disabled)),
      override_ref: override_ref(descriptor)
    }
  end

  defp proposal_dto(attrs) do
    %{
      app_id: attrs |> field(:app_id, :allbert) |> app_id_label(),
      action_name: attrs |> field(:action_name) |> to_string(),
      label: field(attrs, :label),
      source: :review,
      source_label: source_label(:review),
      examples_count: attrs |> field(:examples, []) |> List.wrap() |> length(),
      synonyms_count: attrs |> field(:synonyms, []) |> List.wrap() |> length(),
      required_slots: field(attrs, :required_slots, []),
      disabled?: truthy?(field(attrs, :disabled))
    }
  end

  defp score_dto(score) do
    %{
      total: score.total,
      passed: score.passed,
      overall_accuracy: score.overall_accuracy,
      per_domain: score.per_domain,
      per_surface: score.per_surface,
      confusion: score.confusion,
      slot_accuracy: score.slot_accuracy,
      clarify_vs_execute: score.clarify_vs_execute,
      negative_violations: score.negative_violations
    }
  end

  defp gate_dto(score, baseline_raw) do
    case Gate.check(score, baseline_raw) do
      :ok ->
        %{
          status: :pass,
          failures: [],
          regressions: get_in(score, [:gate, :regressions]) || [],
          baseline: get_in(score, [:gate, :baseline])
        }

      {:error, failures} ->
        %{
          status: :fail,
          failures: failures,
          regressions: get_in(score, [:gate, :regressions]) || [],
          baseline: get_in(score, [:gate, :baseline])
        }
    end
  end

  defp public_baseline(nil), do: nil
  defp public_baseline(baseline), do: Map.drop(baseline, [:raw])

  defp render_baseline_line(nil), do: "baseline id=none gate=missing"

  defp render_baseline_line(baseline) do
    "baseline id=#{baseline.id} cases=#{baseline.corpus_case_count} " <>
      "accuracy=#{baseline.overall_accuracy} gate=#{baseline.gate_status}"
  end

  defp render_domain_scores(per_domain) when map_size(per_domain) == 0, do: nil

  defp render_domain_scores(per_domain) do
    per_domain
    |> Enum.sort_by(fn {domain, _stats} -> domain end)
    |> Enum.map(fn {domain, stats} ->
      "  #{domain}: #{stats.passed}/#{stats.total} accuracy=#{stats.accuracy}"
    end)
    |> Enum.join("\n")
  end

  defp baseline_id(nil), do: "none"
  defp baseline_id(%{id: id}), do: id || "none"

  defp source_label(source) when source in [:app, :action], do: "code"
  defp source_label(:overrides), do: "override"
  defp source_label(:review), do: "learned_review"
  defp source_label(source) when is_atom(source), do: Atom.to_string(source)
  defp source_label(source) when is_binary(source), do: source
  defp source_label(_source), do: "unknown"

  defp override_ref(descriptor) do
    with {:ok, path} <-
           DescriptorStore.path(
             :overrides,
             field(descriptor, :app_id),
             field(descriptor, :action_name)
           ) do
      Path.relative_to(path, DescriptorStore.root())
    else
      _other -> "unavailable"
    end
  end

  defp missing_count(missing) when is_list(missing), do: length(missing)
  defp missing_count(missing) when is_integer(missing), do: missing
  defp missing_count(_missing), do: 0

  defp review_count(coverage) do
    Map.get(coverage, :review, Map.get(coverage, :review_pending, 0))
  end

  defp app_id_label(value) when is_atom(value), do: Atom.to_string(value)
  defp app_id_label(value) when is_binary(value), do: value
  defp app_id_label(nil), do: nil
  defp app_id_label(value), do: to_string(value)

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp field(map, key, default \\ nil)

  defp field(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
