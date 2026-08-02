defmodule AllbertAssist.Intent.FanoutManager do
  @moduledoc """
  Conversational planning Interface for one central Runtime turn.

  One DirectAnswer-qualified model call returns a useful answer, bounded
  candidate children, and closed evidence for Allbert's fan-out rules. A
  private Jido Agent owns the assess/adjudicate lifecycle: the model-backed
  assessment is advisory, while the adjudication command applies Allbert's
  deterministic policy and plan compiler locally. A malformed or internally
  inconsistent response may receive one bounded repair call under the same
  monotonic deadline.

  This Interface owns no durable or execution authority. Durable work begins
  only after the caller hands a compiled inert plan to `AllbertAssist.Objectives`;
  model output cannot grant an action, permission, confirmation, identity,
  worker, scheduling, or delivery decision.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.FanoutManager.Agent, as: ManagerAgent
  alias AllbertAssist.Intent.FanoutManager.Commands.{Adjudicate, Assess}
  alias AllbertAssist.Intent.FanoutManager.Policy
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.Fanout.{Budget, RoleProfileConfiguration}
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models
  alias Jido.Agent.Directive.Error, as: JidoErrorDirective

  @default_model_client __MODULE__.ReqLLMImplementation
  @model_config __MODULE__
  @response_keys ~w[
    answer
    outer_request_task_count
    request_ownership
    all_advisory_or_read_only
    children_self_contained
    can_progress_concurrently
    child_result_dependency
    full_coverage_exactly_once
    material_parallel_leverage
    join_role
    children
  ]
  @request_ownership %{
    "no_embedded_content" => :no_embedded_content,
    "transform_supplied_content" => :transform_supplied_content,
    "perform_requested_operations" => :perform_requested_operations
  }
  @join_roles %{
    "none" => :none,
    "parent_presentation_only" => :parent_presentation_only,
    "child_consumes_sibling_result" => :child_consumes_sibling_result
  }
  @max_request_bytes 4_000
  @max_answer_bytes 32_000
  @max_reported_task_count 64
  @type answer_result :: %{
          kind: :answer,
          message: String.t(),
          diagnostic: map()
        }
  @type fanout_result :: %{
          kind: :fanout,
          plan: FanoutPlan.t(),
          fallback_answer: String.t(),
          diagnostic: map()
        }
  @type clarification_result :: %{
          kind: :clarify,
          clarification: map(),
          fallback_answer: String.t(),
          diagnostic: map()
        }
  @type profile_binding :: %{required(String.t()) => term()}

  @spec respond(String.t(), map()) ::
          {:ok, answer_result() | fanout_result() | clarification_result()} | {:error, term()}
  def respond(text, context \\ %{})

  def respond(text, context) when is_binary(text) and is_map(context) do
    {context, provider_attempt_counter} = ProviderAttempt.attach(context)

    with :ok <- validate_request(text),
         :ok <- ensure_model_enabled(context),
         {:ok, profile} <- resolve_manager_profile(context),
         :ok <- authorize_manager_profile(profile, context),
         {:ok, budget_limits} <- Budget.limits(),
         context <- put_plan_deadline(context, profile, budget_limits) do
      assess(text, profile, context, budget_limits, provider_attempt_counter)
    end
  end

  def respond(_text, _context), do: {:error, :invalid_fanout_manager_request}

  @doc "Return a content-free binding for the exact qualified manager profile configuration."
  @spec profile_binding(map()) :: profile_binding()
  def profile_binding(profile) when is_map(profile), do: profile_binding(:fanout_manager, profile)

  @doc false
  @spec profile_binding(atom(), map()) :: profile_binding()
  def profile_binding(role, profile) when is_atom(role) and is_map(profile) do
    {:ok, configuration} =
      @default_model_client.request_configuration(profile, %{
        timeout_ms: Map.get(profile, :timeout_ms, 10_000)
      })

    {:ok, attempt_digest} =
      RoleProfileConfiguration.digest(
        role,
        profile,
        configuration.transport,
        configuration.protocol
      )

    {:ok, configuration_sha256} =
      RoleProfileConfiguration.attempt_set_digest([attempt_digest])

    %{
      "name" => profile_name(profile),
      "configuration_sha256" => configuration_sha256
    }
  end

  @doc "Verify a re-resolved profile against a durable content-free binding."
  @spec profile_matches?(map(), map()) :: boolean()
  def profile_matches?(profile, %{} = binding) when is_map(profile),
    do: profile_binding(profile) == binding

  def profile_matches?(_profile, _binding), do: false

  defp validate_request(text) do
    cond do
      String.trim(text) == "" -> {:error, :invalid_fanout_manager_request}
      byte_size(text) > @max_request_bytes -> {:error, :request_too_large_for_fanout}
      true -> :ok
    end
  end

  defp assess(text, profile, context, budget_limits, provider_attempt_counter) do
    agent = manager_agent()

    {agent, result} =
      run_command(
        agent,
        Assess,
        fn -> call_model(text, profile, context, :initial, 1) end,
        context
      )

    case result do
      {:ok, {response, configuration}} ->
        with {:ok, attempts} <-
               expect_provider_attempts(provider_attempt_counter, 1) do
          flow =
            manager_flow(text, profile, context, budget_limits, provider_attempt_counter, agent)
            |> Map.merge(%{attempts: attempts, configurations: [configuration]})

          adjudicate_initial(response, flow)
        end

      {:error, reason} ->
        preserve_provider_failure(provider_attempt_counter, 0, 1, reason)
    end
  end

  defp adjudicate_initial(response, %{text: text, context: context, agent: agent} = flow) do
    {agent, result} =
      run_command(
        agent,
        Adjudicate,
        fn -> interpret_response(text, response, context) end,
        context
      )

    case result do
      {:ok, {resolved, semantic}} ->
        decorate(resolved, semantic, %{flow | agent: agent})

      {:error, reason} ->
        repair_once(%{
          flow
          | agent: agent,
            initial_answer: usable_answer(response),
            initial_reason: reason
        })
    end
  end

  defp repair_once(
         %{
           text: text,
           profile: profile,
           context: context,
           agent: agent,
           initial_reason: initial_reason
         } = flow
       ) do
    {agent, result} =
      run_command(
        agent,
        Assess,
        fn -> call_model(text, profile, context, {:repair, initial_reason}, 2) end,
        context
      )

    case result do
      {:ok, {repaired_response, repair_configuration}} ->
        with {:ok, attempts} <-
               expect_provider_attempts(flow.provider_attempt_counter, 2) do
          adjudicate_repair(repaired_response, %{
            flow
            | agent: agent,
              attempts: attempts,
              configurations: flow.configurations ++ [repair_configuration]
          })
        end

      {:error, internal_repair_reason} ->
        {repair_reason, repair_configurations} =
          model_call_error(internal_repair_reason, flow.configurations)

        with {:ok, attempts} <-
               bounded_provider_attempts(flow.provider_attempt_counter, 1, 2) do
          retain_answer_or_error(repair_reason, %{
            flow
            | agent: agent,
              attempts: attempts,
              configurations: repair_configurations
          })
        end
    end
  end

  defp adjudicate_repair(
         repaired_response,
         %{text: text, context: context, agent: agent, initial_reason: initial_reason} = flow
       ) do
    {agent, result} =
      run_command(
        agent,
        Adjudicate,
        fn -> interpret_response(text, repaired_response, context) end,
        context
      )

    case result do
      {:ok, {resolved, semantic}} ->
        semantic = Map.put(semantic, :initial_plan_error, initial_reason)

        decorate(resolved, semantic, %{flow | agent: agent})

      {:error, repair_reason} ->
        retain_answer_or_error(repair_reason, %{
          flow
          | agent: agent,
            initial_answer: flow.initial_answer || usable_answer(repaired_response)
        })
    end
  end

  defp retain_answer_or_error(
         repair_reason,
         %{initial_answer: answer, initial_reason: initial_reason} = flow
       )
       when is_binary(answer) do
    result = %{kind: :answer, message: answer}

    semantic = %{
      outcome: :answered_after_invalid_plan,
      policy_outcome: :manager_output_invalid,
      join_role: :none,
      work_unit_count: 0,
      failed_criteria: [],
      reviewed?: false,
      plan_error: initial_reason,
      repair_error: repair_reason
    }

    decorate(result, semantic, flow)
  end

  defp retain_answer_or_error(
         repair_reason,
         %{initial_answer: nil, initial_reason: initial_reason}
       ),
       do: {:error, {:fanout_manager_failed, {initial_reason, repair_reason}}}

  defp interpret_response(text, response, context) do
    with {:ok, object} <- closed_response(response),
         {:ok, answer} <- answer(Map.fetch!(object, "answer")),
         {:ok, criteria} <- rule_evidence(object),
         {:ok, children} <- FanoutPlan.normalize_candidates(Map.fetch!(object, "children")) do
      resolve_policy(text, answer, criteria, children, context)
    end
  end

  defp resolve_policy(text, answer, criteria, children, context) do
    case Policy.decide(criteria, length(children)) do
      {:answer, decision} ->
        result = %{kind: :answer, message: answer}
        {:ok, {result, semantic(decision, length(children))}}

      {:admit, decision} ->
        compile_admitted_plan(text, answer, children, decision, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_admitted_plan(text, answer, children, decision, context) do
    semantic = semantic(decision, length(children))

    case FanoutPlan.compile_admission(text, children,
           max_children: max_children(context),
           source: :model
         ) do
      {:ok, plan} ->
        result = %{kind: :fanout, plan: plan, fallback_answer: answer}
        {:ok, {result, semantic}}

      {:clarify, clarification} ->
        result = %{kind: :clarify, clarification: clarification, fallback_answer: answer}
        {:ok, {result, semantic}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp semantic(decision, child_count) do
    decision
    |> Map.put(:work_unit_count, child_count)
    |> Map.put(:reviewed?, true)
  end

  defp rule_evidence(object) do
    with {:ok, task_count} <- reported_task_count(object["outer_request_task_count"]),
         {:ok, request_ownership} <-
           closed_enum(object["request_ownership"], @request_ownership),
         {:ok, all_advisory_or_read_only} <- closed_boolean(object["all_advisory_or_read_only"]),
         {:ok, children_self_contained} <- closed_boolean(object["children_self_contained"]),
         {:ok, can_progress_concurrently} <-
           closed_boolean(object["can_progress_concurrently"]),
         {:ok, child_result_dependency} <-
           closed_boolean(object["child_result_dependency"]),
         {:ok, full_coverage_exactly_once} <-
           closed_boolean(object["full_coverage_exactly_once"]),
         {:ok, material_parallel_leverage} <-
           closed_boolean(object["material_parallel_leverage"]),
         {:ok, join_role} <- closed_enum(object["join_role"], @join_roles) do
      {:ok,
       %{
         outer_request_task_count: task_count,
         request_ownership: request_ownership,
         all_advisory_or_read_only: all_advisory_or_read_only,
         children_self_contained: children_self_contained,
         can_progress_concurrently: can_progress_concurrently,
         child_result_dependency: child_result_dependency,
         full_coverage_exactly_once: full_coverage_exactly_once,
         material_parallel_leverage: material_parallel_leverage,
         join_role: join_role
       }}
    end
  end

  defp reported_task_count(value)
       when is_integer(value) and value >= 0 and value <= @max_reported_task_count,
       do: {:ok, value}

  defp reported_task_count(_value), do: {:error, :invalid_outer_request_task_count}

  defp closed_boolean(value) when is_boolean(value), do: {:ok, value}
  defp closed_boolean(_value), do: {:error, :invalid_adjudication_boolean}

  defp closed_response(response) when is_map(response) do
    pairs = Enum.map(response, fn {key, value} -> {normalize_key(key), value} end)
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(@response_keys) and
         Enum.sort(keys) == Enum.sort(@response_keys) do
      {:ok, Map.new(pairs)}
    else
      {:error, :invalid_manager_response_keys}
    end
  end

  defp closed_response(_response), do: {:error, :invalid_manager_response_keys}

  defp closed_enum(value, allowed) when is_binary(value) do
    case Map.fetch(allowed, value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_adjudication_enum}
    end
  end

  defp closed_enum(_value, _allowed), do: {:error, :invalid_adjudication_enum}

  defp answer(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= @max_answer_bytes,
      do: {:ok, value},
      else: {:error, :invalid_manager_answer}
  end

  defp answer(_value), do: {:error, :invalid_manager_answer}

  defp usable_answer(response) when is_map(response) do
    response
    |> Enum.find_value(fn
      {key, value} when key in [:answer, "answer"] -> value
      _field -> nil
    end)
    |> answer()
    |> case do
      {:ok, answer} -> answer
      {:error, _reason} -> nil
    end
  end

  defp usable_answer(_response), do: nil

  defp manager_flow(text, profile, context, budget_limits, provider_attempt_counter, agent) do
    %{
      text: text,
      profile: profile,
      context: context,
      budget_limits: budget_limits,
      provider_attempt_counter: provider_attempt_counter,
      agent: agent,
      attempts: 0,
      configurations: [],
      initial_answer: nil,
      initial_reason: nil
    }
  end

  defp decorate(
         result,
         semantic,
         %{
           profile: profile,
           attempts: attempts,
           budget_limits: budget_limits,
           context: context,
           agent: agent,
           configurations: configurations
         }
       ) do
    default_outcome = if result.kind == :fanout, do: :planned, else: :answered
    default_outcome = if result.kind == :clarify, do: :overflow, else: default_outcome

    with {:ok, configuration_binding} <-
           manager_configuration_binding(profile, attempts, configurations) do
      diagnostic =
        %{
          outcome: Map.get(semantic, :outcome, default_outcome),
          attempts: attempts,
          model_profile: profile_name(profile),
          model_profile_sha256: configuration_binding.sha256,
          model_profile_configuration_evidence: configuration_binding.evidence,
          budget_limits: budget_limits,
          plan_deadline_unix_ms: Map.fetch!(context, :fanout_plan_deadline_unix_ms),
          phases: agent.state.phases
        }
        |> Map.merge(Map.delete(semantic, :outcome))
        |> maybe_put_policy_validation(result.kind)

      {:ok, Map.put(result, :diagnostic, diagnostic)}
    end
  end

  defp maybe_put_policy_validation(diagnostic, :fanout) do
    Map.merge(diagnostic, %{
      semantic_validation: :allbert_policy_decision,
      semantic_rule_ids: Policy.admission_rule_ids()
    })
  end

  defp maybe_put_policy_validation(diagnostic, _kind), do: diagnostic

  defp manager_agent do
    ManagerAgent.new(
      id: "conversation-fanout-manager-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp run_command(agent, command, invoke, context) do
    with {:ok, timeout_ms} <- remaining_timeout(context) do
      task =
        Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor, fn ->
          ManagerAgent.cmd(
            agent,
            {command, %{invoke: invoke}},
            timeout: timeout_ms,
            max_retries: 0,
            __jido_instance__: AllbertAssist.Jido
          )
        end)

      await_command(task, agent, timeout_ms, context)
    else
      {:error, reason} -> {agent, {:error, reason}}
    end
  end

  defp await_command(task, prior_agent, timeout_ms, context) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {agent, directives}} ->
        command_result(agent, directives, context)

      {:exit, _reason} ->
        {prior_agent, {:error, :fanout_manager_command_exit}}

      nil ->
        {prior_agent, {:error, :fanout_manager_deadline_exhausted}}
    end
  end

  defp command_result(agent, directives, context) do
    cond do
      Enum.any?(List.wrap(directives), &match?(%JidoErrorDirective{}, &1)) ->
        {agent, {:error, :fanout_manager_command_failed}}

      deadline_exhausted?(context) ->
        {agent, {:error, :fanout_manager_deadline_exhausted}}

      match?({:ok, _value}, Map.get(agent.state, :last_result)) ->
        {agent, agent.state.last_result}

      match?({:error, _reason}, Map.get(agent.state, :last_result)) ->
        {agent, agent.state.last_result}

      true ->
        {agent, {:error, :missing_manager_command_result}}
    end
  end

  defp call_model(text, profile, context, attempt, attempt_number) do
    with :ok <- authorize_manager_attempt(context, attempt_number),
         {:ok, timeout_ms} <- remaining_timeout(context) do
      client = model_client(context)

      call_context =
        context
        |> Map.put(:fanout_manager_attempt, attempt)
        |> Map.put(:timeout_ms, timeout_ms)

      invoke_model_client(client, text, profile, call_context)
    end
  rescue
    exception -> {:error, {:model_call_failed, exception.__struct__}}
  catch
    :exit, reason -> {:error, {:model_call_failed, Redactor.redact(reason)}}
    kind, reason -> {:error, {:model_call_failed, Redactor.redact({kind, reason})}}
  end

  defp invoke_model_client(@default_model_client, text, profile, context) do
    case @default_model_client.respond_with_configuration(text, profile, context) do
      {:ok, response, configuration} when is_map(response) and is_map(configuration) ->
        {:ok, {response, configuration}}

      {:error, reason, configuration} when is_map(configuration) ->
        {:error,
         {:with_manager_request_configuration, {:model_call_failed, Redactor.redact(reason)},
          configuration}}

      {:error, reason} ->
        {:error, {:model_call_failed, Redactor.redact(reason)}}

      _other ->
        {:error, {:model_call_failed, :invalid_callback_return}}
    end
  end

  defp invoke_model_client(client, text, profile, context) do
    configuration = %{
      evidence_source: :injected_model_client,
      protocol: %{
        "phase" =>
          if(match?({:repair, _reason}, context.fanout_manager_attempt),
            do: "repair",
            else: "initial"
          )
      }
    }

    case client.respond(text, profile, context) do
      {:ok, response} when is_map(response) ->
        {:ok, {response, configuration}}

      {:error, reason} ->
        {:error,
         {:with_manager_request_configuration, {:model_call_failed, Redactor.redact(reason)},
          configuration}}

      _other ->
        {:error, {:model_call_failed, :invalid_callback_return}}
    end
  end

  defp authorize_manager_attempt(context, attempt_number) do
    Budget.authorize_manager_attempt(
      Map.fetch!(context, :fanout_budget_limits),
      attempt_number
    )
  end

  defp model_client(context) do
    Map.get(context, :model_client) ||
      :allbert_assist
      |> Application.get_env(@model_config, [])
      |> Keyword.get(:model_client, @default_model_client)
  end

  defp ensure_model_enabled(%{model_enabled?: true}), do: :ok
  defp ensure_model_enabled(%{model_enabled?: false}), do: {:error, :direct_answer_model_disabled}

  defp ensure_model_enabled(_context) do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :direct_answer_model_disabled}
      {:error, reason} -> {:error, {:settings_unavailable, reason}}
    end
  end

  defp resolve_manager_profile(%{model_profile: profile}) when is_map(profile),
    do: {:ok, profile}

  defp resolve_manager_profile(%{model_profile: _invalid}),
    do: {:error, {:fanout_role_unavailable, :fanout_manager}}

  defp resolve_manager_profile(context) do
    case Models.for(:fanout_manager, context) do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, _reason} -> {:error, {:fanout_role_unavailable, :fanout_manager}}
    end
  end

  defp authorize_manager_profile(profile, context) do
    case Disclosure.authorize_transport(profile, context) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:fanout_role_transport_unavailable, :fanout_manager}}
    end
  end

  defp max_children(context), do: Map.get(context, :max_children_per_fanout, 8)

  defp put_plan_deadline(context, profile, budget_limits) do
    request_timeout = Map.get(context, :timeout_ms, Map.get(profile, :timeout_ms, 10_000))

    timeout_ms =
      [request_timeout, Map.get(profile, :timeout_ms, 10_000), budget_limits.max_elapsed_ms]
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.min(fn -> 10_000 end)

    context
    |> Map.put(:fanout_budget_limits, budget_limits)
    |> Map.put(:fanout_manager_deadline_ms, System.monotonic_time(:millisecond) + timeout_ms)
    |> Map.put(
      :fanout_plan_deadline_unix_ms,
      System.system_time(:millisecond) + budget_limits.max_elapsed_ms
    )
  end

  defp remaining_timeout(context) do
    remaining =
      Map.fetch!(context, :fanout_manager_deadline_ms) - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: {:ok, remaining},
      else: {:error, :fanout_manager_deadline_exhausted}
  end

  defp deadline_exhausted?(context) do
    Map.fetch!(context, :fanout_manager_deadline_ms) <= System.monotonic_time(:millisecond)
  end

  defp expect_provider_attempts(provider_attempt_counter, expected) do
    observed = ProviderAttempt.count(provider_attempt_counter)

    if observed == expected,
      do: {:ok, observed},
      else: provider_attempt_mismatch(expected, observed)
  end

  defp bounded_provider_attempts(provider_attempt_counter, minimum, maximum) do
    observed = ProviderAttempt.count(provider_attempt_counter)

    cond do
      observed < minimum -> provider_attempt_mismatch(minimum, observed)
      observed > maximum -> provider_attempt_mismatch(maximum, observed)
      true -> {:ok, observed}
    end
  end

  defp preserve_provider_failure(provider_attempt_counter, minimum, maximum, reason) do
    case bounded_provider_attempts(provider_attempt_counter, minimum, maximum) do
      {:ok, _observed} -> {:error, public_model_call_error(reason)}
      {:error, _mismatch} = error -> error
    end
  end

  defp provider_attempt_mismatch(expected, observed) do
    {:error,
     {:fanout_manager_provider_attempt_mismatch, %{expected: expected, observed: observed}}}
  end

  defp model_call_error(
         {:with_manager_request_configuration, reason, configuration},
         configurations
       )
       when is_map(configuration),
       do: {reason, configurations ++ [configuration]}

  defp model_call_error(reason, configurations), do: {reason, configurations}

  defp public_model_call_error({:with_manager_request_configuration, reason, _configuration}),
    do: reason

  defp public_model_call_error(reason), do: reason

  defp profile_name(profile), do: Map.get(profile, :name) || Map.get(profile, "name")

  defp manager_configuration_binding(profile, attempts, configurations) do
    sources = Enum.map(configurations, &Map.get(&1, :evidence_source))

    cond do
      sources != [] and Enum.all?(sources, &(&1 == :production_req_llm)) and
          length(configurations) == attempts ->
        with {:ok, attempt_digests} <- exact_attempt_digests(profile, configurations),
             {:ok, sha256} <- RoleProfileConfiguration.attempt_set_digest(attempt_digests) do
          {:ok, %{sha256: sha256, evidence: :production_exact_attempt_set}}
        end

      Enum.all?(sources, &(&1 in [:injected_model_client, :injected_req_llm_client])) ->
        {:ok, %{sha256: nil, evidence: :injected_client_fixture}}

      true ->
        {:error, :invalid_fanout_manager_configuration_evidence}
    end
  end

  defp exact_attempt_digests(profile, configurations) do
    Enum.reduce_while(configurations, {:ok, []}, fn configuration, {:ok, digests} ->
      case RoleProfileConfiguration.digest(
             :fanout_manager,
             profile,
             Map.fetch!(configuration, :transport),
             Map.fetch!(configuration, :protocol)
           ) do
        {:ok, digest} -> {:cont, {:ok, digests ++ [digest]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end
