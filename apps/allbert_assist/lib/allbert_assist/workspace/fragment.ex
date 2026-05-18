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
  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Ephemeral
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody
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
          | :fragment_body_conflict
          | :fragment_id_conflict
          | :payload_too_large
          | :persistence_failed
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
    case validate_and_persist(envelope, :emitter) do
      {:ok, _record} ->
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

  @spec validate_received(Signal.t()) :: {:ok, Envelope.t()} | {:error, error_reason()}
  def validate_received(%Signal{type: @emitted_signal, data: data}) when is_map(data) do
    envelope = Map.get(data, :envelope) || Map.get(data, "envelope")

    case envelope do
      %Envelope{} ->
        validate_received_envelope(envelope)

      _other ->
        publish_dropped(envelope, :invalid_envelope)
        {:error, :invalid_envelope}
    end
  end

  def validate_received(signal) do
    publish_dropped(signal, :invalid_envelope)
    {:error, :invalid_envelope}
  end

  defp validate_received_envelope(%Envelope{} = envelope) do
    case validate_and_persist(envelope, :receiver) do
      {:ok, _record} ->
        {:ok, envelope}

      {:error, reason} ->
        publish_dropped(envelope, reason)
        {:error, reason}
    end
  rescue
    exception ->
      publish_dropped(envelope, {:exception, exception.__struct__})
      {:error, :persistence_failed}
  catch
    :exit, reason ->
      publish_dropped(envelope, {:exit, reason})
      {:error, :persistence_failed}
  end

  defp validate_and_persist(%Envelope{} = envelope, rate_scope) do
    with :ok <- validate(envelope, rate_scope),
         {:ok, record} <- persist(envelope) do
      {:ok, record}
    end
  end

  defp validate(%Envelope{} = envelope, rate_scope) do
    with :ok <- Envelope.validate_shape(envelope),
         :ok <- verify_signature(envelope),
         :ok <- validate_surface(envelope.surface),
         :ok <- validate_emitter(envelope.emitter_id),
         :ok <- check_rate_limit(envelope, rate_scope),
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

  defp check_rate_limit(%Envelope{} = envelope, :emitter) do
    Guard.check_rate(
      envelope.emitter_id,
      envelope.user_id,
      setting("workspace.fragment.rate_limit_per_second", @default_rate_limit)
    )
  end

  defp check_rate_limit(%Envelope{} = envelope, :receiver) do
    Guard.check_receiver_rate(
      envelope.emitter_id,
      envelope.user_id,
      setting("workspace.fragment.receiver_rate_limit_per_second", @default_rate_limit)
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

  defp persist(%Envelope{} = envelope) do
    if transient_fragment?(envelope) do
      {:ok, :transient}
    else
      persist_scoped(envelope)
    end
  end

  defp persist_scoped(%Envelope{scope: scope} = envelope) do
    case normalize_scope(scope) do
      "canvas" -> envelope |> fragment_attrs() |> Canvas.add_tile() |> persistence_result()
      "ephemeral" -> envelope |> fragment_attrs() |> Ephemeral.open() |> persistence_result()
      _scope -> {:error, :invalid_scope}
    end
  end

  defp persistence_result({:ok, record}), do: {:ok, record}

  defp persistence_result({:error, reason})
       when reason in [:fragment_body_conflict, :fragment_id_conflict],
       do: {:error, reason}

  defp persistence_result({:error, _reason}), do: {:error, :persistence_failed}

  defp transient_fragment?(%Envelope{kind: kind, metadata: metadata}) do
    normalize_kind(kind) == "badge_strip" and
      metadata_value(metadata, :placement) == "canvas_header"
  end

  defp fragment_attrs(%Envelope{} = envelope) do
    %{
      id: envelope.id,
      user_id: envelope.user_id,
      thread_id: envelope.thread_id,
      kind: normalize_kind(envelope.kind),
      metadata: fragment_metadata(envelope),
      body: FragmentBody.encode(envelope)
    }
    |> maybe_put_position(envelope.tile_position)
  end

  defp fragment_metadata(%Envelope{} = envelope) do
    %{
      "fragment_id" => envelope.id,
      "emitter_id" => envelope.emitter_id,
      "emitted_at" => emitted_at(envelope.emitted_at),
      "scope" => normalize_scope(envelope.scope)
    }
  end

  defp maybe_put_position(attrs, position) when is_integer(position) and position >= 0 do
    Map.put(attrs, :position, position)
  end

  defp maybe_put_position(attrs, _position), do: attrs

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

  defp normalize_scope(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp normalize_scope(scope) when is_binary(scope), do: scope

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp emitted_at(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp emitted_at(datetime) when is_binary(datetime), do: datetime
  defp emitted_at(_datetime), do: nil
end
