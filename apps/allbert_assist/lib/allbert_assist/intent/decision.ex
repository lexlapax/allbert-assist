defmodule AllbertAssist.Intent.Decision do
  @moduledoc """
  Structured, inert intent decision contract for v0.11.

  A decision explains the selected skill/action, permission posture, resource
  access posture, and approval state before the runtime invokes any registered
  action. It validates against the action registry, skill registry, resource
  reference contract, and Security Central; it does not authorize or execute.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Intent.ResourceAccess
  alias AllbertAssist.Maps
  alias AllbertAssist.Security
  alias AllbertAssist.Session.AppId
  alias AllbertAssist.Skills

  @confirmation_states ~w[not_required required pending unsupported refused]a
  @directions ~w[foreground background]a

  defstruct [
    :intent,
    :confidence,
    :reason,
    :risk_summary,
    :selected_skill,
    :selected_action,
    :permission,
    :confirmation,
    :execution_mode,
    :foreground_or_background,
    :user_id,
    :thread_id,
    :session_id,
    :active_app,
    :approval_handoff,
    candidate_skills: [],
    candidate_actions: [],
    resource_access: [],
    alternatives: [],
    diagnostics: [],
    trace_metadata: %{}
  ]

  @type t :: %__MODULE__{
          intent: atom() | String.t() | nil,
          confidence: float(),
          reason: String.t() | nil,
          risk_summary: String.t() | nil,
          selected_skill: String.t() | nil,
          candidate_skills: [map()],
          selected_action: String.t() | nil,
          candidate_actions: [map()],
          permission: atom() | nil,
          confirmation: atom(),
          execution_mode: atom() | nil,
          resource_access: [ResourceAccess.t()],
          foreground_or_background: :foreground | :background,
          user_id: String.t(),
          thread_id: String.t() | nil,
          session_id: String.t() | nil,
          active_app: atom() | nil,
          approval_handoff: map() | nil,
          alternatives: [String.t() | map()],
          diagnostics: [map()],
          trace_metadata: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    context = field(attrs, :context, %{}) || %{}
    {active_app, active_app_diagnostics} = active_app(attrs, context)

    decision =
      %__MODULE__{
        intent: field(attrs, :intent),
        confidence: normalize_confidence(field(attrs, :confidence, 1.0)),
        reason: field(attrs, :reason),
        risk_summary: field(attrs, :risk_summary),
        selected_skill: normalize_optional_string(field(attrs, :selected_skill)),
        candidate_skills: normalize_list(field(attrs, :candidate_skills)),
        selected_action: normalize_optional_string(field(attrs, :selected_action)),
        candidate_actions: normalize_list(field(attrs, :candidate_actions)),
        permission: field(attrs, :permission),
        confirmation: field(attrs, :confirmation, :not_required),
        execution_mode: field(attrs, :execution_mode),
        resource_access: normalize_list(field(attrs, :resource_access)),
        foreground_or_background: field(attrs, :foreground_or_background, :foreground),
        user_id: user_id(attrs, context),
        thread_id:
          normalize_optional_string(
            field(attrs, :thread_id) || context_value(context, :thread_id)
          ),
        session_id:
          normalize_optional_string(
            field(attrs, :session_id) || context_value(context, :session_id)
          ),
        active_app: active_app,
        approval_handoff: field(attrs, :approval_handoff),
        alternatives: normalize_list(field(attrs, :alternatives)),
        diagnostics: normalize_list(field(attrs, :diagnostics)) ++ active_app_diagnostics,
        trace_metadata: field(attrs, :trace_metadata, %{}) || %{}
      }

    with {:ok, decision} <- validate_foreground_or_background(decision),
         {:ok, decision} <- validate_action(decision),
         {:ok, decision} <- validate_skill(decision, context),
         {:ok, decision} <- validate_resources(decision),
         {:ok, decision} <- validate_confirmation(decision),
         {:ok, decision} <- authorize(decision, context) do
      {:ok, put_trace_metadata(decision)}
    end
  end

  def new(value), do: {:error, {:invalid_decision, value}}

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, decision} -> decision
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec to_map(t() | map() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = decision) do
    %{
      intent: decision.intent,
      confidence: decision.confidence,
      reason: decision.reason,
      risk_summary: decision.risk_summary,
      selected_skill: decision.selected_skill,
      candidate_skills: decision.candidate_skills,
      selected_action: decision.selected_action,
      candidate_actions: decision.candidate_actions,
      permission: decision.permission,
      confirmation: decision.confirmation,
      execution_mode: decision.execution_mode,
      resource_access: ResourceAccess.to_maps(decision.resource_access),
      foreground_or_background: decision.foreground_or_background,
      user_id: decision.user_id,
      thread_id: decision.thread_id,
      session_id: decision.session_id,
      active_app: decision.active_app,
      approval_handoff: decision.approval_handoff,
      alternatives: decision.alternatives,
      diagnostics: decision.diagnostics,
      trace_metadata: decision.trace_metadata
    }
    |> drop_empty_values()
  end

  def to_map(decision) when is_map(decision), do: decision

  @spec authorization_decision(t() | map() | nil) :: map() | nil
  def authorization_decision(%__MODULE__{} = decision) do
    get_in(decision.trace_metadata, [:security_decision])
  end

  def authorization_decision(%{} = decision) do
    get_in(decision, [:trace_metadata, :security_decision]) ||
      get_in(decision, ["trace_metadata", "security_decision"])
  end

  def authorization_decision(_decision), do: nil

  @spec refused?(t() | map()) :: boolean()
  def refused?(%__MODULE__{confirmation: :refused}), do: true
  def refused?(%{confirmation: :refused}), do: true
  def refused?(%{"confirmation" => "refused"}), do: true
  def refused?(_decision), do: false

  defp validate_foreground_or_background(%__MODULE__{foreground_or_background: value} = decision)
       when value in @directions,
       do: {:ok, decision}

  defp validate_foreground_or_background(%__MODULE__{foreground_or_background: value}),
    do: {:error, {:invalid_foreground_or_background, value}}

  defp validate_action(%__MODULE__{selected_action: nil} = decision), do: {:ok, decision}

  defp validate_action(%__MODULE__{selected_action: action} = decision) do
    case Registry.capability(action) do
      {:ok, capability} ->
        summary = Capability.summary(capability)

        {:ok,
         %{
           decision
           | selected_action: capability.name,
             permission: capability.permission,
             execution_mode: capability.execution_mode,
             confirmation: confirmation_from_capability(decision.confirmation, capability),
             candidate_actions: normalize_candidate_actions(decision.candidate_actions, summary)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_skill(%__MODULE__{selected_skill: nil} = decision, _context), do: {:ok, decision}

  defp validate_skill(%__MODULE__{selected_skill: selected_skill} = decision, context) do
    case Skills.get(selected_skill, context) do
      {:ok, skill} ->
        candidate = %{
          name: skill.name,
          source_scope: skill.source_scope,
          trust_status: skill.trust_status,
          status: :selected
        }

        {:ok, %{decision | selected_skill: skill.name, candidate_skills: [candidate]}}

      {:error, reason} ->
        {:error, {:unknown_selected_skill, selected_skill, reason}}
    end
  rescue
    _exception ->
      {:error, {:unknown_selected_skill, selected_skill, :lookup_failed}}
  end

  defp validate_resources(%__MODULE__{resource_access: entries} = decision) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case ResourceAccess.new(entry) do
        {:ok, access} -> {:cont, {:ok, [access | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_resource_access, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, %{decision | resource_access: Enum.reverse(entries)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_confirmation(%__MODULE__{confirmation: confirmation} = decision)
       when confirmation in @confirmation_states,
       do: {:ok, decision}

  defp validate_confirmation(%__MODULE__{confirmation: confirmation}),
    do: {:error, {:invalid_confirmation_state, confirmation}}

  defp authorize(%__MODULE__{permission: nil} = decision, _context), do: {:ok, decision}

  defp authorize(%__MODULE__{} = decision, context) do
    security_context =
      context
      |> Map.put(:selected_action, decision.selected_action)
      |> Map.put(:selected_skill, decision.selected_skill)
      |> Map.put(:action_capability, selected_capability(decision))

    security_decision = Security.authorize(decision.permission, security_context)

    decision =
      decision
      |> apply_security_decision(security_decision)
      |> put_risk_summary(security_decision)

    {:ok,
     %{
       decision
       | trace_metadata: Map.put(decision.trace_metadata, :security_decision, security_decision)
     }}
  end

  defp apply_security_decision(decision, %{decision: :denied}) do
    %{decision | confirmation: :refused}
  end

  defp apply_security_decision(decision, %{decision: :needs_confirmation}) do
    case decision.confirmation do
      :pending -> decision
      :unsupported -> decision
      :refused -> decision
      _other -> %{decision | confirmation: :required}
    end
  end

  defp apply_security_decision(decision, _security_decision), do: decision

  defp put_risk_summary(%__MODULE__{risk_summary: summary} = decision, _security_decision)
       when is_binary(summary) and summary != "",
       do: decision

  defp put_risk_summary(decision, security_decision) do
    risk = get_in(security_decision, [:risk, :tier]) || :unknown

    %{
      decision
      | risk_summary: "#{security_decision.decision} #{decision.permission} risk=#{risk}"
    }
  end

  defp put_trace_metadata(%__MODULE__{} = decision) do
    trace_metadata =
      Map.merge(decision.trace_metadata, %{
        selected_action: decision.selected_action,
        selected_skill: decision.selected_skill,
        permission: decision.permission,
        confirmation: decision.confirmation,
        execution_mode: decision.execution_mode,
        resource_access_count: length(decision.resource_access),
        user_id: decision.user_id,
        thread_id: decision.thread_id,
        session_id: decision.session_id
      })
      |> put_if_present(:active_app, decision.active_app)
      |> put_if_present(:app_id, selected_action_app_id(decision))

    %{decision | trace_metadata: trace_metadata}
  end

  defp selected_capability(%__MODULE__{selected_action: nil}), do: nil

  defp selected_capability(%__MODULE__{selected_action: action}) do
    case Registry.capability(action) do
      {:ok, capability} -> Capability.summary(capability)
      {:error, _reason} -> nil
    end
  end

  defp selected_action_app_id(decision) do
    case selected_capability(decision) do
      %{app_id: app_id} -> app_id
      _summary -> nil
    end
  end

  defp confirmation_from_capability(:pending, _capability), do: :pending
  defp confirmation_from_capability(:unsupported, _capability), do: :unsupported
  defp confirmation_from_capability(:refused, _capability), do: :refused
  defp confirmation_from_capability(:required, _capability), do: :required

  defp confirmation_from_capability(_confirmation, %Capability{confirmation: :required}),
    do: :required

  defp confirmation_from_capability(_confirmation, _capability), do: :not_required

  defp normalize_candidate_actions([], selected_summary),
    do: [Map.put(selected_summary, :status, :selected)]

  defp normalize_candidate_actions(candidates, selected_summary) do
    selected = Map.put(selected_summary, :status, :selected)

    candidates
    |> Enum.map(&normalize_candidate_action/1)
    |> Enum.reject(&is_nil/1)
    |> then(fn normalized ->
      [selected | Enum.reject(normalized, &(&1.name == selected.name))]
    end)
  end

  defp normalize_candidate_action(%{} = candidate) do
    case field(candidate, :name) || field(candidate, :action) ||
           field(candidate, :selected_action) do
      nil ->
        nil

      action ->
        case Registry.capability(action) do
          {:ok, capability} -> capability |> Capability.summary() |> Map.merge(candidate)
          {:error, reason} -> %{name: to_string(action), status: :rejected, reason: reason}
        end
    end
  end

  defp normalize_candidate_action(action) when is_binary(action) or is_atom(action),
    do: normalize_candidate_action(%{name: action})

  defp normalize_candidate_action(_candidate), do: nil

  defp user_id(attrs, context) do
    attrs
    |> field(:user_id)
    |> Kernel.||(field(attrs, :operator_id))
    |> Kernel.||(context_value(context, :user_id))
    |> Kernel.||(context_value(context, :operator_id))
    |> Kernel.||("local")
    |> to_string()
  end

  defp active_app(attrs, context) do
    context_active_app = context_value(context, :active_app)

    if has_field?(attrs, :active_app) do
      candidate = field(attrs, :active_app)

      case AppId.normalize(candidate) do
        {:ok, app_id} ->
          {app_id, []}

        {:error, reason} ->
          {fallback, fallback_diagnostics} = normalize_context_active_app(context_active_app)
          {fallback, [active_app_diagnostic(candidate, reason) | fallback_diagnostics]}
      end
    else
      normalize_context_active_app(context_active_app)
    end
  end

  defp normalize_context_active_app(active_app) do
    case AppId.normalize(active_app) do
      {:ok, app_id} -> {app_id, []}
      {:error, reason} -> {nil, [active_app_diagnostic(active_app, reason)]}
    end
  end

  defp active_app_diagnostic(active_app, reason) do
    %{
      kind: :unknown_active_app,
      message: "Unknown active app was ignored.",
      detail: %{active_app: inspect(active_app), reason: reason}
    }
  end

  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_float(value) do
    value
    |> max(0.0)
    |> min(1.0)
  end

  defp normalize_confidence(_value), do: 1.0

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value), do: normalize_optional_string(to_string(value))

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(value), do: [value]

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)

  defp has_field?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp context_value(%{request: request} = context, key) when is_map(request),
    do: field(request, key) || context |> Map.delete(:request) |> context_value(key)

  defp context_value(context, key) when is_map(context), do: field(context, key)
  defp context_value(_context, _key), do: nil

  defp drop_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, value} when value == %{} -> true
      {_key, value} when value == [] -> true
      _entry -> false
    end)
  end
end
