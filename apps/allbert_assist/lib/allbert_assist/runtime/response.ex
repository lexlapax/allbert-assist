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

  @known_string_statuses %{
    "completed" => :completed,
    "needs_confirmation" => :needs_confirmation,
    "denied" => :denied,
    "advisory" => :advisory,
    "error" => :error,
    "unsupported" => :unsupported,
    "unavailable" => :unavailable,
    "failed" => :failed,
    "timed_out" => :timed_out,
    "cancelled" => :cancelled,
    "not_found" => :not_found,
    "still_blocked" => :still_blocked,
    "objective_abandoned" => :objective_abandoned,
    "objective_cancelled" => :objective_cancelled,
    "objective_failed" => :objective_failed
  }

  @type status ::
          :completed
          | :needs_confirmation
          | :denied
          | :advisory
          | :error
          | :unsupported
          | :unavailable
          | atom()

  @type t :: %{
          required(:message) => String.t(),
          required(:status) => status(),
          required(:actions) => list(),
          optional(:decision) => map() | nil,
          optional(:resource_access) => list(),
          optional(:approval_handoff) => map() | nil,
          optional(:diagnostics) => list(),
          optional(:permission_decision) => map(),
          optional(atom()) => term()
        }

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
  def from_action_result({:ok, response}, _action_name) when is_map(response),
    do: normalize(response)

  def from_action_result({:error, reason}, action_name) do
    error("Action #{action_name} failed: #{inspect(reason)}", reason,
      actions: [
        action(action_name, :error, error: inspect(reason))
      ]
    )
  end

  def from_action_result(other, action_name) do
    error(
      "Action #{action_name} returned an invalid result: #{inspect(other)}",
      {:invalid_action_result, other},
      actions: [
        action(action_name, :error, error: inspect(other))
      ]
    )
  end

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

    response
    |> put_if_absent(:message, message(response, default_message))
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

  defp message(%{message: message}, _default) when is_binary(message), do: message
  defp message(%{"message" => message}, _default) when is_binary(message), do: message
  defp message(%{content: content}, _default) when is_binary(content), do: content
  defp message(%{"content" => content}, _default) when is_binary(content), do: content
  defp message(_response, default), do: default

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
