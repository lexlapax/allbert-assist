defmodule AllbertAssist.Intent.FanoutManager do
  @moduledoc """
  Conversational planning Interface for one central Runtime turn.

  One DirectAnswer-qualified assessment returns a useful answer plus bounded
  outer-request work units. A multi-unit candidate receives one separate
  policy adjudication; Allbert then derives either ordinary single-turn
  handling or an inert ordered `FanoutPlan`. Invalid initial structure may use
  that second call for repair instead, after which multi-unit work fails closed
  because it has not been independently adjudicated.

  This module is deliberately stateless. Durable work begins only after the
  caller hands a compiled plan to `AllbertAssist.Objectives`; model output does
  not grant action, permission, confirmation, identity, or scheduling authority.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Intent.FanoutManager.Agent, as: ManagerAgent
  alias AllbertAssist.Intent.FanoutManager.Commands.{Adjudicate, Assess}
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  @default_model_client __MODULE__.ReqLLMImplementation
  @model_config __MODULE__
  @assessment_keys ~w[answer work_units]
  @adjudication_keys ~w[work_shape join_role children]
  @work_shapes %{
    "independent_advisory" => :independent_advisory,
    "dependent_or_sequential" => :dependent_or_sequential,
    "effectful_or_mixed" => :effectful_or_mixed,
    "supplied_data" => :supplied_data,
    "single_or_indivisible" => :single_or_indivisible,
    "no_material_leverage" => :no_material_leverage,
    "ambiguous" => :ambiguous
  }
  @join_roles %{
    "none" => :none,
    "presentation_only" => :presentation_only,
    "consumes_sibling_result" => :consumes_sibling_result
  }
  @max_request_bytes 4_000
  @max_answer_bytes 32_000
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
      run_command(agent, Assess, fn -> call_model(text, profile, context, :assess, 1) end)

    case result do
      {:ok, response} ->
        case interpret_assessment(response) do
          {:ok, assessment} ->
            resolve_assessment(text, assessment, profile, context, budget_limits, agent)

          {:error, reason} ->
            repair_assessment(
              text,
              profile,
              context,
              budget_limits,
              agent,
              usable_answer(response),
              reason
            )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_assessment(
         text,
         %{answer: answer, work_units: work_units},
         profile,
         context,
         budget_limits,
         agent
       ) do
    case length(work_units) do
      count when count < 2 ->
        result = %{kind: :answer, message: answer}

        {:ok,
         decorate(result, profile, 1, budget_limits, context, %{
           policy_outcome: :single_or_indivisible,
           join_role: :none,
           work_unit_count: count,
           reviewed?: false,
           phases: agent.state.phases
         })}

      _multi ->
        adjudicate(text, answer, work_units, profile, context, budget_limits, agent)
    end
  end

  defp repair_assessment(
         text,
         profile,
         context,
         budget_limits,
         agent,
         initial_answer,
         initial_reason
       ) do
    invoke = fn ->
      call_model(
        text,
        profile,
        context,
        {:repair_assessment, initial_reason},
        2
      )
    end

    {agent, result} = run_command(agent, Assess, invoke)

    case result do
      {:ok, response} ->
        case interpret_assessment(response) do
          {:ok, %{answer: repaired_answer, work_units: units}} when length(units) < 2 ->
            result = %{kind: :answer, message: repaired_answer}

            {:ok,
             decorate(result, profile, 2, budget_limits, context, %{
               outcome: :answered_after_assessment_repair,
               policy_outcome: :single_or_indivisible,
               join_role: :none,
               work_unit_count: length(units),
               reviewed?: false,
               phases: agent.state.phases,
               assessment_error: initial_reason
             })}

          {:ok, %{answer: repaired_answer, work_units: units}} ->
            retain_answer(
              repaired_answer,
              profile,
              2,
              budget_limits,
              context,
              %{
                outcome: :answered_after_assessment_repair,
                policy_outcome: :adjudication_not_run,
                join_role: :none,
                work_unit_count: length(units),
                reviewed?: false,
                phases: agent.state.phases,
                assessment_error: initial_reason,
                adjudication_error: :manager_call_budget_used_by_assessment_repair
              }
            )

          {:error, repair_reason} ->
            retain_answer_or_error(
              initial_answer || usable_answer(response),
              profile,
              attempted_calls(repair_reason),
              budget_limits,
              context,
              %{
                outcome: :answered_after_invalid_assessment,
                policy_outcome: :assessment_invalid,
                join_role: :none,
                work_unit_count: 0,
                reviewed?: false,
                phases: agent.state.phases,
                assessment_error: initial_reason,
                repair_error: repair_reason
              },
              {initial_reason, repair_reason}
            )
        end

      {:error, repair_reason} ->
        retain_answer_or_error(
          initial_answer,
          profile,
          attempted_calls(repair_reason),
          budget_limits,
          context,
          %{
            outcome: :answered_after_invalid_assessment,
            policy_outcome: :assessment_invalid,
            join_role: :none,
            work_unit_count: 0,
            reviewed?: false,
            phases: agent.state.phases,
            assessment_error: initial_reason,
            repair_error: repair_reason
          },
          {initial_reason, repair_reason}
        )
    end
  end

  defp adjudicate(text, answer, work_units, profile, context, budget_limits, agent) do
    adjudication_context = Map.put(context, :fanout_candidate_units, work_units)

    {agent, result} =
      run_command(agent, Adjudicate, fn ->
        call_model(text, profile, adjudication_context, :adjudicate, 2)
      end)

    case result do
      {:ok, response} ->
        resolve_adjudication(
          text,
          answer,
          work_units,
          response,
          profile,
          context,
          budget_limits,
          agent
        )

      {:error, reason} ->
        retain_answer(
          answer,
          profile,
          attempted_calls(reason),
          budget_limits,
          context,
          %{
            outcome: :answered_after_adjudication_failure,
            policy_outcome: :adjudication_unavailable,
            join_role: :none,
            work_unit_count: length(work_units),
            reviewed?: false,
            phases: agent.state.phases,
            adjudication_error: reason
          }
        )
    end
  end

  defp resolve_adjudication(
         text,
         answer,
         assessed_units,
         response,
         profile,
         context,
         budget_limits,
         agent
       ) do
    case interpret_adjudication(response) do
      {:admit, shape, join_role, children} ->
        compile_adjudicated_plan(
          text,
          answer,
          children,
          shape,
          join_role,
          profile,
          context,
          budget_limits,
          agent
        )

      {:answer, shape, join_role} ->
        result = %{kind: :answer, message: answer}

        {:ok,
         decorate(result, profile, 2, budget_limits, context, %{
           policy_outcome: shape,
           join_role: join_role,
           work_unit_count: length(assessed_units),
           reviewed?: true,
           phases: agent.state.phases
         })}

      {:error, reason} ->
        retain_answer(
          answer,
          profile,
          2,
          budget_limits,
          context,
          %{
            outcome: :answered_after_invalid_adjudication,
            policy_outcome: :adjudication_invalid,
            join_role: :none,
            work_unit_count: length(assessed_units),
            reviewed?: false,
            phases: agent.state.phases,
            adjudication_error: reason
          }
        )
    end
  end

  defp compile_adjudicated_plan(
         text,
         answer,
         children,
         shape,
         join_role,
         profile,
         context,
         budget_limits,
         agent
       ) do
    semantic = %{
      policy_outcome: shape,
      join_role: join_role,
      work_unit_count: length(children),
      reviewed?: true,
      phases: agent.state.phases
    }

    case FanoutPlan.compile_admission(text, children,
           max_children: max_children(context),
           source: :model
         ) do
      {:ok, plan} ->
        result = %{kind: :fanout, plan: plan, fallback_answer: answer}
        {:ok, decorate(result, profile, 2, budget_limits, context, semantic)}

      {:clarify, clarification} ->
        result = %{kind: :clarify, clarification: clarification, fallback_answer: answer}
        {:ok, decorate(result, profile, 2, budget_limits, context, semantic)}

      {:error, reason} ->
        retain_answer(
          answer,
          profile,
          2,
          budget_limits,
          context,
          Map.merge(semantic, %{
            outcome: :answered_after_invalid_plan,
            policy_outcome: :compiled_plan_invalid,
            plan_error: reason
          })
        )
    end
  end

  defp interpret_assessment(response) do
    with {:ok, object} <- closed_response(response, @assessment_keys, :invalid_assessment_keys),
         {:ok, answer} <- answer(Map.fetch!(object, "answer")),
         {:ok, work_units} <- FanoutPlan.normalize_candidates(Map.fetch!(object, "work_units")) do
      {:ok, %{answer: answer, work_units: work_units}}
    end
  end

  defp interpret_adjudication(response) do
    with {:ok, object} <-
           closed_response(response, @adjudication_keys, :invalid_adjudication_keys),
         {:ok, work_shape} <- closed_enum(Map.fetch!(object, "work_shape"), @work_shapes),
         {:ok, join_role} <- closed_enum(Map.fetch!(object, "join_role"), @join_roles),
         {:ok, children} <- FanoutPlan.normalize_candidates(Map.fetch!(object, "children")) do
      adjudication_disposition(work_shape, join_role, children)
    end
  end

  defp adjudication_disposition(:independent_advisory, join_role, children)
       when join_role in [:none, :presentation_only] and length(children) >= 2,
       do: {:admit, :independent_advisory, join_role, children}

  defp adjudication_disposition(work_shape, join_role, [])
       when work_shape in [
              :dependent_or_sequential,
              :effectful_or_mixed,
              :supplied_data,
              :single_or_indivisible,
              :no_material_leverage,
              :ambiguous
            ] and join_role in [:none, :consumes_sibling_result],
       do: {:answer, work_shape, join_role}

  defp adjudication_disposition(_work_shape, _join_role, _children),
    do: {:error, :inconsistent_adjudication}

  defp closed_response(response, allowed_keys, error) when is_map(response) do
    pairs = Enum.map(response, fn {key, value} -> {normalize_key(key), value} end)
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(allowed_keys) and Enum.sort(keys) == Enum.sort(allowed_keys) do
      {:ok, Map.new(pairs)}
    else
      {:error, error}
    end
  end

  defp closed_response(_response, _allowed_keys, error), do: {:error, error}

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

  defp retain_answer_or_error(
         answer,
         profile,
         attempts,
         budget_limits,
         context,
         semantic,
         _failure
       )
       when is_binary(answer),
       do: retain_answer(answer, profile, attempts, budget_limits, context, semantic)

  defp retain_answer_or_error(
         nil,
         _profile,
         _attempts,
         _budget_limits,
         _context,
         _semantic,
         failure
       ),
       do: {:error, {:fanout_manager_failed, failure}}

  defp retain_answer(answer, profile, attempts, budget_limits, context, semantic) do
    result = %{kind: :answer, message: answer}
    {:ok, decorate(result, profile, attempts, budget_limits, context, semantic)}
  end

  defp decorate(result, profile, attempts, budget_limits, context, semantic) do
    default_outcome = if result.kind == :fanout, do: :planned, else: :answered
    default_outcome = if result.kind == :clarify, do: :overflow, else: default_outcome

    diagnostic =
      %{
        outcome: Map.get(semantic, :outcome, default_outcome),
        attempts: attempts,
        model_profile: profile_name(profile),
        model_profile_sha256: profile_configuration_digest(profile),
        budget_limits: budget_limits,
        plan_deadline_unix_ms: Map.fetch!(context, :fanout_plan_deadline_unix_ms)
      }
      |> Map.merge(Map.delete(semantic, :outcome))
      |> maybe_put_semantic_validation(result.kind)

    Map.put(result, :diagnostic, diagnostic)
  end

  defp maybe_put_semantic_validation(diagnostic, :fanout) do
    Map.merge(diagnostic, %{
      semantic_validation: :model_adjudication_compiled,
      semantic_claims: [
        :independent_children,
        :advisory_or_read_only_children,
        :supplied_text_owned_by_outer_request,
        :shared_deliverable_is_join_guidance
      ]
    })
  end

  defp maybe_put_semantic_validation(diagnostic, _kind), do: diagnostic

  defp manager_agent do
    ManagerAgent.new(
      id: "conversation-fanout-manager-#{System.unique_integer([:positive, :monotonic])}",
      state: %{phase: :ready, phases: [], last_result: nil}
    )
  end

  defp run_command(agent, command, invoke) do
    {agent, _directives} =
      ManagerAgent.cmd(
        agent,
        {command, %{invoke: invoke}},
        timeout: 0,
        __jido_instance__: AllbertAssist.Jido
      )

    {agent, Map.fetch!(agent.state, :last_result)}
  end

  defp call_model(text, profile, context, phase, attempt_number) do
    with :ok <- authorize_manager_attempt(context, attempt_number),
         {:ok, timeout_ms} <- remaining_timeout(context) do
      client = model_client(context)

      call_context =
        context
        |> Map.put(:fanout_manager_phase, phase)
        |> Map.put(:fanout_manager_attempt, compatibility_attempt(phase))
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

  defp compatibility_attempt(:assess), do: :initial
  defp compatibility_attempt(:adjudicate), do: :adjudicate
  defp compatibility_attempt({:repair_assessment, reason}), do: {:repair, reason}

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
