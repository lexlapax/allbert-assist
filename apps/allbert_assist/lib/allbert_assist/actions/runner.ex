defmodule AllbertAssist.Actions.Runner do
  @moduledoc """
  Shared runtime boundary for invoking registered Allbert Jido actions.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Signals
  alias Jido.Signal

  @type result :: {:ok, map()}

  @doc """
  Run a registered action by module or action name.

  Unknown action names and unregistered modules are denied without dynamic
  loading or invocation.
  """
  @spec run(module() | String.t() | atom(), map(), map()) :: result()
  def run(action_or_name, params, context \\ %{})

  def run(action_or_name, params, context) when is_map(params) and is_map(context) do
    case Registry.resolve(action_or_name) do
      {:ok, action_module} ->
        run_registered(action_module, params, context)

      {:error, {:unknown_action, unknown}} ->
        unknown_action_response(unknown, params, context)
    end
  end

  def run(action_or_name, _params, context) when is_map(context) do
    unknown_action_response(action_or_name, %{}, context)
  end

  defp run_registered(action_module, params, context) do
    action_name = action_module.name()
    started_at = System.monotonic_time(:millisecond)

    requested_signal =
      action_name
      |> Signals.action_requested(action_module, params, context)
      |> log_signal()

    response =
      action_module
      |> safe_run(params, runner_context(context, action_module, requested_signal))
      |> normalize_response(action_name)

    duration_ms = System.monotonic_time(:millisecond) - started_at
    status = response_status(response)

    completed_signal =
      action_name
      |> Signals.action_completed(action_module, status, response, context, duration_ms)
      |> log_signal()

    metadata = %{
      runner_action_id: runner_action_id(requested_signal),
      requested_signal_id: signal_id(requested_signal),
      completed_signal_id: signal_id(completed_signal),
      action_name: action_name,
      action_module: action_module,
      status: status,
      duration_ms: duration_ms,
      permission_decision: permission_decision(response),
      selected_skill: Map.get(context, :selected_skill),
      skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
      action_capability: Redactor.redact(action_capability(context, action_module)),
      error: Map.get(response, :error)
    }

    {:ok, attach_runner_metadata(response, metadata)}
  end

  defp safe_run(action_module, params, context) do
    try do
      action_module.run(params, context)
    rescue
      exception ->
        {:error, {exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  defp runner_context(context, action_module, requested_signal) do
    Map.merge(context, %{
      action_metadata: action_module.__action_metadata__(),
      selected_action: action_module.name(),
      selected_action_module: action_module,
      runner_requested_signal_id: signal_id(requested_signal)
    })
  end

  defp normalize_response({:ok, response}, _action_name) when is_map(response), do: response

  defp normalize_response({:error, reason}, action_name) do
    %{
      message: "Action #{action_name} failed: #{inspect(reason)}",
      status: :error,
      error: reason,
      actions: [
        %{
          name: action_name,
          status: :error,
          error: inspect(reason)
        }
      ]
    }
  end

  defp normalize_response(other, action_name) do
    %{
      message: "Action #{action_name} returned an invalid result: #{inspect(other)}",
      status: :error,
      error: {:invalid_action_result, other},
      actions: [
        %{
          name: action_name,
          status: :error,
          error: inspect(other)
        }
      ]
    }
  end

  defp unknown_action_response(unknown, params, context) do
    action_name = unknown_action_name(unknown)
    started_at = System.monotonic_time(:millisecond)

    requested_signal =
      action_name
      |> Signals.action_requested(nil, params, context)
      |> log_signal()

    response = %{
      message: "Action is not registered: #{inspect(unknown)}",
      status: :denied,
      error: {:unknown_action, unknown},
      actions: [
        %{
          name: action_name,
          status: :denied,
          error: {:unknown_action, unknown}
        }
      ]
    }

    duration_ms = System.monotonic_time(:millisecond) - started_at

    completed_signal =
      action_name
      |> Signals.action_completed(nil, :denied, response, context, duration_ms)
      |> log_signal()

    metadata = %{
      runner_action_id: runner_action_id(requested_signal),
      requested_signal_id: signal_id(requested_signal),
      completed_signal_id: signal_id(completed_signal),
      action_name: action_name,
      action_module: nil,
      status: :denied,
      duration_ms: duration_ms,
      permission_decision: nil,
      selected_skill: Map.get(context, :selected_skill),
      skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
      action_capability: Redactor.redact(Map.get(context, :action_capability)),
      error: {:unknown_action, unknown}
    }

    {:ok, attach_runner_metadata(response, metadata)}
  end

  defp attach_runner_metadata(response, metadata) do
    response
    |> Map.put(:runner_metadata, metadata)
    |> Map.update(:actions, [], fn actions ->
      Enum.map(actions, &attach_action_metadata(&1, metadata))
    end)
  end

  defp attach_action_metadata(action, metadata) do
    action
    |> Map.put(:runner_metadata, metadata)
    |> put_if_absent(:skill_metadata, metadata.skill_metadata)
    |> put_if_absent(:action_capability, metadata.action_capability)
  end

  defp put_if_absent(action, _key, nil), do: action
  defp put_if_absent(action, key, value), do: Map.put_new(action, key, value)

  defp response_status(%{status: status}) when is_atom(status), do: status
  defp response_status(_response), do: :completed

  defp permission_decision(%{permission_decision: decision}), do: Redactor.redact(decision)

  defp permission_decision(%{actions: actions}) when is_list(actions) do
    Enum.find_value(actions, &Map.get(&1, :permission_decision))
    |> Redactor.redact()
  end

  defp permission_decision(_response), do: nil

  defp action_capability(context, action_module) do
    Map.get(context, :action_capability) ||
      case Registry.capability(action_module) do
        {:ok, capability} -> Capability.summary(capability)
        {:error, _reason} -> nil
      end
  end

  defp log_signal({:ok, %Signal{} = signal}) do
    :ok = Signals.log(signal)
    signal
  end

  defp log_signal({:error, reason}) do
    raise ArgumentError, "could not create action lifecycle signal: #{inspect(reason)}"
  end

  defp signal_id(%Signal{id: id}), do: id

  defp runner_action_id(%Signal{id: id}), do: id

  defp unknown_action_name(unknown) when is_binary(unknown), do: unknown

  defp unknown_action_name(unknown) when is_atom(unknown) do
    unknown
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp unknown_action_name(unknown), do: inspect(unknown)
end
