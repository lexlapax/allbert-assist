defmodule AllbertAssist.Workspace.AGUI.Bridge do
  @moduledoc """
  Internal-only AG-UI semantic mapping for curated Allbert signals.

  This module only translates already-created `Jido.Signal` structs into
  JSON-shaped maps for tests and future protocol work. It does not subscribe to
  SignalBus, expose HTTP/WebSocket/SSE endpoints, or dispatch any effects.
  """

  alias AllbertAssist.Signals
  alias Jido.Signal

  @type event :: %{required(String.t()) => term()}

  @mapping %{
    "allbert.runtime.turn.started" => "LIFECYCLE_START",
    "allbert.runtime.turn.completed" => "LIFECYCLE_END",
    "allbert.confirmation.requested" => "INTERRUPT",
    "allbert.confirmation.approved" => "INTERRUPT_RESPONSE",
    "allbert.confirmation.denied" => "INTERRUPT_RESPONSE",
    "allbert.objective.observed" => "STATE_DELTA",
    "allbert.objective.completed" => "STATE_SNAPSHOT",
    "allbert.action.requested" => "TOOL_CALL_START",
    "allbert.action.completed" => "TOOL_CALL_END",
    "allbert.action.failed" => "TOOL_CALL_ERROR"
  }

  @spec translate(Signal.t() | term()) :: {:ok, event()} | {:error, :no_mapping}
  def translate(%Signal{type: type} = signal) do
    case Map.fetch(@mapping, type) do
      {:ok, agui_type} -> {:ok, event(signal, agui_type)}
      :error -> {:error, :no_mapping}
    end
  end

  def translate(_signal), do: {:error, :no_mapping}

  defp event(%Signal{} = signal, agui_type) do
    signal
    |> base_event(agui_type)
    |> Map.merge(payload(signal, agui_type))
  end

  defp base_event(%Signal{} = signal, agui_type) do
    %{
      "type" => agui_type,
      "signal" => %{
        "id" => signal.id,
        "type" => signal.type,
        "source" => signal.source,
        "subject" => signal.subject,
        "time" => signal.time
      },
      "data" => json_safe(Signals.redact(signal.data || %{}))
    }
  end

  defp payload(%Signal{} = signal, "INTERRUPT_RESPONSE") do
    %{
      "response" => response_for(signal.type),
      "interrupt_id" => first_value(signal.data, [:confirmation_id, :id, :interrupt_id])
    }
  end

  defp payload(%Signal{} = signal, "INTERRUPT") do
    %{
      "interrupt_id" => first_value(signal.data, [:confirmation_id, :id, :interrupt_id]),
      "reason" => first_value(signal.data, [:reason, :message, :summary])
    }
  end

  defp payload(%Signal{} = signal, "TOOL_CALL_START") do
    %{
      "tool_call_id" => first_value(signal.data, [:action_id, :action_name, :id]),
      "tool_name" => first_value(signal.data, [:action_name, :tool_name, :name])
    }
  end

  defp payload(%Signal{} = signal, "TOOL_CALL_END") do
    %{
      "tool_call_id" => first_value(signal.data, [:action_id, :action_name, :id]),
      "result" => first_value(signal.data, [:response, :result, :status])
    }
  end

  defp payload(%Signal{} = signal, "TOOL_CALL_ERROR") do
    %{
      "tool_call_id" => first_value(signal.data, [:action_id, :action_name, :id]),
      "error" => first_value(signal.data, [:error, :reason, :message])
    }
  end

  defp payload(%Signal{} = signal, "STATE_DELTA") do
    %{"state" => %{"delta" => json_safe(signal.data || %{})}}
  end

  defp payload(%Signal{} = signal, "STATE_SNAPSHOT") do
    %{"state" => json_safe(signal.data || %{})}
  end

  defp payload(%Signal{} = signal, _agui_type) do
    %{"run_id" => first_value(signal.data, [:trace_id, :run_id, :id]) || signal.id}
  end

  defp response_for("allbert.confirmation.approved"), do: "approve"
  defp response_for("allbert.confirmation.denied"), do: "reject"
  defp response_for(_type), do: nil

  defp first_value(data, keys) when is_map(data) do
    Enum.find_value(keys, fn key ->
      Map.get(data, key) || Map.get(data, Atom.to_string(key))
    end)
    |> json_safe()
  end

  defp first_value(_data, _keys), do: nil

  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp json_safe(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp json_safe(%_struct{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value
end
