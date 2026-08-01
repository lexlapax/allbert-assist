defmodule AllbertAssist.Objectives.Runs.Worker.Grounding do
  @moduledoc """
  Grounds fan-out child action selection in operator-authored source text.

  Conversational-manager child prose is useful work description, but it is
  advisory and cannot amplify action authority. v1.3 therefore executes those
  clean conversational children only through DirectAnswer. Exact-counted
  children may use their child text only when it is an exact span of the
  digest-verified operator turn. Invalid, unknown-version, or inconsistent
  provenance fails closed to DirectAnswer. A parent with no plan provenance is
  an upgrade-era ordinary fan-out and retains its pre-M9.b.4 action behavior.
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.{AcceptanceCriteria, Fanout, Objective}

  @type t :: %{
          decision_text: String.t() | nil,
          direct_answer_text: String.t(),
          action_text: String.t() | nil,
          original_request: String.t() | nil,
          child_objective: String.t(),
          expected_result: String.t() | nil,
          steering:
            nil
            | %{
                directive_event_id: String.t(),
                directive: String.t()
              },
          fanout_budget: map() | nil,
          fanout_deadline_unix_ms: integer() | nil,
          source:
            :ordinary
            | :legacy_ordinary
            | :operator_steered
            | :conversation_manager
            | :counted_protocol
            | :untrusted
        }

  @doc "Return the operator-grounded texts that may drive child action selection and params."
  @spec resolve(Objective.t()) :: t()
  def resolve(%Objective{fanout_role: "child"} = child) do
    with parent_id when is_binary(parent_id) <- child.parent_objective_id,
         {:ok, parent} <- Objectives.get_objective(parent_id) do
      resolve_child(child, parent)
    else
      _missing_or_inconsistent -> direct_answer_only(child, :untrusted)
    end
  end

  def resolve(%Objective{} = objective) do
    %{
      decision_text: objective.objective,
      direct_answer_text: objective.objective,
      action_text: objective.objective,
      original_request: nil,
      child_objective: objective.objective,
      expected_result: nil,
      steering: nil,
      fanout_budget: nil,
      fanout_deadline_unix_ms: nil,
      source: :ordinary
    }
  end

  @doc "Authorize a resolved action against the durable child-plan trust class."
  @spec authorize_action(t(), module()) :: :ok | {:error, :fanout_child_action_not_authorized}
  def authorize_action(%{source: source}, DirectAnswer)
      when source in [:conversation_manager, :untrusted],
      do: :ok

  def authorize_action(%{source: source}, _action_module)
      when source in [:conversation_manager, :untrusted],
      do: {:error, :fanout_child_action_not_authorized}

  def authorize_action(%{source: source}, _action_module)
      when source in [:ordinary, :legacy_ordinary, :operator_steered, :counted_protocol],
      do: :ok

  def authorize_action(_grounding, _action_module),
    do: {:error, :fanout_child_action_not_authorized}

  defp resolve_child(child, parent) do
    case Fanout.verified_plan(parent) do
      {:ok, plan} ->
        plan_source = plan["source"]
        digest = plan["original_request_sha256"]
        plan_digest = plan["plan_sha256"]

        with {:ok, source_intent} <- verified_source(parent, digest) do
          case verified_plan(parent, child, plan_source, plan_digest) do
            :ok -> grounded_child(child, source_intent, plan_source, plan)
            {:error, _changed} -> changed_plan_child(child, plan, source_intent)
          end
        else
          _missing_or_inconsistent -> direct_answer_only(child, :untrusted, plan)
        end

      {:error, :missing_plan_provenance} ->
        if compiled_child_binding_present?(child.proposer_hint),
          do: direct_answer_only(child, :untrusted),
          else: legacy_ordinary(child)

      {:error, _invalid} ->
        direct_answer_only(child, :untrusted)
    end
  end

  defp grounded_child(child, source_intent, "conversation_manager", plan) do
    child
    |> quality_fields(source_intent, nil)
    |> Map.merge(%{
      decision_text: nil,
      direct_answer_text: compiled_task_input(child),
      action_text: nil,
      fanout_budget: Map.get(plan, "budget"),
      fanout_deadline_unix_ms: Map.get(plan, "deadline_unix_ms"),
      source: :conversation_manager
    })
  end

  defp grounded_child(child, source_intent, "counted_protocol", plan) do
    if exact_span?(source_intent, child.objective) do
      child
      |> quality_fields(source_intent, nil)
      |> Map.merge(%{
        decision_text: child.objective,
        direct_answer_text: compiled_task_input(child),
        action_text: child.objective,
        fanout_budget: Map.get(plan, "budget"),
        fanout_deadline_unix_ms: Map.get(plan, "deadline_unix_ms"),
        source: :counted_protocol
      })
    else
      direct_answer_only(child, :untrusted, plan)
    end
  end

  defp grounded_child(child, _source_intent, _unknown_source, _plan),
    do: direct_answer_only(child, :untrusted)

  defp direct_answer_only(child, source) do
    direct_answer_only(child, source, %{})
  end

  defp direct_answer_only(child, source, plan) do
    %{
      decision_text: nil,
      direct_answer_text: child.objective,
      action_text: nil,
      original_request: nil,
      child_objective: child.objective,
      expected_result: nil,
      steering: nil,
      fanout_budget: Map.get(plan, "budget"),
      fanout_deadline_unix_ms: Map.get(plan, "deadline_unix_ms"),
      source: source
    }
  end

  defp changed_plan_child(child, plan, source_intent) do
    case verified_steering(child) do
      {:ok, %{directive: directive} = steering} ->
        child
        |> quality_fields(source_intent, steering)
        |> Map.merge(%{
          decision_text: directive,
          direct_answer_text: directive,
          action_text: directive,
          fanout_budget: Map.get(plan, "budget"),
          fanout_deadline_unix_ms: Map.get(plan, "deadline_unix_ms"),
          source: :operator_steered
        })

      {:error, _not_operator_steered} ->
        direct_answer_only(child, :untrusted, plan)
    end
  end

  defp legacy_ordinary(child) do
    %{
      decision_text: child.objective,
      direct_answer_text: child.objective,
      action_text: child.objective,
      original_request: nil,
      child_objective: child.objective,
      expected_result: nil,
      steering: nil,
      fanout_budget: nil,
      fanout_deadline_unix_ms: nil,
      source: :legacy_ordinary
    }
  end

  defp compiled_child_binding_present?(hint) when is_binary(hint) do
    case Jason.decode(hint) do
      {:ok, decoded} -> compiled_child_binding_present?(decoded)
      {:error, _reason} -> false
    end
  end

  defp compiled_child_binding_present?(%{"fanout_child" => _binding}), do: true
  defp compiled_child_binding_present?(_hint), do: false

  defp verified_source(%Objective{} = parent, digest) do
    case parent.objective do
      source when is_binary(source) ->
        if digest == sha256(source), do: {:ok, source}, else: {:error, :source_digest_mismatch}

      _missing ->
        {:error, :source_digest_mismatch}
    end
  end

  defp verified_plan(parent, child, source, expected_digest) do
    with {:ok, plan_source} <- plan_source(source),
         {:ok, children} <- durable_children(Fanout.children(parent)),
         {:ok, compiled} <-
           FanoutPlan.compile(parent.objective, children,
             source: plan_source,
             max_children: 16
           ),
         true <-
           compiled.plan_sha256 == expected_digest or
             durable_child_binding_valid?(child, expected_digest) do
      :ok
    else
      _invalid_or_changed ->
        if durable_child_binding_valid?(child, expected_digest),
          do: :ok,
          else: {:error, :plan_digest_mismatch}
    end
  end

  defp durable_child_binding_valid?(%Objective{} = child, expected_digest) do
    case durable_child(child) do
      {:ok, durable} ->
        FanoutPlan.child_binding_valid?(
          expected_digest,
          child.queue_position,
          durable,
          child.proposer_hint
        )

      {:error, _invalid} ->
        false
    end
  end

  defp durable_children(children) do
    children
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case durable_child(child) do
        {:ok, durable} -> {:cont, {:ok, [durable | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, durable} -> {:ok, Enum.reverse(durable)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_child(%Objective{} = child) do
    with {:ok, %{"summary" => expected_result} = criteria} <-
           AcceptanceCriteria.decode(child.acceptance_criteria),
         true <- map_size(criteria) == 1,
         true <- is_binary(expected_result) do
      {:ok,
       %{
         "title" => child.title,
         "objective" => child.objective,
         "expected_result" => expected_result
       }}
    else
      _invalid -> {:error, :invalid_durable_plan_child}
    end
  end

  defp compiled_task_input(child) do
    case durable_child(child) do
      {:ok, %{"objective" => objective, "expected_result" => expected_result}} ->
        """
        Allbert bounded fan-out task

        Objective:
        #{objective}

        Expected result (output and evaluation guidance only):
        #{expected_result}
        """
        |> String.trim()

      {:error, _invalid} ->
        child.objective
    end
  end

  defp plan_source("conversation_manager"), do: {:ok, :model}
  defp plan_source("counted_protocol"), do: {:ok, :exact_counted}
  defp plan_source(_source), do: {:error, :invalid_plan_source}

  defp verified_steering(child) do
    events = Objectives.list_events(child.id, limit: 200)

    with %{payload: applied_payload} <- Enum.find(events, &(&1.kind == "steer_applied")),
         directive_event_id when is_binary(directive_event_id) <-
           payload_value(applied_payload, "directive_event_id"),
         %{payload: directive_payload} <-
           Enum.find(events, &(&1.id == directive_event_id and &1.kind == "steer_directive")),
         directive when is_binary(directive) <- payload_value(directive_payload, "directive"),
         true <- child.objective == directive,
         true <- child.title == String.slice(directive, 0, 200) do
      {:ok, %{directive_event_id: directive_event_id, directive: directive}}
    else
      _missing_or_changed -> {:error, :unverified_steering}
    end
  end

  defp payload_value(payload, "directive_event_id") when is_map(payload),
    do: Map.get(payload, "directive_event_id") || Map.get(payload, :directive_event_id)

  defp payload_value(payload, "directive") when is_map(payload),
    do: Map.get(payload, "directive") || Map.get(payload, :directive)

  defp payload_value(payload, _key) when is_map(payload), do: nil

  defp payload_value(payload, key) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> payload_value(decoded, key)
      {:error, _invalid} -> nil
    end
  end

  defp payload_value(_payload, _key), do: nil

  defp exact_span?(source_intent, child_text) do
    child_text != "" and String.contains?(source_intent, child_text)
  end

  defp quality_fields(child, source_intent, steering) do
    expected_result =
      case durable_child(child) do
        {:ok, %{"expected_result" => expected_result}} -> expected_result
        {:error, _invalid} -> nil
      end

    %{
      original_request: source_intent,
      child_objective: child.objective,
      expected_result: expected_result,
      steering: steering
    }
  end

  defp sha256(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end
end
