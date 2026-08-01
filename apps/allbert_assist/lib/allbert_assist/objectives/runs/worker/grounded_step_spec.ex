defmodule AllbertAssist.Objectives.Runs.Worker.GroundedStepSpec do
  @moduledoc """
  Derives and verifies the one durable action step allowed by grounded child text.

  Compiled-plan prose is never action authority by itself. Conversation-manager
  and untrusted children have one closed DirectAnswer specification. Counted and
  operator-steered children re-run the central Engine and SelectionPolicy over
  operator-authored text. The resulting registered action name, canonical JSON
  params, and advisory resource metadata must match the durable step exactly at
  every authority boundary.

  Legacy ordinary Objectives retain their pre-M9.b.4 recovery behavior.
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Confirmations.ResumeParamsBinding
  alias AllbertAssist.Intent.{Decision, Engine, SelectionPolicy}
  alias AllbertAssist.Objectives.{Objective, Step}

  @validated_sources [:conversation_manager, :counted_protocol, :operator_steered, :untrusted]

  @type t :: %{
          required(:action) => String.t(),
          required(:action_module) => module(),
          required(:params) => map(),
          required(:resource_access) => list()
        }

  @doc "Derive the canonical durable step specification for current grounded text."
  @spec derive(Objective.t(), map()) :: {:ok, t()} | {:error, term()}
  def derive(%Objective{}, %{source: source} = grounding)
      when source in [:conversation_manager, :untrusted] do
    canonical_spec(DirectAnswer, %{text: grounding.direct_answer_text}, [])
  end

  def derive(%Objective{} = objective, %{source: source} = grounding)
      when source in [:ordinary, :legacy_ordinary] do
    derive_engine_spec(objective, grounding, [])
  end

  def derive(%Objective{} = objective, %{source: source} = grounding)
      when source in [:counted_protocol, :operator_steered] do
    derive_engine_spec(objective, grounding, model_assist: false)
  end

  def derive(_objective, _grounding), do: {:error, :invalid_grounded_step_source}

  defp derive_engine_spec(objective, grounding, engine_opts) do
    request = %{
      text: grounding.decision_text,
      user_id: objective.user_id,
      thread_id: objective.source_thread_id,
      session_id: objective.session_id,
      active_app: objective.active_app,
      channel: objective.source_channel
    }

    with {:ok, decision} <- Engine.decide(request, engine_opts),
         {:ok, action_module} <- selected_action(decision, grounding),
         {:ok, params} <- action_params(action_module, decision, grounding),
         {:ok, resource_access} <- resource_access(action_module, decision) do
      canonical_spec(action_module, params, resource_access)
    end
  end

  @doc "Verify a persisted plan child step against its freshly derived specification."
  @spec validate(Objective.t(), Step.t(), map()) :: :ok | {:error, term()}
  def validate(%Objective{} = objective, %Step{} = step, %{source: source} = grounding)
      when source in @validated_sources do
    with {:ok, expected} <- derive(objective, grounding),
         :ok <- compare(:action, step.candidate_action, expected.action),
         {:ok, params} <- decode_map(step.action_params),
         :ok <- compare(:params, params, expected.params),
         {:ok, resource_access} <- decode_list(step.resource_access),
         :ok <- compare(:resource_access, resource_access, expected.resource_access) do
      :ok
    end
  end

  def validate(%Objective{}, %Step{}, %{source: source})
      when source in [:ordinary, :legacy_ordinary],
      do: :ok

  def validate(_objective, _step, _grounding),
    do: {:error, :invalid_grounded_step_source}

  @doc "Verify an action-owned confirmation resume packet against its parked binding."
  @spec validate_resume_params(Step.t(), map(), map()) :: :ok | {:error, term()}
  def validate_resume_params(%Step{} = step, params, %{source: source})
      when source in @validated_sources do
    ResumeParamsBinding.verify(step.confirmation_resume_params_sha256, params)
  end

  def validate_resume_params(%Step{}, _params, %{source: source})
      when source in [:ordinary, :legacy_ordinary],
      do: :ok

  def validate_resume_params(_step, _params, _grounding),
    do: {:error, :invalid_grounded_step_source}

  defp selected_action(%Decision{} = decision, grounding) do
    action =
      if SelectionPolicy.decision_accepted?(decision, grounding.decision_text || "") do
        decision.selected_action || "direct_answer"
      else
        "direct_answer"
      end

    case Registry.resolve(action) do
      {:ok, action_module} -> {:ok, action_module}
      {:error, _unknown} -> {:ok, DirectAnswer}
    end
  end

  defp action_params(DirectAnswer, _decision, grounding),
    do: {:ok, %{text: grounding.direct_answer_text}}

  defp action_params(action_module, decision, grounding) do
    slots = get_in(decision.trace_metadata, [:extracted_slots]) || %{}

    params =
      case action_module.name() do
        "external_network_request" -> Map.put_new(slots, :request, grounding.action_text)
        _other -> slots
      end

    canonical_map(params)
  end

  defp resource_access(DirectAnswer, _decision), do: {:ok, []}

  defp resource_access(_action_module, decision) do
    decision
    |> Decision.to_map()
    |> Map.get(:resource_access, [])
    |> canonical_list()
  end

  defp canonical_spec(action_module, params, resource_access) do
    with {:ok, params} <- canonical_map(params),
         {:ok, resource_access} <- canonical_list(resource_access) do
      {:ok,
       %{
         action: action_module.name(),
         action_module: action_module,
         params: params,
         resource_access: resource_access
       }}
    end
  end

  defp canonical_map(value) when is_map(value), do: json_round_trip(value, :map)
  defp canonical_map(_value), do: {:error, :invalid_grounded_action_params}

  defp canonical_list(value) when is_list(value), do: json_round_trip(value, :list)
  defp canonical_list(_value), do: {:error, :invalid_grounded_resource_access}

  defp json_round_trip(value, expected) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- expected_shape?(decoded, expected) do
      {:ok, decoded}
    else
      _invalid -> {:error, :invalid_grounded_step_json}
    end
  end

  defp decode_map(nil), do: {:error, {:grounded_step_mismatch, :params}}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _invalid -> {:error, {:grounded_step_mismatch, :params}}
    end
  end

  defp decode_map(value) when is_map(value), do: canonical_map(value)
  defp decode_map(_value), do: {:error, {:grounded_step_mismatch, :params}}

  defp decode_list(nil), do: {:error, {:grounded_step_mismatch, :resource_access}}

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      _invalid -> {:error, {:grounded_step_mismatch, :resource_access}}
    end
  end

  defp decode_list(value) when is_list(value), do: canonical_list(value)
  defp decode_list(_value), do: {:error, {:grounded_step_mismatch, :resource_access}}

  defp compare(_field, value, value), do: :ok
  defp compare(field, _actual, _expected), do: {:error, {:grounded_step_mismatch, field}}

  defp expected_shape?(value, :map), do: is_map(value)
  defp expected_shape?(value, :list), do: is_list(value)
end
