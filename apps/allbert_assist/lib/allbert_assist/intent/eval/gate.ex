defmodule AllbertAssist.Intent.Eval.Gate do
  @moduledoc """
  Blocking routing-accuracy gate for descriptor promotion and release checks.
  """

  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Eval.{Corpus, Runner}
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Eval.Scorer
  alias AllbertAssist.Settings

  @baseline_candidates [
    "apps/allbert_assist/test/fixtures/intent/eval/baseline.yaml",
    "test/fixtures/intent/eval/baseline.yaml"
  ]

  @spec check(map(), map() | nil) :: :ok | {:error, [map()]}
  def check(run_or_score, baseline \\ nil) do
    score = ensure_score(run_or_score, baseline)
    regressions = failures(score, baseline)

    if regressions == [] do
      :ok
    else
      {:error, regressions}
    end
  end

  @spec check_promotion(map(), keyword()) :: :ok | {:error, [map()]}
  def check_promotion(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, candidate} <- Descriptor.normalize(attrs, source: :promotion_candidate),
         descriptors <-
           opts
           |> Keyword.get(:descriptors, DescriptorResolver.resolve())
           |> with_candidate(candidate) do
      check_descriptors(descriptors, opts)
    else
      {:error, diagnostic} ->
        {:error, [%{reason: :invalid_promotion_descriptor, diagnostic: diagnostic}]}
    end
  end

  @spec check_descriptors([Descriptor.t()], keyword()) :: :ok | {:error, [map()]}
  def check_descriptors(descriptors, opts \\ []) when is_list(descriptors) do
    with {:ok, cases} <- Corpus.load() do
      baseline = Keyword.get(opts, :baseline, baseline_raw())
      cases |> Runner.run(descriptors: descriptors) |> check(baseline)
    else
      {:error, reason} ->
        {:error, [%{reason: :promotion_gate_unavailable, diagnostic: reason}]}
    end
  end

  @spec check_removal(atom(), String.t(), keyword()) :: :ok | {:error, [map()]}
  def check_removal(app_id, action_name, opts \\ [])
      when is_atom(app_id) and is_binary(action_name) do
    descriptors =
      opts
      |> Keyword.get(:descriptors, DescriptorResolver.resolve())
      |> Enum.reject(&(&1.app_id == app_id and &1.action_name == action_name))

    check_descriptors(descriptors, opts)
  end

  defp with_candidate(descriptors, candidate) do
    descriptors
    |> Enum.reject(&(&1.app_id == candidate.app_id and &1.action_name == candidate.action_name))
    |> Kernel.++([candidate])
  end

  defp ensure_score(%{overall_accuracy: _} = score, _baseline), do: score
  defp ensure_score(run, baseline), do: Scorer.score(run, baseline)

  defp failures(score, baseline) do
    []
    |> maybe_negative_violations(score)
    |> maybe_accuracy_floor(score)
    |> maybe_domain_floor(score)
    |> maybe_blocked_regressions(score, baseline)
    |> Enum.reverse()
  end

  defp maybe_negative_violations(acc, %{negative_violations: []}), do: acc

  defp maybe_negative_violations(acc, %{negative_violations: violations}) do
    [%{reason: :negative_route_violation, violations: violations} | acc]
  end

  defp maybe_accuracy_floor(acc, score) do
    floor = setting_float("intent.eval.min_accuracy", 0.85)

    if score.overall_accuracy < floor do
      [
        %{
          reason: :accuracy_below_floor,
          metric: :overall_accuracy,
          floor: floor,
          actual: score.overall_accuracy
        }
        | acc
      ]
    else
      acc
    end
  end

  defp maybe_domain_floor(acc, score) do
    floor = setting_float("intent.eval.min_per_domain_accuracy", 0.8)

    score.per_domain
    |> Enum.filter(fn {_domain, stats} -> stats.accuracy < floor end)
    |> Enum.reduce(acc, fn {domain, stats}, acc ->
      [
        %{
          reason: :domain_accuracy_below_floor,
          domain: domain,
          floor: floor,
          actual: stats.accuracy
        }
        | acc
      ]
    end)
  end

  defp maybe_blocked_regressions(acc, score, _baseline) do
    if setting_bool("intent.eval.block_on_regression", true) do
      regressions = get_in(score, [:gate, :regressions]) || []

      Enum.reduce(regressions, acc, fn regression, acc ->
        [Map.put(regression, :reason, :regression) | acc]
      end)
    else
      acc
    end
  end

  defp setting_float(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_number(value) -> value
      _other -> default
    end
  end

  defp setting_bool(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_boolean(value) -> value
      _other -> default
    end
  end

  defp baseline_raw do
    @baseline_candidates
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        nil

      path ->
        case YamlElixir.read_from_file(path) do
          {:ok, %{} = baseline} -> baseline
          _error -> nil
        end
    end
  end
end
