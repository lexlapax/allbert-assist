defmodule AllbertAssist.Signals do
  @moduledoc """
  Helpers for Allbert's runtime signal vocabulary.

  v0.04 keeps signal handling log-oriented. These helpers centralize signal
  construction and secret-safe action lifecycle summaries.
  """

  require Logger

  alias Jido.Signal

  @action_requested "allbert.action.requested"
  @action_completed "allbert.action.completed"

  @sensitive_key_fragments ["api_key", "apikey", "secret", "token", "password", "credential"]

  @doc "Return action lifecycle signal names."
  @spec action_signal_types() :: %{requested: String.t(), completed: String.t()}
  def action_signal_types do
    %{requested: @action_requested, completed: @action_completed}
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
        params: redact(params),
        source_signal_id: source_signal_id(context),
        channel: request_value(context, :channel),
        operator_id: request_value(context, :operator_id),
        selected_skill: Map.get(context, :selected_skill)
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
  def redact(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__struct__, module_name(struct.__struct__))
    |> redact()
  end

  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(value), do: value

  defp response_summary(%{} = response) do
    response
    |> Map.take([:message, :status, :permission_decision, :actions])
    |> redact()
  end

  defp response_summary(response), do: redact(response)

  defp permission_decision(%{permission_decision: decision}), do: redact(decision)

  defp permission_decision(%{actions: actions}) when is_list(actions) do
    Enum.find_value(actions, &Map.get(&1, :permission_decision))
    |> redact()
  end

  defp permission_decision(_response), do: nil

  defp sanitized_error(%{error: error}), do: inspect(error)
  defp sanitized_error(_response), do: nil

  defp request_value(%{request: request}, key) when is_map(request), do: Map.get(request, key)
  defp request_value(context, key) when is_map(context), do: Map.get(context, key)

  defp source_signal_id(%{request: %{input_signal_id: id}}), do: id
  defp source_signal_id(%{input_signal_id: id}), do: id
  defp source_signal_id(_context), do: nil

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: inspect(module)

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()

    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end
end
