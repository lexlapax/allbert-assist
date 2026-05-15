defmodule AllbertAssist.Signals do
  @moduledoc """
  Helpers for Allbert's runtime signal vocabulary.

  v0.04 keeps signal handling log-oriented. These helpers centralize signal
  construction and secret-safe action lifecycle summaries.
  """

  require Logger

  alias AllbertAssist.Security.Redactor
  alias Jido.Signal

  @action_requested "allbert.action.requested"
  @action_completed "allbert.action.completed"

  @channel_signal_types %{
    update_received: "allbert.channel.update_received",
    message_rejected: "allbert.channel.message_rejected",
    runtime_submitted: "allbert.channel.runtime_submitted",
    response_sent: "allbert.channel.response_sent",
    delivery_failed: "allbert.channel.delivery_failed",
    callback_received: "allbert.channel.callback_received"
  }

  @doc "Return action lifecycle signal names."
  @spec action_signal_types() :: %{requested: String.t(), completed: String.t()}
  def action_signal_types do
    %{requested: @action_requested, completed: @action_completed}
  end

  @doc "Return channel lifecycle signal names."
  @spec channel_signal_types() :: %{atom() => String.t()}
  def channel_signal_types, do: @channel_signal_types

  @doc "Create a channel lifecycle signal."
  @spec channel_lifecycle(atom(), map()) :: {:ok, Signal.t()} | {:error, term()}
  def channel_lifecycle(kind, metadata) when is_atom(kind) and is_map(metadata) do
    with {:ok, type} <- Map.fetch(@channel_signal_types, kind) do
      Signal.new(
        type,
        Redactor.redact(metadata),
        source: "/allbert/channels/#{Map.get(metadata, :channel, "unknown")}",
        subject: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
      )
    else
      :error -> {:error, {:unknown_channel_signal, kind}}
    end
  end

  @doc "Create an action-requested signal."
  @spec action_requested(String.t(), module() | nil, map(), map()) ::
          {:ok, Signal.t()} | {:error, term()}
  def action_requested(action_name, action_module, params, context \\ %{}) do
    Signal.new(
      @action_requested,
      %{
        action_name: action_name,
        action_module: module_name(action_module),
        params: Redactor.redact(params),
        source_signal_id: source_signal_id(context),
        channel: request_value(context, :channel),
        operator_id: request_value(context, :operator_id),
        selected_skill: Map.get(context, :selected_skill),
        skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
        action_capability: Redactor.redact(Map.get(context, :action_capability)),
        contract_status: contract_status(context)
      },
      source: "/allbert/actions/#{action_name}",
      subject: request_value(context, :operator_id)
    )
  end

  @doc "Create an action-completed signal."
  @spec action_completed(String.t(), module() | nil, atom(), map(), map(), non_neg_integer()) ::
          {:ok, Signal.t()} | {:error, term()}
  def action_completed(action_name, action_module, status, response, context, duration_ms) do
    Signal.new(
      @action_completed,
      %{
        action_name: action_name,
        action_module: module_name(action_module),
        status: status,
        duration_ms: duration_ms,
        permission_decision: permission_decision(response),
        selected_skill: Map.get(context, :selected_skill),
        skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
        action_capability: Redactor.redact(Map.get(context, :action_capability)),
        contract_status: contract_status(context),
        response: response_summary(response),
        error: sanitized_error(response)
      },
      source: "/allbert/actions/#{action_name}",
      subject: request_value(context, :operator_id)
    )
  end

  @doc "Log a signal using the current runtime log style."
  @spec log(Signal.t()) :: :ok
  def log(%Signal{} = signal) do
    Logger.info("allbert signal #{signal.type} id=#{signal.id} source=#{signal.source}")
    :ok
  end

  @doc "Recursively redact values with sensitive key names."
  @spec redact(term()) :: term()
  defdelegate redact(value), to: Redactor

  defp response_summary(%{} = response) do
    response
    |> Map.take([:message, :status, :permission_decision, :actions])
    |> Redactor.redact()
  end

  defp response_summary(response), do: Redactor.redact(response)

  defp permission_decision(%{permission_decision: decision}), do: Redactor.redact(decision)

  defp permission_decision(%{actions: actions}) when is_list(actions) do
    Enum.find_value(actions, &Map.get(&1, :permission_decision))
    |> Redactor.redact()
  end

  defp permission_decision(_response), do: nil

  defp sanitized_error(%{error: error}), do: inspect(error)
  defp sanitized_error(_response), do: nil

  defp request_value(%{request: request}, key) when is_map(request), do: Map.get(request, key)
  defp request_value(context, key) when is_map(context), do: Map.get(context, key)

  defp source_signal_id(%{request: %{input_signal_id: id}}), do: id
  defp source_signal_id(%{input_signal_id: id}), do: id
  defp source_signal_id(_context), do: nil

  defp contract_status(%{skill_metadata: %{capability_contract: %{validation_status: status}}}),
    do: status

  defp contract_status(%{
         skill_metadata: %{"capability_contract" => %{"validation_status" => status}}
       }),
       do: status

  defp contract_status(_context), do: nil

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: inspect(module)
end
