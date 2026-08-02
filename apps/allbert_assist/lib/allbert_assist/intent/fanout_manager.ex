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
  alias AllbertAssist.Objectives.Fanout.Budget
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
  @profile_binding_fields ~w[
    name
    provider
    provider_type
    provider_endpoint_kind
    model
    aliases
    capabilities
    media
    temperature
    max_tokens
    timeout_ms
    provider_base_url
    provider_api_key_ref
  ]a

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
    with :ok <- validate_request(text),
         :ok <- ensure_model_enabled(context),
         {:ok, profile} <- resolve_profile(context),
         :ok <- Disclosure.authorize_transport(profile, context),
         {:ok, budget_limits} <- Budget.limits(),
         context <- put_plan_deadline(context, profile, budget_limits) do
      assess(text, profile, context, budget_limits)
    end
  end

  def respond(_text, _context), do: {:error, :invalid_fanout_manager_request}

  @doc "Return a content-free binding for the exact qualified manager profile configuration."
  @spec profile_binding(map()) :: profile_binding()
  def profile_binding(profile) when is_map(profile) do
    %{
      "name" => profile_name(profile),
      "configuration_sha256" => profile_configuration_digest(profile)
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

  defp assess(text, profile, context, budget_limits) do
    agent = manager_agent()

    {agent, result} =
      run_command(
        agent,
        Assess,
        fn -> call_model(text, profile, context, :initial, 1) end,
        context
      )

    case result do
      {:ok, response} ->
        adjudicate_initial(text, response, profile, context, budget_limits, agent)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp adjudicate_initial(text, response, profile, context, budget_limits, agent) do
    {agent, result} =
      run_command(
        agent,
        Adjudicate,
        fn -> interpret_response(text, response, context) end,
        context
      )

    case result do
      {:ok, {resolved, semantic}} ->
        {:ok, decorate(resolved, profile, 1, budget_limits, context, semantic, agent)}

      {:error, reason} ->
        repair_once(
          text,
          profile,
          context,
          budget_limits,
          agent,
          usable_answer(response),
          reason
        )
    end
  end

  defp repair_once(
         text,
         profile,
         context,
         budget_limits,
         agent,
         initial_answer,
         initial_reason
       ) do
    {agent, result} =
      run_command(
        agent,
        Assess,
        fn -> call_model(text, profile, context, {:repair, initial_reason}, 2) end,
        context
      )

    case result do
      {:ok, repaired_response} ->
        adjudicate_repair(
          text,
          repaired_response,
          profile,
          context,
          budget_limits,
          agent,
          initial_answer,
          initial_reason
        )

      {:error, repair_reason} ->
        retain_answer_or_error(
          initial_answer,
          profile,
          attempted_calls(repair_reason),
          budget_limits,
          context,
          agent,
          initial_reason,
          repair_reason
        )
    end
  end

  defp adjudicate_repair(
         text,
         repaired_response,
         profile,
         context,
         budget_limits,
         agent,
         initial_answer,
         initial_reason
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
        {:ok, decorate(resolved, profile, 2, budget_limits, context, semantic, agent)}

      {:error, repair_reason} ->
        retain_answer_or_error(
          initial_answer || usable_answer(repaired_response),
          profile,
          2,
          budget_limits,
          context,
          agent,
          initial_reason,
          repair_reason
        )
    end
  end

  defp retain_answer_or_error(
         answer,
         profile,
         attempts,
         budget_limits,
         context,
         agent,
         initial_reason,
         repair_reason
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

    {:ok, decorate(result, profile, attempts, budget_limits, context, semantic, agent)}
  end

  defp retain_answer_or_error(
         nil,
         _profile,
         _attempts,
         _budget_limits,
         _context,
         _agent,
         initial_reason,
         repair_reason
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

  defp decorate(result, profile, attempts, budget_limits, context, semantic, agent) do
    default_outcome = if result.kind == :fanout, do: :planned, else: :answered
    default_outcome = if result.kind == :clarify, do: :overflow, else: default_outcome

    diagnostic =
      %{
        outcome: Map.get(semantic, :outcome, default_outcome),
        attempts: attempts,
        model_profile: profile_name(profile),
        model_profile_sha256: profile_configuration_digest(profile),
        budget_limits: budget_limits,
        plan_deadline_unix_ms: Map.fetch!(context, :fanout_plan_deadline_unix_ms),
        phases: agent.state.phases
      }
      |> Map.merge(Map.delete(semantic, :outcome))
      |> maybe_put_policy_validation(result.kind)

    Map.put(result, :diagnostic, diagnostic)
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

      case client.respond(text, profile, call_context) do
        {:ok, response} when is_map(response) -> {:ok, response}
        {:error, reason} -> {:error, {:model_call_failed, Redactor.redact(reason)}}
        _other -> {:error, {:model_call_failed, :invalid_callback_return}}
      end
    end
  rescue
    exception -> {:error, {:model_call_failed, exception.__struct__}}
  catch
    :exit, reason -> {:error, {:model_call_failed, Redactor.redact(reason)}}
    kind, reason -> {:error, {:model_call_failed, Redactor.redact({kind, reason})}}
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

  defp resolve_profile(%{model_profile: profile}) when is_map(profile), do: {:ok, profile}

  defp resolve_profile(context) do
    case Models.for(:direct_answer, context) do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, reason} -> {:error, {:model_unavailable, reason}}
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

  defp attempted_calls(:fanout_manager_deadline_exhausted), do: 1
  defp attempted_calls({:fanout_budget_exhausted, _detail}), do: 1
  defp attempted_calls(_repair_reason), do: 2

  defp profile_name(profile), do: Map.get(profile, :name) || Map.get(profile, "name")

  defp profile_configuration_digest(profile) do
    canonical =
      Enum.map(@profile_binding_fields, fn key ->
        value = Map.get(profile, key) || Map.get(profile, Atom.to_string(key))
        encoded = canonical_value(value)
        [Atom.to_string(key), ?:, Integer.to_string(byte_size(encoded)), ?:, encoded, ?;]
      end)

    :sha256
    |> :crypto.hash(canonical)
    |> Base.encode16(case: :lower)
  end

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, nested} -> [key, ?=, canonical_value(nested), ?;] end)
    |> IO.iodata_to_binary()
  end

  defp canonical_value(value) when is_list(value) do
    value
    |> Enum.map(fn nested ->
      encoded = canonical_value(nested)
      [Integer.to_string(byte_size(encoded)), ?:, encoded, ?;]
    end)
    |> IO.iodata_to_binary()
  end

  defp canonical_value(value), do: Jason.encode!(value)

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end
