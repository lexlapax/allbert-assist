defmodule AllbertAssist.DevGates.V13FanoutWorkerQualityEval do
  @moduledoc """
  Content-safe worker semantic-quality qualification for the v1.3 fan-out gate.

  The frozen matrix supplies the first-call draft so the configured provider is
  spent only on the production worker reviewer/reviser boundary. Acceptance is
  based on the closed `QualityPolicy` verdict/rule evidence, the 1 + 1 provider
  call bound, and whether repair scenarios changed the draft bytes. Neither
  source prompts, drafts, final answers, nor their digests enter TestMetrics.

  Call evidence keeps two dimensions explicit: `protocol_provider_call_count`
  includes the frozen draft as logical call 1, while
  `configured_reviewer_invocation_count` is 0 until the reviewer invocation
  begins and 1 afterward. The latter is an invocation-attempt count, not an
  independently observed transport-request count. Thus the opt-in production
  path never reports a synthetic draft as a configured-provider request.

  This is development tooling. It grants no runtime authority and does not
  replace the Worker/Jido lifecycle owner tests or attended semantic judgment.
  """

  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Runs.Worker.{QualityPolicy, ReqLLMReviewer}

  @scenario_ids [
    "restart-inaccuracy-repaired",
    "replay-guarantee-overclaim-repaired",
    "omitted-required-nuance-unresolved",
    "accurate-paraphrase-accepted",
    "unrelated-domain-accepted"
  ]
  @corpus_id "v13-fanout-worker-quality-real-model-v1"
  @fixture_sha256 "35992f6ee830e8f36af4cb80d4c08b1be5617d26bb3687377d1d12c146d8b425"
  @safe_identifier ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @fixture_keys ~w[schema_version corpus_id scenarios]
  @scenario_keys ~w[id task draft expected]
  @task_keys ~w[source original_request child_objective expected_result]
  @expected_keys ~w[verdict provider_call_count answer_change required_failed_rule_ids]
  @review_keys [
    :failed_rule_ids,
    :final_answer,
    :reviewer_config_sha256,
    :rule_results,
    :verdict
  ]
  @default_row_timeout_ms 30_000
  @maximum_row_timeout_ms 60_000

  @type result :: %{
          status: String.t(),
          stats: map(),
          failed_rows: [String.t()],
          rows: [map()]
        }

  @doc "Load and validate the frozen task-neutral worker-quality matrix."
  @spec load_fixture!(Path.t()) :: map()
  def load_fixture!(path) do
    fixture = path |> File.read!() |> Jason.decode!()

    cond do
      not valid_fixture?(fixture) ->
        raise("invalid v1.3 fan-out worker-quality fixture")

      fixture_sha256(fixture) != @fixture_sha256 ->
        raise("invalid v1.3 fan-out worker-quality fixture digest")

      true ->
        fixture
    end
  end

  @doc "Return the SHA-256 of the canonical decoded worker-quality fixture."
  @spec fixture_sha256(map()) :: String.t()
  def fixture_sha256(fixture) when is_map(fixture),
    do: sha256(CanonicalJSON.encode(fixture))

  @doc "Evaluate the matrix and append one content-free phase record."
  @spec run(map(), keyword()) :: result()
  def run(fixture, opts) when is_map(fixture) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    fixture_sha256 = validated_fixture_sha256!(fixture)
    reviewer = Keyword.get(opts, :reviewer, ReqLLMReviewer)
    reviewer_context = Keyword.get(opts, :reviewer_context, %{})
    row_timeout_ms = bounded_row_timeout(Keyword.get(opts, :row_timeout_ms))

    rows =
      Enum.map(fixture["scenarios"], fn scenario ->
        evaluate_scenario(scenario, reviewer, reviewer_context, row_timeout_ms)
      end)

    failed_rows = for %{passed?: false, id: id} <- rows, do: id
    status = if failed_rows == [], do: "passed", else: "failed"
    profile = opts |> Keyword.fetch!(:profile) |> profile_name()
    stats = stats(profile, fixture_sha256, fixture["scenarios"], rows)

    TestMetrics.record(%{
      store: Keyword.get(opts, :store),
      git_sha: opts |> Keyword.get(:full_sha) |> short_sha(),
      full_sha: Keyword.get(opts, :full_sha),
      dirty: Keyword.get(opts, :dirty),
      cwd: "apps/allbert_assist",
      gate: "bench-v13-fanout",
      phase_or_step: "worker-quality",
      corpus_id: fixture["corpus_id"],
      command: "bench-v13-fanout --profile #{profile}",
      status: status,
      wall_ms: System.monotonic_time(:millisecond) - started,
      stats: stats
    })

    %{status: status, stats: stats, failed_rows: failed_rows, rows: rows}
  end

  @doc "Render the content-free worker-quality phase summary."
  @spec summary(result()) :: String.t()
  def summary(%{status: status, stats: stats}) do
    "v13-fanout-worker-quality status=#{status} " <>
      "rows=#{stats.worker_quality_rows_passed}/#{stats.worker_quality_rows} " <>
      "protocol_calls=#{stats.protocol_provider_call_count} " <>
      "reviewer_invocations=#{stats.configured_reviewer_invocation_count} " <>
      "rules_closed=#{stats.rule_evidence_closed}"
  end

  defp evaluate_scenario(scenario, reviewer, base_context, row_timeout_ms) do
    row_deadline_monotonic_ms = System.monotonic_time(:millisecond) + row_timeout_ms

    context =
      scenario_context(base_context, scenario["id"], row_timeout_ms, row_deadline_monotonic_ms)

    with {:ok, contract} <- quality_contract(scenario),
         {:ok, prepared} <-
           call_before_deadline(
             fn -> safe_prepare(reviewer, contract, scenario["draft"], context) end,
             row_deadline_monotonic_ms,
             :reviewer_prepare_timeout
           ) do
      evaluate_invoked(scenario, reviewer, prepared, context, row_deadline_monotonic_ms)
    else
      _prepare_failure -> invalid_row(scenario["id"], 1)
    end
  end

  defp evaluate_invoked(scenario, reviewer, prepared, context, row_deadline_monotonic_ms) do
    case call_before_deadline(
           fn -> safe_invoke(reviewer, prepared, context) end,
           row_deadline_monotonic_ms,
           :reviewer_invoke_timeout
         ) do
      {:ok, reviewed} ->
        case closed_review(reviewed, prepared) do
          {:ok, evidence} -> reviewed_row(scenario, evidence)
          {:error, _reason} -> invalid_row(scenario["id"], 2)
        end

      {:error, _reason} ->
        invalid_row(scenario["id"], 2)
    end
  end

  defp reviewed_row(scenario, evidence) do
    expected = scenario["expected"]
    answer_changed = evidence.final_answer != scenario["draft"]

    passed? =
      evidence.verdict == expected["verdict"] and
        evidence.provider_call_count == expected["provider_call_count"] and
        evidence.rule_evidence_closed and
        expected_failures_match?(
          evidence.failed_rule_ids,
          expected["required_failed_rule_ids"]
        ) and answer_change_valid?(answer_changed, expected["answer_change"])

    %{
      id: scenario["id"],
      passed?: passed?,
      verdict: evidence.verdict,
      provider_call_count: evidence.provider_call_count,
      configured_reviewer_invocation_count: 1,
      failed_rule_ids: evidence.failed_rule_ids,
      rule_evidence_closed: evidence.rule_evidence_closed,
      answer_changed: answer_changed
    }
  end

  defp invalid_row(id, provider_call_count) do
    %{
      id: id,
      passed?: false,
      verdict: "invalid",
      provider_call_count: provider_call_count,
      configured_reviewer_invocation_count: if(provider_call_count == 2, do: 1, else: 0),
      failed_rule_ids: [],
      rule_evidence_closed: false,
      answer_changed: false
    }
  end

  defp closed_review(reviewed, prepared) when is_map(reviewed) and is_map(prepared) do
    with true <- Enum.sort(Map.keys(reviewed)) == Enum.sort(@review_keys),
         reviewer_config_sha256 when is_binary(reviewer_config_sha256) <-
           Map.get(prepared, :reviewer_config_sha256),
         true <- sha256?(reviewer_config_sha256),
         true <- reviewed.reviewer_config_sha256 == reviewer_config_sha256,
         {:ok, normalized} <-
           reviewed
           |> Map.drop([:reviewer_config_sha256])
           |> QualityPolicy.validate_normalized_review(),
         true <- normalized.failed_rule_ids == reviewed.failed_rule_ids,
         true <- closed_rule_evidence?(normalized.rule_results) do
      {:ok,
       %{
         final_answer: normalized.final_answer,
         verdict: normalized.verdict,
         provider_call_count: 2,
         failed_rule_ids: normalized.failed_rule_ids,
         rule_evidence_closed: true
       }}
    else
      _invalid -> {:error, :invalid_worker_quality_review}
    end
  end

  defp closed_review(_reviewed, _prepared), do: {:error, :invalid_worker_quality_review}

  defp closed_rule_evidence?(rule_results) do
    Enum.map(rule_results, & &1["rule_id"]) == QualityPolicy.rule_ids() and
      Enum.all?(rule_results, &(&1["verdict"] in ~w[satisfied unsatisfied]))
  end

  defp expected_failures_match?(actual, expected), do: actual == expected

  defp answer_change_valid?(true, "required"), do: true
  defp answer_change_valid?(false, "required"), do: false
  defp answer_change_valid?(_answer_changed, "allowed"), do: true

  defp quality_contract(%{"task" => task}) do
    QualityPolicy.build(%{
      source: source(task["source"]),
      original_request: task["original_request"],
      child_objective: task["child_objective"],
      expected_result: task["expected_result"],
      steering: nil
    })
  end

  defp source("conversation_manager"), do: :conversation_manager
  defp source("counted_protocol"), do: :counted_protocol
  defp source(_source), do: :invalid

  defp safe_prepare(reviewer, contract, draft, context) do
    reviewer.prepare(contract, draft, context)
  rescue
    _exception -> {:error, :reviewer_prepare_failed}
  catch
    _kind, _reason -> {:error, :reviewer_prepare_failed}
  end

  defp safe_invoke(reviewer, prepared, context) do
    reviewer.invoke(prepared, context)
  rescue
    _exception -> {:error, :reviewer_invoke_failed}
  catch
    _kind, _reason -> {:error, :reviewer_invoke_failed}
  end

  defp call_before_deadline(callback, deadline_monotonic_ms, timeout_reason) do
    remaining_ms = deadline_monotonic_ms - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      task = Task.async(callback)

      case Task.yield(task, remaining_ms) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, :reviewer_task_failed}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          {:error, timeout_reason}
      end
    else
      {:error, timeout_reason}
    end
  end

  defp scenario_context(base, case_id, row_timeout_ms, deadline_monotonic_ms)
       when is_map(base) do
    base
    |> Map.put(:quality_eval_case_id, case_id)
    |> Map.put(
      :fanout_deadline_unix_ms,
      System.system_time(:millisecond) + row_timeout_ms
    )
    |> Map.put(
      :fanout_worker_deadline_monotonic_ms,
      deadline_monotonic_ms
    )
    |> Map.put(:model_max_output_tokens, 512)
  end

  defp stats(profile, fixture_sha256, scenarios, rows) do
    scenario_rows = Enum.zip(scenarios, rows)
    required_change_rows = count_change_rows(scenario_rows, "required", nil)
    required_change_rows_changed = count_change_rows(scenario_rows, "required", true)

    %{
      profile: profile,
      fixture_sha256: fixture_sha256,
      worker_quality_rows: length(rows),
      worker_quality_rows_passed: Enum.count(rows, & &1.passed?),
      accepted_rows: Enum.count(rows, &(&1.verdict == "accepted")),
      unresolved_rows: Enum.count(rows, &(&1.verdict == "unresolved")),
      protocol_provider_call_count: Enum.sum(Enum.map(rows, & &1.provider_call_count)),
      configured_reviewer_invocation_count:
        Enum.sum(Enum.map(rows, & &1.configured_reviewer_invocation_count)),
      required_change_rows: required_change_rows,
      required_change_rows_changed: required_change_rows_changed,
      optional_change_rows_changed: count_change_rows(scenario_rows, "allowed", true),
      required_changes_closed: required_change_rows_changed == required_change_rows,
      rule_catalog_version: QualityPolicy.version(),
      rule_count: length(QualityPolicy.rule_ids()),
      rule_evidence_closed: Enum.all?(rows, & &1.rule_evidence_closed)
    }
  end

  defp count_change_rows(scenario_rows, requirement, changed?) do
    Enum.count(scenario_rows, fn {scenario, row} ->
      scenario["expected"]["answer_change"] == requirement and
        (is_nil(changed?) or row.answer_changed == changed?)
    end)
  end

  defp validated_fixture_sha256!(fixture) do
    digest = fixture_sha256(fixture)

    if valid_fixture?(fixture) and digest == @fixture_sha256,
      do: digest,
      else: raise("invalid v1.3 fan-out worker-quality fixture digest")
  end

  defp valid_fixture?(fixture) do
    scenarios = fixture["scenarios"]

    exact_keys?(fixture, @fixture_keys) and fixture["schema_version"] == 1 and
      fixture["corpus_id"] == @corpus_id and safe_identifier?(fixture["corpus_id"]) and
      is_list(scenarios) and
      Enum.all?(scenarios, &is_map/1) and Enum.map(scenarios, & &1["id"]) == @scenario_ids and
      Enum.all?(scenarios, &valid_scenario?/1)
  end

  defp valid_scenario?(scenario) do
    exact_keys?(scenario, @scenario_keys) and safe_identifier?(scenario["id"]) and
      nonempty?(scenario["draft"]) and
      valid_task?(scenario["task"]) and valid_expected?(scenario["expected"])
  end

  defp valid_task?(task) do
    exact_keys?(task, @task_keys) and
      task["source"] in ~w[conversation_manager counted_protocol] and
      Enum.all?(~w[original_request child_objective expected_result], &nonempty?(task[&1])) and
      match?({:ok, _contract}, quality_contract(%{"task" => task}))
  end

  defp valid_expected?(expected) do
    exact_keys?(expected, @expected_keys) and expected["verdict"] in ~w[accepted unresolved] and
      expected["provider_call_count"] == 2 and
      expected["answer_change"] in ~w[required allowed] and
      valid_expected_failures?(expected["verdict"], expected["required_failed_rule_ids"])
  end

  defp valid_expected_failures?("accepted", []), do: true

  defp valid_expected_failures?("unresolved", [_first | _rest] = failed_rule_ids) do
    failed_rule_ids == Enum.filter(QualityPolicy.rule_ids(), &(&1 in failed_rule_ids))
  end

  defp valid_expected_failures?(_verdict, _failed_rule_ids), do: false

  defp exact_keys?(map, keys) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_map, _keys), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp safe_identifier?(value), do: is_binary(value) and Regex.match?(@safe_identifier, value)

  defp bounded_row_timeout(timeout) when is_integer(timeout) and timeout > 0,
    do: min(timeout, @maximum_row_timeout_ms)

  defp bounded_row_timeout(_timeout), do: @default_row_timeout_ms

  defp profile_name(value) when is_binary(value), do: value
  defp profile_name(value) when is_map(value), do: Map.get(value, :name) || Map.get(value, "name")
  defp short_sha(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_sha(_value), do: nil

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp sha256?(_value), do: false

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
