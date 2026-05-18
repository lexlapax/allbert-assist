defmodule AllbertAssist.Workspace.Fragment do
  @moduledoc """
  Workspace fragment emission boundary.

  Runtime fragments pass through this boundary before the workspace shell can
  see them. Invalid fragments emit a bounded dropped signal and return a
  specific error; they are never rendered.
  """

  require Logger

  alias AllbertAssist.Settings
  alias AllbertAssist.SignalBus
  alias AllbertAssist.Signals
  alias AllbertAssist.Surface
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.Guard
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias Jido.Signal
  alias Jido.Signal.Bus

  @type envelope :: Envelope.t()
  @type error_reason ::
          :emitter_not_allowed
          | :invalid_envelope
          | :invalid_metadata
          | :invalid_scope
          | :invalid_surface
          | :payload_too_large
          | :rate_limited
          | :signature_invalid
          | :surface_invalid

  @emitted_signal "allbert.workspace.fragment.emitted"
  @dropped_signal "allbert.workspace.fragment.dropped"
  @default_rate_limit 10
  @default_payload_max_bytes 65_536
  @bounded_field_bytes 160

  @spec emit(term()) :: :ok | {:error, error_reason()}
  def emit(%Envelope{} = envelope) do
    case validate(envelope) do
      :ok ->
        publish_emitted(envelope)
        :ok

      {:error, reason} ->
        publish_dropped(envelope, reason)
        {:error, reason}
    end
  rescue
    exception ->
      reason = {:exception, exception.__struct__}
      publish_dropped(envelope, reason)
      {:error, :invalid_envelope}
  catch
    :exit, reason ->
      publish_dropped(envelope, {:exit, reason})
      {:error, :invalid_envelope}
  end

  def emit(envelope) do
    publish_dropped(envelope, :invalid_envelope)
    {:error, :invalid_envelope}
  end

  defp validate(%Envelope{} = envelope) do
    with :ok <- Envelope.validate_shape(envelope),
         :ok <- verify_signature(envelope),
         :ok <- validate_surface(envelope.surface),
         :ok <- validate_emitter(envelope.emitter_id),
         :ok <- check_rate_limit(envelope),
         :ok <- check_size(envelope) do
      :ok
    end
  end

  defp verify_signature(%Envelope{} = envelope) do
    with {:ok, secret} <- SigningSecret.ensure(),
         :ok <- Envelope.verify(envelope, secret) do
      :ok
    else
      {:error, :signature_missing} -> {:error, :signature_invalid}
      {:error, :signature_invalid} -> {:error, :signature_invalid}
      {:error, _reason} -> {:error, :signature_invalid}
    end
  end

  defp validate_surface(%Surface{} = surface) do
    case Surface.validate_surface(surface) do
      {:ok, _surface} -> :ok
      {:error, _diagnostics} -> {:error, :surface_invalid}
    end
  end

  defp validate_surface(_surface), do: {:error, :surface_invalid}

  defp validate_emitter(emitter_id) do
    if Guard.emitter_allowed?(emitter_id), do: :ok, else: {:error, :emitter_not_allowed}
  end

  defp check_rate_limit(%Envelope{} = envelope) do
    Guard.check_rate(
      envelope.emitter_id,
      envelope.user_id,
      setting("workspace.fragment.rate_limit_per_second", @default_rate_limit)
    )
  end

  defp check_size(%Envelope{} = envelope) do
    max_bytes = setting("workspace.fragment.payload_max_bytes", @default_payload_max_bytes)

    if byte_size(:erlang.term_to_binary(envelope)) <= max_bytes do
      :ok
    else
      {:error, :payload_too_large}
    end
  end

  defp publish_emitted(%Envelope{} = envelope) do
    data = %{
      envelope: envelope,
      fragment_id: envelope.id,
      user_id: envelope.user_id,
      thread_id: envelope.thread_id,
      emitter_id: envelope.emitter_id,
      scope: envelope.scope,
      kind: envelope.kind
    }

    publish_signal(@emitted_signal, data, envelope)
  end

  defp publish_dropped(envelope, reason) do
    data = dropped_data(envelope, reason)

    maybe_log_dropped(data)
    publish_signal(@dropped_signal, data, envelope)
  end

  defp publish_signal(type, data, envelope) do
    case Signal.new(type, data, source: source(envelope), subject: Map.get(data, :user_id)) do
      {:ok, signal} ->
        publish(signal)

      {:error, reason} ->
        Logger.debug("workspace fragment signal skipped type=#{type} reason=#{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.debug(
        "workspace fragment signal failed type=#{type} reason=#{Exception.message(exception)}"
      )

      :ok
  end

  defp publish(%Signal{} = signal) do
    case Bus.publish(SignalBus, [signal]) do
      {:ok, _recorded} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "workspace fragment signal publish skipped type=#{signal.type} reason=#{inspect(reason)}"
        )

        :ok
    end
  catch
    :exit, reason ->
      Logger.debug(
        "workspace fragment signal publish unavailable type=#{signal.type} reason=#{inspect(reason)}"
      )

      :ok
  end

  defp dropped_data(%Envelope{} = envelope, reason) do
    %{
      reason: normalize_reason(reason),
      fragment_id: bounded(envelope.id),
      user_id: bounded(envelope.user_id),
      thread_id: bounded(envelope.thread_id),
      emitter_id: bounded(envelope.emitter_id),
      scope: bounded(envelope.scope),
      kind: bounded(envelope.kind)
    }
  end

  defp dropped_data(_envelope, reason) do
    %{
      reason: normalize_reason(reason),
      fragment_id: nil,
      user_id: nil,
      thread_id: nil,
      emitter_id: nil,
      scope: nil,
      kind: nil
    }
  end

  defp maybe_log_dropped(data) do
    if setting("workspace.signal_bridge.log_dropped_fragments", true) do
      Logger.warning(
        "workspace fragment dropped reason=#{inspect(data.reason)} " <>
          "fragment_id=#{inspect(data.fragment_id)} user_id=#{inspect(data.user_id)} " <>
          "thread_id=#{inspect(data.thread_id)} emitter_id=#{inspect(data.emitter_id)}"
      )
    end

    :ok
  end

  defp source(%Envelope{id: id}) when is_binary(id) and id != "" do
    "/allbert/workspace/fragments/#{id}"
  end

  defp source(_envelope), do: "/allbert/workspace/fragments"

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  rescue
    _exception -> default
  catch
    :exit, _reason -> default
  end

  defp bounded(nil), do: nil

  defp bounded(value) do
    value
    |> to_string()
    |> Signals.redact()
    |> String.slice(0, @bounded_field_bytes)
  end

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason({kind, _detail}) when is_atom(kind), do: kind
end
