defmodule AllbertAssist.Runtime.Response do
  @moduledoc """
  Typed response helpers for runtime-facing action, intent, and objective paths.

  The helpers keep the existing map shape operators and tests already consume,
  but centralize the status vocabulary, default fields, and conversions from
  richer intent structs into transport-safe maps.
  """

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.ResourceAccess
  alias AllbertAssist.Runtime.Redactor

  @action_statuses [
    :completed,
    :needs_confirmation,
    :denied,
    :advisory,
    :error,
    :unsupported,
    :unavailable,
    :failed,
    :timed_out,
    :cancelled,
    :not_found,
    :still_blocked,
    :objective_abandoned,
    :objective_cancelled,
    :objective_failed,
    :already_finished,
    :clarification,
    :degraded,
    :disabled,
    :finalizing,
    :needs_clarification,
    :queued,
    :running,
    :stopped
  ]
  @known_string_statuses Map.new(@action_statuses, &{Atom.to_string(&1), &1})
  @action_status_outcomes %{
    completed: :success,
    needs_confirmation: :needs_confirmation,
    denied: :denied,
    advisory: :success,
    error: :error,
    unsupported: :error,
    unavailable: :error,
    failed: :error,
    timed_out: :success,
    cancelled: :success,
    not_found: :success,
    still_blocked: :success,
    objective_abandoned: :success,
    objective_cancelled: :success,
    objective_failed: :success,
    already_finished: :success,
    clarification: :success,
    degraded: :success,
    disabled: :success,
    finalizing: :success,
    needs_clarification: :success,
    queued: :success,
    running: :success,
    stopped: :success
  }

  if MapSet.new(Map.keys(@action_status_outcomes)) != MapSet.new(@action_statuses) do
    raise "action status outcome inventory must classify every admitted status"
  end

  @type status ::
          :completed
          | :needs_confirmation
          | :denied
          | :advisory
          | :error
          | :unsupported
          | :unavailable
          | :failed
          | :timed_out
          | :cancelled
          | :not_found
          | :still_blocked
          | :objective_abandoned
          | :objective_cancelled
          | :objective_failed
          | :already_finished
          | :clarification
          | :degraded
          | :disabled
          | :finalizing
          | :needs_clarification
          | :queued
          | :running
          | :stopped

  @type t :: %{
          required(:message) => String.t(),
          required(:model_payload) => String.t(),
          required(:surface_payload) => String.t(),
          required(:status) => status(),
          required(:actions) => list(),
          optional(:decision) => map() | nil,
          optional(:resource_access) => list(),
          optional(:approval_handoff) => map() | nil,
          optional(:diagnostics) => list(),
          optional(:permission_decision) => map(),
          optional(atom()) => term()
        }

  @type action_response :: t()
  @type outcome_class :: :success | :needs_confirmation | :denied | :error
  @type action_response_schema :: %{
          message: :string,
          model_payload: :string,
          surface_payload: :string,
          status: :atom,
          actions: :list,
          decision: :map_or_nil,
          resource_access: :list,
          approval_handoff: :map_or_nil,
          diagnostics: :list
        }

  @action_response_schema %{
    message: :string,
    model_payload: :string,
    surface_payload: :string,
    status: :atom,
    actions: :list,
    decision: :map_or_nil,
    resource_access: :list,
    approval_handoff: :map_or_nil,
    diagnostics: :list
  }

  @doc "Return the stable internal fields guaranteed for registered action responses."
  @spec action_response_schema() :: action_response_schema()
  def action_response_schema, do: @action_response_schema

  @doc "Return the complete status vocabulary admitted at the registered-action boundary."
  @spec action_statuses() :: [status(), ...]
  def action_statuses, do: @action_statuses

  @doc "Return the explicit public-protocol outcome class for every admitted action status."
  @spec action_status_outcomes() :: %{required(status()) => outcome_class()}
  def action_status_outcomes, do: @action_status_outcomes

  @doc "Classify a response or status for transport mapping; unknown values fail closed."
  @spec outcome_class(map() | status()) :: outcome_class()
  def outcome_class(response) when is_map(response),
    do: response |> status(:unknown) |> outcome_class()

  def outcome_class(status) when is_atom(status),
    do: Map.get(@action_status_outcomes, status, :error)

  def outcome_class(_status), do: :error

  @doc "Build a completed response."
  @spec completed(String.t(), map() | keyword()) :: t()
  def completed(message, attrs \\ %{}), do: build(:completed, message, attrs)

  @doc "Build a confirmation-needed response."
  @spec needs_confirmation(String.t(), map() | keyword()) :: t()
  def needs_confirmation(message, attrs \\ %{}), do: build(:needs_confirmation, message, attrs)

  @doc "Alias for callers that read more naturally as a noun phrase."
  @spec confirmation_needed(String.t(), map() | keyword()) :: t()
  def confirmation_needed(message, attrs \\ %{}), do: needs_confirmation(message, attrs)

  @doc "Build a denied response."
  @spec denied(String.t(), map() | keyword()) :: t()
  def denied(message, attrs \\ %{}), do: build(:denied, message, attrs)

  @doc "Build an advisory response that must not imply authority."
  @spec advisory(String.t(), map() | keyword()) :: t()
  def advisory(message, attrs \\ %{}), do: build(:advisory, message, attrs)

  @doc "Build an error response with an optional machine-readable reason."
  @spec error(String.t(), term(), map() | keyword()) :: t()
  def error(message, reason \\ nil, attrs \\ %{}) do
    attrs
    |> attrs_map()
    |> maybe_put(:error, reason)
    |> then(&build(:error, message, &1))
  end

  @doc "Build an unsupported-capability response."
  @spec unsupported(String.t(), term(), map() | keyword()) :: t()
  def unsupported(message, reason \\ nil, attrs \\ %{}) do
    attrs
    |> attrs_map()
    |> maybe_put(:error, reason)
    |> then(&build(:unsupported, message, &1))
  end

  @doc "Build an unavailable-capability response."
  @spec unavailable(String.t(), term(), map() | keyword()) :: t()
  def unavailable(message, reason \\ nil, attrs \\ %{}) do
    attrs
    |> attrs_map()
    |> maybe_put(:error, reason)
    |> then(&build(:unavailable, message, &1))
  end

  @doc """
  Normalize an action callback result into the runtime response contract.

  Successful maps preserve their existing keys. Error and invalid callback
  shapes get the same operator-facing messages Runner used before M6.
  """
  @spec from_action_result({:ok, map()} | {:error, term()} | term(), String.t()) :: t()
  def from_action_result({:ok, response}, action_name) when is_map(response),
    do: normalize(response, default_message: default_action_message(action_name))

  def from_action_result({:error, reason}, action_name) do
    safe_reason = Redactor.redact(reason)

    error("Action #{action_name} failed: #{inspect(safe_reason)}", safe_reason,
      actions: [
        action(action_name, :error, error: :action_failed)
      ]
    )
  end

  def from_action_result(_other, action_name) do
    error(
      "Action #{action_name} returned an invalid result.",
      :invalid_action_result,
      actions: [
        action(action_name, :error, error: :invalid_action_result)
      ]
    )
  end

  @doc "Normalize and validate a registered action result at the Runner boundary."
  @spec canonical_action_result({:ok, map()} | {:error, term()} | term(), String.t()) ::
          action_response()
  def canonical_action_result({:ok, response}, action_name)
      when is_map(response) and is_binary(action_name) do
    with :ok <- validate_present_action_fields(response),
         normalized <- normalize(response, default_message: default_action_message(action_name)),
         {:ok, canonical_response} <- validate_action_response(normalized) do
      canonical_response
    else
      {:error, _reason} -> invalid_canonical_action_response(action_name)
    end
  end

  def canonical_action_result(result, action_name) when is_binary(action_name) do
    result
    |> from_action_result(action_name)
    |> ensure_canonical_action_response(action_name)
  end

  @doc "Return whether a response has every canonical internal action-response field."
  @spec canonical_action_response?(term()) :: boolean()
  def canonical_action_response?(%{
        message: message,
        model_payload: model_payload,
        surface_payload: surface_payload,
        status: status,
        actions: actions,
        decision: decision,
        resource_access: resource_access,
        approval_handoff: approval_handoff,
        diagnostics: diagnostics
      }) do
    is_binary(message) and
      is_binary(model_payload) and
      is_binary(surface_payload) and
      status in @action_statuses and
      is_list(actions) and
      (is_nil(decision) or is_map(decision)) and
      is_list(resource_access) and
      (is_nil(approval_handoff) or is_map(approval_handoff)) and
      is_list(diagnostics)
  end

  def canonical_action_response?(_response), do: false

  @doc "Validate a canonical internal action response without changing its contents."
  @spec validate_action_response(term()) :: {:ok, action_response()} | {:error, term()}
  def validate_action_response(response) when is_map(response) do
    if canonical_action_response?(response) do
      {:ok, response}
    else
      {:error, {:invalid_canonical_action_response, response}}
    end
  end

  def validate_action_response(response),
    do: {:error, {:invalid_canonical_action_response, response}}

  @doc "Build the standard response for an unknown or unregistered action."
  @spec unknown_action(term(), String.t()) :: t()
  def unknown_action(unknown, action_name) do
    denied("Action is not registered: #{inspect(unknown)}",
      error: {:unknown_action, unknown},
      actions: [
        action(action_name, :denied, error: {:unknown_action, unknown})
      ]
    )
  end

  @doc "Return a response with all contract fields populated and extra keys preserved."
  @spec normalize(term(), keyword()) :: t()
  def normalize(response, opts \\ [])

  def normalize(response, opts) when is_map(response) do
    default_message = Keyword.get(opts, :default_message, inspect(response, pretty: true))
    default_status = Keyword.get(opts, :default_status, :completed)
    message = message(response, default_message)
    model_payload = model_payload(response, message)
    surface_payload = surface_payload(response, model_payload)

    response
    |> put_if_absent(:message, message)
    |> put_if_absent(:model_payload, model_payload)
    |> put_if_absent(:surface_payload, surface_payload)
    |> Map.put(:status, status(response, default_status))
    |> Map.put(:actions, actions(response))
    |> Map.put(:decision, decision(response))
    |> Map.put(:resource_access, resource_access(response))
    |> Map.put(:approval_handoff, approval_handoff(response))
    |> Map.put(:diagnostics, diagnostics(response))
  end

  def normalize(message, opts) when is_binary(message) do
    build(Keyword.get(opts, :default_status, :completed), message,
      diagnostics: Keyword.get(opts, :diagnostics, [])
    )
  end

  def normalize(response, opts) do
    default_message = Keyword.get(opts, :default_message, inspect(response, pretty: true))

    build(Keyword.get(opts, :default_status, :completed), default_message,
      diagnostics: Keyword.get(opts, :diagnostics, [])
    )
  end

  @doc "Return the normalized status for any runtime response-like map."
  @spec status(map(), status()) :: status()
  def status(response, default \\ :completed)
  def status(%{status: status}, _default) when is_atom(status), do: status
  def status(%{"status" => status}, _default) when is_atom(status), do: status

  def status(%{status: status}, default) when is_binary(status),
    do: Map.get(@known_string_statuses, status, default)

  def status(%{"status" => status}, default) when is_binary(status),
    do: Map.get(@known_string_statuses, status, default)

  def status(_response, default), do: default

  @doc "Map a Security Central permission decision to the runtime response status vocabulary."
  @spec permission_status(term()) :: :completed | :needs_confirmation | :denied
  def permission_status(%{decision: :allowed}), do: :completed
  def permission_status(%{decision: :needs_confirmation}), do: :needs_confirmation
  def permission_status(%{decision: :denied}), do: :denied
  def permission_status(_decision), do: :denied

  @doc "Return true when a response is completed."
  @spec completed?(map()) :: boolean()
  def completed?(response), do: status(response) == :completed

  @doc "Return true when a response is waiting on confirmation."
  @spec needs_confirmation?(map()) :: boolean()
  def needs_confirmation?(response), do: status(response) == :needs_confirmation

  @doc "Return true when a response is denied."
  @spec denied?(map()) :: boolean()
  def denied?(response), do: status(response) == :denied

  @doc "Build a normalized action entry for `response.actions`."
  @spec action(String.t(), status(), map() | keyword()) :: map()
  def action(name, status, attrs \\ %{}) when is_binary(name) do
    attrs
    |> attrs_map()
    |> Map.merge(%{name: name, status: status})
  end

  @doc "Append a diagnostic without disturbing existing response metadata."
  @spec append_diagnostic(map(), map()) :: map()
  def append_diagnostic(response, diagnostic) when is_map(response) and is_map(diagnostic) do
    Map.update(response, :diagnostics, [diagnostic], &(&1 ++ [diagnostic]))
  end

  @doc "Return normalized diagnostic entries."
  @spec diagnostics(map()) :: list()
  def diagnostics(%{diagnostics: diagnostics}) when is_list(diagnostics), do: diagnostics
  def diagnostics(%{"diagnostics" => diagnostics}) when is_list(diagnostics), do: diagnostics
  def diagnostics(%{decision: %Decision{} = decision}), do: decision.diagnostics
  def diagnostics(_response), do: []

  defp build(status, message, attrs) when is_binary(message) do
    attrs = attrs_map(attrs)

    attrs
    |> Map.merge(%{
      message: message,
      status: status,
      actions: actions(attrs),
      diagnostics: diagnostics(attrs)
    })
    |> normalize(default_message: message, default_status: status)
  end

  defp ensure_canonical_action_response(response, action_name) do
    case validate_action_response(response) do
      {:ok, canonical_response} ->
        canonical_response

      {:error, _reason} ->
        invalid_canonical_action_response(action_name)
    end
  end

  defp invalid_canonical_action_response(action_name) do
    error(
      "Action #{action_name} returned an invalid canonical response.",
      :invalid_canonical_action_response,
      actions: [
        action(action_name, :error, error: :invalid_canonical_action_response)
      ]
    )
  end

  defp default_action_message(action_name), do: "Action #{action_name} completed."

  defp validate_present_action_fields(response) do
    validators = [
      message: &is_binary/1,
      model_payload: &is_binary/1,
      surface_payload: &is_binary/1,
      status: &valid_action_status?/1,
      actions: &is_list/1,
      decision: &(is_nil(&1) or is_map(&1)),
      resource_access: &is_list/1,
      approval_handoff: &(is_nil(&1) or is_map(&1)),
      diagnostics: &is_list/1
    ]

    Enum.reduce_while(validators, :ok, fn {key, validator}, :ok ->
      case present_values(response, key) do
        [] ->
          {:cont, :ok}

        values ->
          if Enum.all?(values, validator) do
            {:cont, :ok}
          else
            {:halt, {:error, {:invalid_action_response_field, key}}}
          end
      end
    end)
  end

  defp present_values(response, key) do
    string_key = Atom.to_string(key)

    [{key, Map.fetch(response, key)}, {string_key, Map.fetch(response, string_key)}]
    |> Enum.flat_map(fn
      {_key, {:ok, value}} -> [value]
      {_key, :error} -> []
    end)
  end

  defp valid_action_status?(status) when is_atom(status), do: status in @action_statuses

  defp valid_action_status?(status) when is_binary(status),
    do: Map.has_key?(@known_string_statuses, status)

  defp valid_action_status?(_status), do: false

  defp message(%{message: message}, _default) when is_binary(message), do: message
  defp message(%{"message" => message}, _default) when is_binary(message), do: message
  defp message(%{model_payload: payload}, _default) when is_binary(payload), do: payload
  defp message(%{"model_payload" => payload}, _default) when is_binary(payload), do: payload
  defp message(%{content: content}, _default) when is_binary(content), do: content
  defp message(%{"content" => content}, _default) when is_binary(content), do: content
  defp message(_response, default), do: default

  defp model_payload(%{model_payload: payload}, _fallback) when is_binary(payload), do: payload

  defp model_payload(%{"model_payload" => payload}, _fallback) when is_binary(payload),
    do: payload

  defp model_payload(_response, fallback), do: fallback

  defp surface_payload(%{surface_payload: payload}, _fallback) when is_binary(payload),
    do: payload

  defp surface_payload(%{"surface_payload" => payload}, _fallback) when is_binary(payload),
    do: payload

  defp surface_payload(_response, fallback), do: fallback

  defp actions(%{actions: actions}) when is_list(actions), do: actions
  defp actions(%{"actions" => actions}) when is_list(actions), do: actions
  defp actions(_response), do: []

  defp decision(%{decision: %Decision{} = decision}), do: Decision.to_map(decision)
  defp decision(%{decision: decision}) when is_map(decision), do: Decision.to_map(decision)
  defp decision(%{"decision" => decision}) when is_map(decision), do: Decision.to_map(decision)
  defp decision(_response), do: nil

  defp resource_access(%{resource_access: entries}) when is_list(entries),
    do: ResourceAccess.to_maps(entries)

  defp resource_access(%{"resource_access" => entries}) when is_list(entries),
    do: ResourceAccess.to_maps(entries)

  defp resource_access(%{decision: %Decision{} = decision}),
    do: ResourceAccess.to_maps(decision.resource_access)

  defp resource_access(%{decision: decision}) when is_map(decision) do
    decision
    |> Decision.to_map()
    |> Map.get(:resource_access, [])
    |> ResourceAccess.to_maps()
  end

  defp resource_access(_response), do: []

  defp approval_handoff(%{approval_handoff: %ApprovalHandoff{} = handoff}),
    do: ApprovalHandoff.to_map(handoff)

  defp approval_handoff(%{approval_handoff: handoff}) when is_map(handoff),
    do: ApprovalHandoff.to_map(handoff)

  defp approval_handoff(%{"approval_handoff" => handoff}) when is_map(handoff),
    do: ApprovalHandoff.to_map(handoff)

  defp approval_handoff(%{decision: %Decision{} = decision}),
    do: ApprovalHandoff.to_map(decision.approval_handoff)

  defp approval_handoff(_response), do: nil

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_if_absent(map, key, value), do: Map.put_new(map, key, value)
end
