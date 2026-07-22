defmodule AllbertAssist.Surface.EventRecorder do
  @moduledoc """
  Best-effort event recorder for non-channel surfaces.

  v0.58 extends the durable channel-event spine to web, CLI, and public protocol
  surfaces by storing their stable `surface_id` in the existing `channel` field.
  """

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Runtime.Response

  @provider "allbert"
  @failed_statuses [:error, :failed, :unsupported, :unavailable, :timed_out, :cancelled]

  @spec record_inbound(String.t() | atom(), map()) :: Event.t() | nil
  def record_inbound(surface_id, attrs \\ %{}) when is_map(attrs) do
    create(surface_id, attrs, "inbound", "received")
  end

  @spec record_rejection(String.t() | atom(), map()) :: Event.t() | nil
  def record_rejection(surface_id, attrs \\ %{}) when is_map(attrs) do
    create(surface_id, attrs, "inbound", "rejected")
  end

  @spec record_error(String.t() | atom(), map(), term()) :: Event.t() | nil
  def record_error(surface_id, attrs \\ %{}, reason) when is_map(attrs) do
    create(surface_id, Map.put_new(attrs, :error, inspect(reason)), "inbound", "failed")
  end

  @spec mark_result(Event.t() | nil, {:ok, map()} | {:error, term()} | term()) :: :ok
  def mark_result(%Event{} = event, {:ok, response}) when is_map(response) do
    status = Response.status(response)

    attrs =
      response
      |> response_attrs()
      |> Map.put(:status, event_status(status))
      |> maybe_put_reason(status)

    update(event, attrs)
  end

  def mark_result(%Event{} = event, {:error, reason}) do
    update(event, %{status: "failed", error: inspect(reason)})
  end

  def mark_result(%Event{} = event, other) do
    update(event, %{status: "failed", error: inspect(other)})
  end

  def mark_result(nil, _result), do: :ok

  @doc "Persist a successful result and report write failure to delivery-barrier callers."
  @spec mark_result_durable(Event.t() | nil, map()) :: :ok | {:error, term()}
  def mark_result_durable(%Event{} = event, response) when is_map(response) do
    status = Response.status(response)

    attrs =
      response
      |> response_attrs()
      |> Map.put(:status, event_status(status))
      |> maybe_put_reason(status)

    case Channels.update_event(event, attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_result_durable(nil, _response), do: {:error, :event_not_recorded}

  @spec mark_failed(Event.t() | nil, term()) :: :ok
  def mark_failed(%Event{} = event, reason) do
    update(event, %{status: "failed", error: inspect(reason)})
  end

  def mark_failed(nil, _reason), do: :ok

  @spec mark_rejected(Event.t() | nil, term()) :: :ok
  def mark_rejected(%Event{} = event, reason) do
    update(event, %{status: "rejected", reason: inspect(reason)})
  end

  def mark_rejected(nil, _reason), do: :ok

  defp create(surface_id, attrs, direction, status) do
    attrs =
      attrs
      |> Map.put(:channel, surface_id(surface_id))
      |> Map.put_new(:provider, @provider)
      |> Map.put(:direction, direction)
      |> Map.put(:status, status)
      |> Map.put_new(:external_event_id, external_event_id(surface_id, status))

    case Channels.create_event(attrs) do
      {:ok, event} -> event
      {:error, _changeset} -> nil
    end
  end

  defp update(event, attrs) do
    _ = Channels.update_event(event, attrs)
    :ok
  end

  defp response_attrs(response) do
    %{
      input_signal_id: Map.get(response, :signal_id),
      trace_id: Map.get(response, :trace_id),
      user_id: Map.get(response, :user_id),
      session_id: Map.get(response, :session_id),
      thread_id: Map.get(response, :thread_id),
      payload_summary: Map.get(response, :message),
      error: Map.get(response, :error)
    }
    |> compact()
  end

  defp event_status(:denied), do: "rejected"
  defp event_status(status) when status in @failed_statuses, do: "failed"
  defp event_status(_status), do: "processed"

  defp maybe_put_reason(attrs, :denied), do: Map.put(attrs, :reason, "denied")

  defp maybe_put_reason(attrs, status) when status in @failed_statuses,
    do: Map.put(attrs, :reason, to_string(status))

  defp maybe_put_reason(attrs, _status), do: attrs

  defp compact(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      _entry -> false
    end)
  end

  defp external_event_id(surface_id, status) do
    "#{surface_id(surface_id)}:#{status}:#{Ecto.UUID.generate()}"
  end

  defp surface_id(surface_id) when is_atom(surface_id), do: Atom.to_string(surface_id)
  defp surface_id(surface_id), do: to_string(surface_id)
end
