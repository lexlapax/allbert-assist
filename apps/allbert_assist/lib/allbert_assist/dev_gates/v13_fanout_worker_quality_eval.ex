defmodule AllbertAssist.DevGates.V13FanoutWorkerQualityEval do
  @moduledoc """
  Content-safe Worker semantic-quality qualification for the v1.3 fan-out gate.

  The frozen matrix supplies logical draft call one, then this gate drives the
  production phase-separated Worker state machine: two initial critics, at most
  one revision through the registered DirectAnswer action, and two fresh final
  critics when revision was required. A first-pass acceptance is exactly three
  calls; a revised acceptance or unresolved result is exactly six calls.

  Raw task text, candidates, critic assessments, source handles, and model output
  stay transient. TestMetrics receives only validated content-free digests,
  closed phase cardinalities, call arithmetic, verdicts, receipt versions, and
  failure classifications. This development tool grants no runtime authority
  and does not replace Worker lifecycle tests or attended semantic judgment.
  """

  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.{ReqLLMCritic, ReviewProtocol}
  alias AllbertAssist.Objectives.Runs.Worker.Agent, as: WorkerAgent
  alias AllbertAssist.Objectives.Runs.Worker.Commands.{ReviewRound, Revise}
  alias AllbertAssist.Objectives.Runs.Worker.{QualityPolicy, QualityReceipt}

  @scenario_ids [
    "restart-inaccuracy-repaired",
    "replay-guarantee-overclaim-repaired",
    "omitted-required-nuance-unresolved",
    "accurate-paraphrase-accepted",
    "unrelated-domain-accepted"
  ]
  @corpus_id "v13-fanout-worker-quality-real-model-v1"
  @fixture_sha256 "a482d406a5037b66e31b8d9fd91b2435b7ef7aa0985221aced5b338558ffbd83"
  @safe_identifier ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @fixture_keys ~w[schema_version corpus_id scenarios]
  @scenario_keys ~w[id task draft expected]
  @task_keys ~w[source original_request child_objective expected_result]
  @expected_keys ~w[
    verdict provider_call_count answer_change initial_failed_rule_ids final_failed_rule_ids
  ]
  @failure_stages ~w[none initial_review revision final_review deadline fixture_expectation]
  @failure_reasons ~w[
    none initial_review_failed revision_failed final_review_failed row_timeout
    invalid_worker_state invalid_quality_receipt verdict_mismatch provider_call_count_mismatch
    initial_failed_rules_mismatch final_failed_rules_mismatch answer_change_mismatch
  ]
  @default_row_timeout_ms 30_000
  @maximum_row_timeout_ms 120_000
  @reviewer_config_aggregate_domain "allbert:fanout-reviewer-config-aggregate:v1\0"
  @fanout_worker_policy %{
    version: 1,
    provider_failover: :disabled,
    conversation_fanout: :disabled
  }

  @type result :: %{
          status: String.t(),
          stats: map(),
          failed_rows: [String.t()],
          rows: [map()]
        }

  defmodule RecordingCritic do
    @moduledoc false

    alias AllbertAssist.Objectives.Fanout.ReqLLMCritic

    @doc false
    def assess(request, context) when is_map(request) and is_map(context) do
      implementation = Map.get(context, :quality_eval_critic_implementation, ReqLLMCritic)
      owner = Map.fetch!(context, :quality_eval_owner)
      ref = Map.fetch!(context, :quality_eval_ref)
      phase = Map.fetch!(context, :fanout_review_phase)
      group_id = get_in(request, ["group", "id"])

      send(owner, {:quality_eval_critic_started, ref, phase, group_id})

      result =
        if implementation == __MODULE__,
          do: {:error, :invalid_quality_eval_critic},
          else: implementation.assess(request, context)

      send(owner, {:quality_eval_critic_result, ref, phase, group_id, result})
      result
    end

    def assess(_request, _context), do: {:error, :invalid_quality_eval_critic}
  end

  @doc "Load and validate the frozen task-neutral Worker-quality matrix."
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

  @doc "Return the SHA-256 of the canonical decoded Worker-quality fixture."
  @spec fixture_sha256(map()) :: String.t()
  def fixture_sha256(fixture) when is_map(fixture),
    do: sha256(CanonicalJSON.encode(fixture))

  @doc "Evaluate the matrix and append one content-free phase record."
  @spec run(map(), keyword()) :: result()
  def run(fixture, opts) when is_map(fixture) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    fixture_sha256 = validated_fixture_sha256!(fixture)
    critic = Keyword.get(opts, :critic, ReqLLMCritic)
    runner_context = Keyword.get(opts, :runner_context, %{})
    row_timeout_ms = bounded_row_timeout(Keyword.get(opts, :row_timeout_ms))
    row_monotonic_now = row_monotonic_now(opts)

    rows =
      Enum.map(fixture["scenarios"], fn scenario ->
        evaluate_scenario(
          scenario,
          critic,
          runner_context,
          row_timeout_ms,
          row_monotonic_now
        )
      end)

    failed_rows = for %{passed?: false, id: id} <- rows, do: id
    status = if failed_rows == [], do: "passed", else: "failed"
    profile = opts |> Keyword.fetch!(:profile) |> profile_name()

    stats =
      profile
      |> stats(fixture_sha256, fixture["scenarios"], rows)
      |> Map.put(:role_profile_bindings, Keyword.get(opts, :role_profile_bindings, %{}))

    TestMetrics.record(%{
      store: Keyword.get(opts, :store),
      git_sha: opts |> Keyword.get(:full_sha) |> short_sha(),
      full_sha: Keyword.get(opts, :full_sha),
      dirty: Keyword.get(opts, :dirty),
      cwd: "apps/allbert_assist",
      gate: "bench-v13-fanout",
      phase_or_step: "worker-quality",
      corpus_id: fixture["corpus_id"],
      command: Keyword.get(opts, :command, "bench-v13-fanout --profile #{profile}"),
      status: status,
      wall_ms: System.monotonic_time(:millisecond) - started,
      stats: stats
    })

    %{status: status, stats: stats, failed_rows: failed_rows, rows: rows}
  end

  @doc "Render the content-free Worker-quality phase summary."
  @spec summary(result()) :: String.t()
  def summary(%{status: status, stats: stats}) do
    "v13-fanout-worker-quality status=#{status} " <>
      "rows=#{stats.worker_quality_rows_passed}/#{stats.worker_quality_rows} " <>
      "protocol_calls=#{stats.protocol_provider_call_count} " <>
      "critic_invocations=#{stats.configured_critic_invocation_count} " <>
      "revision_invocations=#{stats.configured_revision_invocation_count} " <>
      "phases_closed=#{stats.phase_evidence_closed}" <>
      role_profile_summary(stats.role_profile_bindings)
  end

  defp role_profile_summary(bindings) when map_size(bindings) == 4 do
    " profiles " <>
      Enum.map_join(~w[worker manager review synthesis], " ", fn role ->
        binding = Map.fetch!(bindings, role)

        "#{role}=#{binding.profile}|#{binding.provider}|#{binding.model}|" <>
          "#{binding.endpoint_class}|#{binding.endpoint_sha256}|#{binding.configuration_sha256}"
      end)
  end

  defp role_profile_summary(_bindings), do: ""

  defp evaluate_scenario(scenario, critic, base_context, row_timeout_ms, monotonic_now) do
    deadline_monotonic_ms = monotonic_now.() + row_timeout_ms

    task =
      Task.async(fn ->
        execute_scenario(
          scenario,
          critic,
          base_context,
          row_timeout_ms,
          deadline_monotonic_ms
        )
      end)

    remaining_ms = deadline_monotonic_ms - monotonic_now.()

    await_scenario(task, scenario, remaining_ms, deadline_monotonic_ms, monotonic_now)
  end

  defp await_scenario(task, scenario, remaining_ms, deadline_monotonic_ms, monotonic_now)
       when remaining_ms > 0 do
    case Task.yield(task, remaining_ms) do
      {:ok, row} -> timely_row(row, scenario, deadline_monotonic_ms, monotonic_now)
      {:exit, _reason} -> invalid_worker_state_row(scenario)
      nil -> stop_timed_out_scenario(task, scenario)
    end
  end

  defp await_scenario(task, scenario, _remaining_ms, _deadline, _monotonic_now),
    do: stop_timed_out_scenario(task, scenario)

  defp timely_row(row, scenario, deadline_monotonic_ms, monotonic_now) do
    if monotonic_now.() < deadline_monotonic_ms,
      do: row,
      else: deadline_row(scenario)
  end

  defp invalid_worker_state_row(scenario),
    do: invalid_row(scenario["id"], nil, 0, 0, 0, 0, "deadline", "invalid_worker_state")

  defp stop_timed_out_scenario(task, scenario) do
    _ = Task.shutdown(task, :brutal_kill)
    deadline_row(scenario)
  end

  defp deadline_row(scenario),
    do: invalid_row(scenario["id"], nil, 0, 0, 0, 0, "deadline", "row_timeout")

  defp execute_scenario(
         scenario,
         critic,
         base_context,
         row_timeout_ms,
         deadline_monotonic_ms
       ) do
    with {:ok, contract} <- quality_contract(scenario),
         {:ok, contract_sha256} <- QualityPolicy.digest(contract),
         {:ok, protocol} <- QualityPolicy.review_protocol() do
      context =
        scenario_context(
          base_context,
          scenario["id"],
          critic,
          row_timeout_ms,
          deadline_monotonic_ms
        )

      agent =
        WorkerAgent.new(
          id: "quality-eval-#{scenario["id"]}",
          state:
            initial_state(
              scenario,
              contract,
              contract_sha256,
              Map.get(base_context, :quality_eval_worker_profile)
            )
        )

      {agent, initial_evidence} = run_review_phase(agent, :initial, protocol, context)
      continue_scenario(scenario, agent, initial_evidence, protocol, context)
    else
      _invalid ->
        invalid_row(
          scenario["id"],
          1,
          0,
          0,
          0,
          0,
          "initial_review",
          "invalid_worker_state"
        )
    end
  end

  defp continue_scenario(
         scenario,
         %{state: %{status: :accepted}} = agent,
         initial_evidence,
         _protocol,
         _context
       ) do
    accepted_row(scenario, agent.state, initial_evidence, nil)
  end

  defp continue_scenario(
         scenario,
         %{state: %{status: :revision_required}} = agent,
         initial_evidence,
         protocol,
         context
       ) do
    {agent, _directives} =
      WorkerAgent.cmd(
        agent,
        {Revise, %{runner_context: context}},
        timeout: 0,
        max_retries: 0,
        __jido_instance__: AllbertAssist.Jido
      )

    case agent.state do
      %{status: :revised} ->
        {agent, final_evidence} = run_review_phase(agent, :final, protocol, context)
        terminal_row(scenario, agent.state, initial_evidence, final_evidence)

      state ->
        invalid_state_row(
          scenario["id"],
          state,
          initial_evidence,
          nil,
          "revision",
          "revision_failed"
        )
    end
  end

  defp continue_scenario(
         scenario,
         %{state: state},
         initial_evidence,
         _protocol,
         _context
       ) do
    invalid_state_row(
      scenario["id"],
      state,
      initial_evidence,
      nil,
      "initial_review",
      "initial_review_failed"
    )
  end

  defp terminal_row(scenario, %{status: :accepted} = state, initial, final),
    do: accepted_row(scenario, state, initial, final)

  defp terminal_row(
         scenario,
         %{status: :unresolved, error: :quality_review_unresolved} = state,
         initial,
         %{closed?: true} = final
       ) do
    case worker_protocol_evidence(initial, final, false) do
      {:ok, protocol_evidence} ->
        reviewed_row(
          scenario,
          state,
          initial,
          final,
          "unresolved",
          final.failed_rule_ids,
          nil,
          protocol_evidence
        )

      {:error, _reason} ->
        invalid_state_row(
          scenario["id"],
          state,
          initial,
          final,
          "final_review",
          "invalid_quality_receipt"
        )
    end
  end

  defp terminal_row(scenario, state, initial, final) do
    invalid_state_row(
      scenario["id"],
      state,
      initial,
      final,
      "final_review",
      "final_review_failed"
    )
  end

  defp accepted_row(scenario, state, initial, final) do
    with %{} = receipt <- Map.get(state, :quality_receipt),
         2 <- receipt["version"],
         {:ok, protocol_evidence} <- worker_protocol_evidence(initial, final, true),
         :ok <-
           QualityReceipt.validate_current(
             receipt,
             receipt_validation_binding(state, protocol_evidence)
           ),
         true <- receipt_phase_shape?(receipt, initial, final) do
      reviewed_row(
        scenario,
        state,
        initial,
        final,
        "accepted",
        [],
        receipt,
        protocol_evidence
      )
    else
      _invalid ->
        invalid_state_row(
          scenario["id"],
          state,
          initial,
          final,
          if(final, do: "final_review", else: "initial_review"),
          "invalid_quality_receipt"
        )
    end
  end

  defp reviewed_row(
         scenario,
         state,
         initial,
         final,
         verdict,
         failed_rule_ids,
         receipt,
         protocol_evidence
       ) do
    answer = Map.get(state, :final_answer) || get_in(state, [:revised_response, :message])
    answer_changed = is_binary(answer) and answer != scenario["draft"]
    evidence_closed = phase_evidence_closed?(initial, final, state.provider_call_count)

    revision_model_profile = revision_model_profile(state, final)

    revision_profile_closed =
      is_nil(state.expected_worker_profile) or is_nil(final) or
        revision_model_profile == state.expected_worker_profile

    evidence = %{
      verdict: verdict,
      provider_call_count: state.provider_call_count,
      failed_rule_ids: failed_rule_ids,
      initial_failed_rule_ids: protocol_evidence.initial_failed_rule_ids,
      final_failed_rule_ids: protocol_evidence.final_failed_rule_ids,
      answer_changed: answer_changed
    }

    {failure_stage, failure_reason} =
      reviewed_row_failure(
        evidence,
        scenario["expected"],
        evidence_closed,
        revision_profile_closed
      )

    %{
      id: scenario["id"],
      passed?: failure_stage == "none",
      verdict: verdict,
      provider_call_count: state.provider_call_count,
      draft_call_count: 1,
      initial_critic_call_count: initial.invocation_count,
      revision_call_count: if(final, do: 1, else: 0),
      final_critic_call_count: evidence_value(final, :invocation_count, 0),
      revision_used: not is_nil(final),
      critic_group_count: protocol_evidence.critic_group_count,
      review_protocol_version: protocol_evidence.review_protocol_version,
      rule_group_catalog_version: protocol_evidence.rule_group_catalog_version,
      rule_group_catalog_sha256: protocol_evidence.rule_group_catalog_sha256,
      reviewer_config_sha256: protocol_evidence.reviewer_config_sha256,
      initial_assessment_sha256: protocol_evidence.initial_assessment_sha256,
      final_assessment_sha256: protocol_evidence.final_assessment_sha256,
      accepted_assessment_sha256: protocol_evidence.accepted_assessment_sha256,
      configured_critic_invocation_count:
        initial.invocation_count + evidence_value(final, :invocation_count, 0),
      configured_revision_invocation_count:
        if(state.provider_call_count in [4, 5, 6], do: 1, else: 0),
      revision_model_profile: revision_model_profile,
      initial_critic_group_count: initial.group_count,
      final_critic_group_count: evidence_value(final, :group_count, 0),
      receipt_version: receipt && receipt["version"],
      failed_rule_count: length(failed_rule_ids),
      initial_failed_rule_count: length(protocol_evidence.initial_failed_rule_ids),
      final_failed_rule_count: count_or_nil(protocol_evidence.final_failed_rule_ids),
      rule_evidence_closed: evidence_closed,
      answer_changed: answer_changed,
      failure_stage: failure_stage,
      failure_reason: failure_reason
    }
  end

  defp revision_model_profile(_state, nil), do: nil

  defp revision_model_profile(state, _final) do
    response =
      Map.get(state, :revised_response) ||
        case Map.get(state, :last_result) do
          {:ok, %{response: response}} -> response
          _other -> %{}
        end

    get_in(response, [:direct_answer, :model_profile])
  end

  defp reviewed_row_failure(_evidence, _expected, _evidence_closed, false),
    do: {"revision", "revision_failed"}

  defp reviewed_row_failure(_evidence, _expected, false, true),
    do: {"final_review", "final_review_failed"}

  defp reviewed_row_failure(evidence, expected, true, true),
    do: expectation_failure(evidence, expected)

  defp invalid_state_row(id, state, initial, final, stage, reason) do
    invalid_row(
      id,
      Map.get(state, :provider_call_count),
      initial.invocation_count + evidence_value(final, :invocation_count, 0),
      if(Map.get(state, :provider_call_count) in [4, 5, 6], do: 1, else: 0),
      initial.group_count,
      evidence_value(final, :group_count, 0),
      stage,
      reason
    )
  end

  defp invalid_row(
         id,
         provider_call_count,
         critic_invocations,
         revision_invocations,
         initial_group_count,
         final_group_count,
         failure_stage,
         failure_reason
       )
       when failure_stage in @failure_stages and failure_reason in @failure_reasons do
    %{
      id: id,
      passed?: false,
      verdict: "invalid",
      provider_call_count: provider_call_count,
      draft_call_count: nil,
      initial_critic_call_count: nil,
      revision_call_count: nil,
      final_critic_call_count: nil,
      revision_used: nil,
      critic_group_count: nil,
      review_protocol_version: nil,
      rule_group_catalog_version: nil,
      rule_group_catalog_sha256: nil,
      reviewer_config_sha256: nil,
      initial_assessment_sha256: nil,
      final_assessment_sha256: nil,
      accepted_assessment_sha256: nil,
      configured_critic_invocation_count: critic_invocations,
      configured_revision_invocation_count: revision_invocations,
      revision_model_profile: nil,
      initial_critic_group_count: initial_group_count,
      final_critic_group_count: final_group_count,
      receipt_version: nil,
      failed_rule_count: 0,
      initial_failed_rule_count: nil,
      final_failed_rule_count: nil,
      rule_evidence_closed: false,
      answer_changed: false,
      failure_stage: failure_stage,
      failure_reason: failure_reason
    }
  end

  defp run_review_phase(agent, phase, protocol, context) do
    candidate = phase_candidate(agent.state, phase)
    ref = make_ref()

    runner_context =
      context
      |> Map.put(:quality_eval_owner, self())
      |> Map.put(:quality_eval_ref, ref)

    {agent, _directives} =
      WorkerAgent.cmd(
        agent,
        {ReviewRound,
         %{
           phase: phase,
           critic: RecordingCritic,
           runner_context: runner_context
         }},
        timeout: 0,
        max_retries: 0,
        __jido_instance__: AllbertAssist.Jido
      )

    messages = drain_phase_messages(ref, phase, [])
    {agent, phase_evidence(protocol, agent.state.task_contract, candidate, messages)}
  end

  defp drain_phase_messages(ref, phase, messages) do
    receive do
      {:quality_eval_critic_started, ^ref, ^phase, group_id} ->
        drain_phase_messages(ref, phase, [{:started, group_id} | messages])

      {:quality_eval_critic_result, ^ref, ^phase, group_id, result} ->
        drain_phase_messages(ref, phase, [{:result, group_id, result} | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp phase_evidence(protocol, contract, candidate, messages) do
    started = for {:started, group_id} <- messages, do: group_id

    results =
      for {:result, group_id,
           {:ok,
            %{
              assessment: %{} = assessment,
              reviewer_config_sha256: reviewer_config_sha256
            }}} <- messages,
          is_binary(group_id),
          is_binary(reviewer_config_sha256),
          do: %{
            group_id: group_id,
            assessment: assessment,
            reviewer_config_sha256: reviewer_config_sha256
          }

    validated = validated_phase_evidence(protocol, contract, candidate, results)

    %{
      invocation_count: length(started),
      group_count: validated_value(validated, :critic_group_count, 0),
      closed?: match?({:ok, _review}, validated),
      failed_rule_ids:
        case validated do
          {:ok, review} -> review.revision_rule_ids
          _invalid -> []
        end,
      review_protocol_version: validated_value(validated, :review_protocol_version, nil),
      rule_group_catalog_version: validated_value(validated, :rule_group_catalog_version, nil),
      rule_group_catalog_sha256: validated_value(validated, :rule_group_catalog_sha256, nil),
      reviewer_config_sha256: validated_value(validated, :reviewer_config_sha256, nil),
      assessment_sha256: validated_value(validated, :assessment_sha256, nil)
    }
  end

  defp validated_phase_evidence(protocol, contract, candidate, results) do
    with {:ok, review} <- merge_phase_evidence(protocol, contract, candidate, results),
         {:ok, reviewer_config_sha256} <- reviewer_config_sha256(protocol, results),
         review <-
           review
           |> Map.put(:reviewer_config_sha256, reviewer_config_sha256)
           |> Map.put(:provider_call_count, 2),
         :ok <-
           QualityPolicy.validate_phase_review(
             contract,
             candidate,
             review,
             reviewer_config_sha256
           ) do
      {:ok, review}
    else
      _invalid -> {:error, :invalid_quality_phase_evidence}
    end
  end

  defp merge_phase_evidence(protocol, contract, candidate, results)
       when is_binary(candidate) and length(results) == 2 do
    with true <-
           Enum.sort(Enum.map(results, & &1.group_id)) ==
             Enum.sort(ReviewProtocol.group_ids(protocol)),
         {:ok, source_bindings} <-
           ReviewProtocol.bind_sources(
             %{"task_contract" => CanonicalJSON.encode(contract)},
             candidate
           ),
         {:ok, review} <-
           ReviewProtocol.merge(protocol, Enum.map(results, & &1.assessment), source_bindings) do
      {:ok, review}
    else
      _invalid -> {:error, :invalid_quality_phase_evidence}
    end
  end

  defp merge_phase_evidence(_protocol, _contract, _candidate, _results),
    do: {:error, :invalid_quality_phase_evidence}

  defp reviewer_config_sha256(protocol, results) do
    by_group = Map.new(results, &{&1.group_id, &1})

    with true <- map_size(by_group) == length(results),
         ordered <- Enum.map(ReviewProtocol.group_ids(protocol), &Map.fetch!(by_group, &1)),
         true <- Enum.all?(ordered, &lowercase_sha256?(&1.reviewer_config_sha256)) do
      input = %{
        "review_protocol_version" => protocol.review_protocol_version,
        "rule_group_catalog_version" => protocol.rule_group_catalog_version,
        "rule_group_catalog_sha256" => protocol.rule_group_catalog_sha256,
        "critics" =>
          Enum.map(ordered, fn result ->
            %{
              "group_id" => result.group_id,
              "reviewer_config_sha256" => result.reviewer_config_sha256
            }
          end)
      }

      {:ok, sha256(@reviewer_config_aggregate_domain <> CanonicalJSON.encode(input))}
    else
      _invalid -> {:error, :invalid_quality_reviewer_config}
    end
  end

  defp worker_protocol_evidence(initial, final, accepted?) when is_boolean(accepted?) do
    with true <- valid_closed_phase?(initial),
         true <- is_nil(final) or valid_closed_phase?(final),
         true <- is_nil(final) or same_protocol?(initial, final),
         {:ok, reviewer_config_sha256} <-
           QualityPolicy.reviewer_config_set_sha256(
             initial.reviewer_config_sha256,
             evidence_value(final, :reviewer_config_sha256, nil)
           ) do
      revision_used = not is_nil(final)
      final_assessment_sha256 = evidence_value(final, :assessment_sha256, nil)

      {:ok,
       %{
         review_protocol_version: initial.review_protocol_version,
         critic_group_count: initial.group_count,
         rule_group_catalog_version: initial.rule_group_catalog_version,
         rule_group_catalog_sha256: initial.rule_group_catalog_sha256,
         reviewer_config_sha256: reviewer_config_sha256,
         draft_call_count: 1,
         initial_critic_call_count: initial.invocation_count,
         revision_call_count: if(revision_used, do: 1, else: 0),
         final_critic_call_count: evidence_value(final, :invocation_count, 0),
         provider_call_count:
           1 + initial.invocation_count + if(revision_used, do: 1, else: 0) +
             evidence_value(final, :invocation_count, 0),
         initial_assessment_sha256: initial.assessment_sha256,
         final_assessment_sha256: final_assessment_sha256,
         initial_failed_rule_ids: initial.failed_rule_ids,
         final_failed_rule_ids: evidence_value(final, :failed_rule_ids, nil),
         accepted_assessment_sha256:
           if(accepted?, do: final_assessment_sha256 || initial.assessment_sha256, else: nil),
         verdict: if(accepted?, do: "accepted", else: "unresolved"),
         failed_rule_ids: if(accepted?, do: [], else: evidence_value(final, :failed_rule_ids, []))
       }}
    else
      _invalid -> {:error, :invalid_quality_phase_evidence}
    end
  end

  defp valid_closed_phase?(phase) do
    phase.closed? and phase.invocation_count == 2 and phase.group_count == 2 and
      phase.review_protocol_version == 1 and phase.rule_group_catalog_version == 1 and
      lowercase_sha256?(phase.rule_group_catalog_sha256) and
      lowercase_sha256?(phase.reviewer_config_sha256) and
      lowercase_sha256?(phase.assessment_sha256)
  end

  defp same_protocol?(initial, final) do
    Map.take(initial, [
      :review_protocol_version,
      :group_count,
      :rule_group_catalog_version,
      :rule_group_catalog_sha256
    ]) ==
      Map.take(final, [
        :review_protocol_version,
        :group_count,
        :rule_group_catalog_version,
        :rule_group_catalog_sha256
      ])
  end

  defp receipt_validation_binding(state, evidence) do
    %{
      objective_id: state.objective_id,
      step_id: state.step_id,
      task_contract_sha256: state.task_contract_sha256,
      final_answer: state.final_answer,
      review_protocol_version: evidence.review_protocol_version,
      critic_group_count: evidence.critic_group_count,
      rule_group_catalog_version: evidence.rule_group_catalog_version,
      rule_group_catalog_sha256: evidence.rule_group_catalog_sha256,
      reviewer_config_sha256: evidence.reviewer_config_sha256,
      draft_call_count: evidence.draft_call_count,
      initial_critic_call_count: evidence.initial_critic_call_count,
      revision_call_count: evidence.revision_call_count,
      final_critic_call_count: evidence.final_critic_call_count,
      provider_call_count: evidence.provider_call_count,
      initial_assessment_sha256: evidence.initial_assessment_sha256,
      final_assessment_sha256: evidence.final_assessment_sha256,
      accepted_assessment_sha256: evidence.accepted_assessment_sha256,
      verdict: evidence.verdict,
      failed_rule_ids: evidence.failed_rule_ids
    }
  end

  defp receipt_phase_shape?(receipt, initial, nil),
    do:
      initial.closed? and initial.group_count == 2 and
        receipt["draft_call_count"] == 1 and receipt["initial_critic_call_count"] == 2 and
        receipt["revision_call_count"] == 0 and receipt["final_critic_call_count"] == 0 and
        receipt["provider_call_count"] == 3

  defp receipt_phase_shape?(receipt, initial, final),
    do:
      initial.closed? and final.closed? and initial.group_count == 2 and final.group_count == 2 and
        receipt["draft_call_count"] == 1 and receipt["initial_critic_call_count"] == 2 and
        receipt["revision_call_count"] == 1 and receipt["final_critic_call_count"] == 2 and
        receipt["provider_call_count"] == 6

  defp phase_evidence_closed?(initial, nil, 3), do: initial.closed? and initial.group_count == 2

  defp phase_evidence_closed?(initial, final, 6),
    do: initial.closed? and final.closed? and initial.group_count == 2 and final.group_count == 2

  defp phase_evidence_closed?(_initial, _final, _provider_call_count), do: false

  defp expectation_failure(evidence, expected) do
    cond do
      evidence.verdict != expected["verdict"] ->
        {"fixture_expectation", "verdict_mismatch"}

      evidence.provider_call_count != expected["provider_call_count"] ->
        {"fixture_expectation", "provider_call_count_mismatch"}

      evidence.initial_failed_rule_ids != expected["initial_failed_rule_ids"] ->
        {"fixture_expectation", "initial_failed_rules_mismatch"}

      evidence.final_failed_rule_ids != expected["final_failed_rule_ids"] ->
        {"fixture_expectation", "final_failed_rules_mismatch"}

      not answer_change_valid?(evidence.answer_changed, expected["answer_change"]) ->
        {"fixture_expectation", "answer_change_mismatch"}

      true ->
        {"none", "none"}
    end
  end

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

  defp initial_state(scenario, contract, contract_sha256, expected_worker_profile) do
    %{
      status: :draft,
      objective_id: "quality-eval-objective-#{scenario["id"]}",
      step_id: "quality-eval-step-#{scenario["id"]}",
      provider_call_count: 1,
      task_contract: contract,
      task_contract_sha256: contract_sha256,
      expected_worker_profile: expected_worker_profile,
      draft_response: %{
        message: scenario["draft"],
        direct_answer: %{source: :model}
      },
      last_command: :execute,
      last_result: {:ok, :draft}
    }
  end

  defp phase_candidate(%{draft_response: %{message: candidate}}, :initial), do: candidate
  defp phase_candidate(%{revised_response: %{message: candidate}}, :final), do: candidate
  defp phase_candidate(_state, _phase), do: nil

  defp scenario_context(
         base,
         case_id,
         critic,
         row_timeout_ms,
         deadline_monotonic_ms
       )
       when is_map(base) and is_atom(critic) do
    base
    |> Map.put(:quality_eval_case_id, case_id)
    |> Map.put(:quality_eval_critic_implementation, critic)
    |> Map.put(:fanout_deadline_unix_ms, System.system_time(:millisecond) + row_timeout_ms)
    |> Map.put(:fanout_worker_deadline_monotonic_ms, deadline_monotonic_ms)
    |> Map.put(:fanout_review_deadline_monotonic_ms, deadline_monotonic_ms)
    |> Map.put(:fanout_worker_policy, @fanout_worker_policy)
    |> Map.put(:model_max_output_tokens, 512)
    |> Map.put(:model_timeout_ms, row_timeout_ms)
    |> Map.put(:model_max_retries, 0)
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
      protocol_provider_call_count:
        rows
        |> Enum.map(& &1.provider_call_count)
        |> Enum.filter(&is_integer/1)
        |> Enum.sum(),
      provider_call_count_closed: Enum.all?(rows, &is_integer(&1.provider_call_count)),
      configured_critic_invocation_count:
        Enum.sum(Enum.map(rows, & &1.configured_critic_invocation_count)),
      configured_revision_invocation_count:
        Enum.sum(Enum.map(rows, & &1.configured_revision_invocation_count)),
      required_change_rows: required_change_rows,
      required_change_rows_changed: required_change_rows_changed,
      optional_change_rows_changed: count_change_rows(scenario_rows, "allowed", true),
      required_changes_closed: required_change_rows_changed == required_change_rows,
      rule_catalog_version: QualityPolicy.version(),
      rule_count: length(QualityPolicy.rule_ids()),
      phase_evidence_closed: Enum.all?(rows, & &1.rule_evidence_closed),
      rule_evidence_closed: Enum.all?(rows, & &1.rule_evidence_closed),
      worker_quality_failure_stage_by_row: row_map(rows, :failure_stage),
      worker_quality_failure_reason_by_row: row_map(rows, :failure_reason),
      worker_quality_verdict_by_row: row_map(rows, :verdict),
      worker_quality_provider_call_count_by_row: row_map(rows, :provider_call_count),
      worker_quality_draft_call_count_by_row: row_map(rows, :draft_call_count),
      worker_quality_initial_critic_call_count_by_row: row_map(rows, :initial_critic_call_count),
      worker_quality_revision_call_count_by_row: row_map(rows, :revision_call_count),
      worker_quality_final_critic_call_count_by_row: row_map(rows, :final_critic_call_count),
      worker_quality_revision_used_by_row: row_map(rows, :revision_used),
      worker_quality_revision_model_profile_by_row: row_map(rows, :revision_model_profile),
      worker_quality_critic_group_count_by_row: row_map(rows, :critic_group_count),
      worker_quality_review_protocol_version_by_row: row_map(rows, :review_protocol_version),
      worker_quality_rule_group_catalog_version_by_row:
        row_map(rows, :rule_group_catalog_version),
      worker_quality_rule_group_catalog_sha256_by_row: row_map(rows, :rule_group_catalog_sha256),
      worker_quality_reviewer_config_sha256_by_row: row_map(rows, :reviewer_config_sha256),
      worker_quality_initial_assessment_sha256_by_row: row_map(rows, :initial_assessment_sha256),
      worker_quality_final_assessment_sha256_by_row: row_map(rows, :final_assessment_sha256),
      worker_quality_accepted_assessment_sha256_by_row:
        row_map(rows, :accepted_assessment_sha256),
      worker_quality_failed_rule_count_by_row: row_map(rows, :failed_rule_count),
      worker_quality_initial_failed_rule_count_by_row: row_map(rows, :initial_failed_rule_count),
      worker_quality_final_failed_rule_count_by_row: row_map(rows, :final_failed_rule_count),
      worker_quality_initial_critic_group_count_by_row:
        row_map(rows, :initial_critic_group_count),
      worker_quality_final_critic_group_count_by_row: row_map(rows, :final_critic_group_count),
      worker_quality_receipt_version_by_row: row_map(rows, :receipt_version)
    }
  end

  defp row_map(rows, key), do: Map.new(rows, &{&1.id, Map.fetch!(&1, key)})

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

    exact_keys?(fixture, @fixture_keys) and fixture["schema_version"] == 2 and
      fixture["corpus_id"] == @corpus_id and safe_identifier?(fixture["corpus_id"]) and
      is_list(scenarios) and Enum.all?(scenarios, &is_map/1) and
      Enum.map(scenarios, & &1["id"]) == @scenario_ids and
      Enum.all?(scenarios, &valid_scenario?/1)
  end

  defp valid_scenario?(scenario) do
    exact_keys?(scenario, @scenario_keys) and safe_identifier?(scenario["id"]) and
      nonempty?(scenario["draft"]) and valid_task?(scenario["task"]) and
      valid_expected?(scenario["expected"])
  end

  defp valid_task?(task) do
    exact_keys?(task, @task_keys) and
      task["source"] in ~w[conversation_manager counted_protocol] and
      Enum.all?(~w[original_request child_objective expected_result], &nonempty?(task[&1])) and
      match?({:ok, _contract}, quality_contract(%{"task" => task}))
  end

  defp valid_expected?(expected) do
    exact_keys?(expected, @expected_keys) and expected["verdict"] in ~w[accepted unresolved] and
      expected["provider_call_count"] in [3, 6] and
      expected["answer_change"] in ~w[required allowed] and
      valid_expected_failures?(
        expected["verdict"],
        expected["provider_call_count"],
        expected["initial_failed_rule_ids"],
        expected["final_failed_rule_ids"]
      )
  end

  defp valid_expected_failures?("accepted", 3, [], nil), do: true

  defp valid_expected_failures?("accepted", 6, [_first | _rest] = initial, []),
    do: ordered_rule_ids?(initial)

  defp valid_expected_failures?(
         "unresolved",
         6,
         [_first | _rest] = initial,
         [_final_first | _final_rest] = final
       ),
       do: ordered_rule_ids?(initial) and ordered_rule_ids?(final)

  defp valid_expected_failures?(_verdict, _provider_call_count, _initial, _final), do: false

  defp ordered_rule_ids?(rule_ids),
    do: rule_ids == Enum.filter(QualityPolicy.rule_ids(), &(&1 in rule_ids))

  defp exact_keys?(map, keys) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_map, _keys), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp safe_identifier?(value), do: is_binary(value) and Regex.match?(@safe_identifier, value)

  defp bounded_row_timeout(timeout) when is_integer(timeout) and timeout > 0,
    do: min(timeout, @maximum_row_timeout_ms)

  defp bounded_row_timeout(_timeout), do: @default_row_timeout_ms

  defp row_monotonic_now(opts) do
    case Keyword.get(opts, :row_monotonic_now) do
      monotonic_now when is_function(monotonic_now, 0) -> monotonic_now
      nil -> fn -> System.monotonic_time(:millisecond) end
      _invalid -> raise ArgumentError, "row_monotonic_now must be a zero-arity function"
    end
  end

  defp evidence_value(nil, _key, default), do: default
  defp evidence_value(evidence, key, _default), do: Map.fetch!(evidence, key)
  defp count_or_nil(nil), do: nil
  defp count_or_nil(values) when is_list(values), do: length(values)

  defp validated_value({:ok, evidence}, key, default), do: Map.get(evidence, key, default)
  defp validated_value(_invalid, _key, default), do: default

  defp lowercase_sha256?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp profile_name(value) when is_binary(value), do: value
  defp profile_name(value) when is_map(value), do: Map.get(value, :name) || Map.get(value, "name")
  defp short_sha(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_sha(_value), do: nil

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
