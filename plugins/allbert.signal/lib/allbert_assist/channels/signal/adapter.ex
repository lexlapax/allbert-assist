defmodule AllbertAssist.Channels.Signal.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Capabilities.ReleaseAvailability
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.Signal.Client
  alias AllbertAssist.Channels.Signal.Daemon
  alias AllbertAssist.Channels.Signal.Parser
  alias AllbertAssist.Channels.Signal.Renderer
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor

  @provider "signal_cli_jsonrpc"
  @trust_class :e2ee_origin

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def simulate_daemon_notification(server \\ __MODULE__, notification) do
    GenServer.call(server, {:handle_notification, notification, %{surface: "signal_simulate"}})
  end

  def daemon_notification(server \\ __MODULE__, notification) do
    GenServer.cast(server, {:handle_notification, notification, %{surface: "signal_daemon"}})
  end

  def status(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :not_started
      pid -> GenServer.call(pid, :status, 1_000)
    end
  catch
    :exit, _reason -> :unavailable
  end

  @impl true
  def init(opts) do
    {:ok, load_state(opts)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, channel_status(state), state}
  end

  def handle_call({:handle_notification, notification, auth_context}, _from, state) do
    {reply, state} =
      case ensure_live_use_allowed(auth_context) do
        :ok -> process_notification(notification, auth_context, state)
        {:error, reason} -> {{:error, reason}, state}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:handle_notification, notification, auth_context}, state) do
    {_reply, state} =
      case ensure_live_use_allowed(auth_context) do
        :ok -> process_notification(notification, auth_context, state)
        {:error, _reason} -> {{:error, :live_use_denied}, state}
      end

    {:noreply, state}
  end

  defp channel_status(state) do
    cond do
      not ReleaseAvailability.live_use_allowed?({:channel, "signal"}) ->
        :implemented_not_released

      state.enabled? ->
        :running

      true ->
        :disabled
    end
  end

  defp ensure_live_use_allowed(%{surface: "signal_simulate"}), do: :ok

  defp ensure_live_use_allowed(_auth_context),
    do: ReleaseAvailability.ensure_live_use_allowed({:channel, "signal"})

  defp load_state(opts) do
    settings =
      case Channels.channel_settings("signal") do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    _custody = Daemon.ensure_custody!(settings)

    %{
      enabled?: Map.get(settings, "enabled", false),
      settings: settings,
      client_opts: Keyword.get(opts, :client_opts, default_client_opts(settings)),
      diagnostics: AllbertSignal.Settings.Fragment.required_when_enabled(settings)
    }
  end

  defp default_client_opts(settings) do
    settings
    |> Daemon.client_opts(Application.get_env(:allbert_assist, :signal_client_opts, []))
  end

  defp process_notification(notification, auth_context, state) do
    events = Parser.parse_notification(notification)

    summary =
      Enum.reduce(events, %{processed: 0, duplicates: 0, rejected: 0, failed: 0}, fn event,
                                                                                     summary ->
        case process_parsed_event(event, auth_context, state) do
          {:ok, :processed} -> Map.update!(summary, :processed, &(&1 + 1))
          {:ok, :duplicate} -> Map.update!(summary, :duplicates, &(&1 + 1))
          {:ok, :rejected} -> Map.update!(summary, :rejected, &(&1 + 1))
          {:error, _reason} -> Map.update!(summary, :failed, &(&1 + 1))
        end
      end)

    {{:ok, summary}, state}
  end

  defp process_parsed_event({:text_message, fields}, auth_context, state),
    do: process_text_event(fields, auth_context, state)

  defp process_parsed_event({:unsupported, fields}, _auth_context, _state),
    do: insert_rejected_event(fields)

  defp process_parsed_event({:malformed, reason}, _auth_context, _state),
    do: {:error, {:malformed, reason}}

  defp process_text_event(fields, auth_context, state) do
    fields = put_thread_fields(fields, state)
    {text, new_thread?} = prompt_text(fields.text)
    fields = maybe_isolate_new_provider_thread(fields, new_thread?)

    case insert_received_event(fields, "inbound") do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        handle_text_event(event, fields, auth_context, state, text, new_thread?)

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_text_event(event, fields, _auth_context, state, text, new_thread?) do
    with :ok <- validate_enabled(state),
         :ok <- validate_aci(fields, state),
         :ok <- validate_text(fields, state),
         :ok <- reject_echo(fields),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id),
         session_id <- Channels.derive_session_id("signal", fields.external_user_id, nil),
         {:ok, response} <-
           submit_runtime(text, user_id, session_id, fields, new_thread?, inbound_trust),
         {:ok, chunks} <- Renderer.render_response(response, renderer_opts(state)),
         {:ok, delivered} <-
           Runtime.track_delivery(response, %{channel: "signal"}, fn ->
             deliver_chunks(fields, chunks, state)
           end),
         :ok <- record_outbound_refs(response, fields, delivered),
         :ok <- Runtime.acknowledge_deliveries(response, %{channel: "signal"}),
         {:ok, _event} <- mark_processed(event, response, user_id, session_id) do
      {:ok, :processed}
    else
      {:error, {:delivery_failed, _reason} = reason} ->
        Logger.debug("signal event failed: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:error, reason}

      {:error, reason} ->
        Logger.debug("signal event rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: "signal",
      provider: @provider,
      direction: direction,
      external_event_id: fields.external_event_id,
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      external_message_id: fields.external_message_id,
      status: "received",
      payload_summary: fields.raw_summary
    }
    |> Channels.create_event()
    |> event_result()
  end

  defp insert_rejected_event(fields) do
    %{
      channel: "signal",
      provider: @provider,
      direction: "inbound",
      external_event_id:
        Map.get(fields, :external_event_id) || "malformed_#{Ecto.UUID.generate()}",
      external_chat_id: Map.get(fields, :external_chat_id),
      status: "rejected",
      reason: Map.get(fields, :type, "unsupported_event"),
      payload_summary: "unsupported signal event"
    }
    |> Channels.create_event()
    |> event_result(:rejected)
  end

  defp validate_enabled(%{enabled?: true}), do: :ok
  defp validate_enabled(_state), do: {:error, :disabled}

  defp validate_aci(fields, state) do
    allowed =
      state.settings
      |> Map.get("allowed_aci_ids", [])
      |> Enum.map(&Parser.normalize_aci/1)

    cond do
      not Parser.valid_aci?(fields.external_user_id) ->
        {:error, :invalid_signal_aci}

      allowed != [] and fields.external_user_id not in allowed ->
        {:error, :signal_aci_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_text(fields, state) do
    max_text_bytes = Map.get(state.settings, "max_text_bytes", 4000)

    cond do
      not is_binary(fields.text) or String.trim(fields.text) == "" ->
        {:error, :empty_text}

      byte_size(fields.text) > max_text_bytes ->
        {:error, :text_too_large}

      true ->
        :ok
    end
  end

  defp reject_echo(fields) do
    if ChannelThread.echo?(%{
         channel: "signal",
         receiver_account_ref: fields.receiver_account_ref,
         provider_message_id: fields.external_message_id
       }) do
      {:error, :echo_suppressed}
    else
      :ok
    end
  end

  defp resolve_identity(fields, state) do
    Identity.resolve(
      "signal",
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp authorize_inbound(fields, user_id) do
    InboundTrust.authorize(%{
      user_id: user_id,
      channel: "signal",
      provider: @provider,
      surface: "signal_message",
      external_user_id: fields.external_user_id,
      external_chat_id: fields.external_chat_id,
      receiver_account_ref: fields.receiver_account_ref
    })
  end

  defp submit_runtime(text, user_id, session_id, fields, new_thread?, inbound_trust) do
    %{
      text: text,
      channel: "signal",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      new_thread: new_thread?,
      channel_thread_ref: fields.channel_thread_ref,
      provider_message_id: fields.external_message_id,
      metadata: %{
        channel: "signal",
        provider: @provider,
        trust_class: @trust_class,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.external_chat_id,
        external_message_id: fields.external_message_id,
        receiver_account_ref: fields.receiver_account_ref,
        provider_thread_ref: fields.provider_thread_ref,
        inbound_trust: inbound_trust
      }
    }
    |> maybe_put_known_thread_id(fields, new_thread?)
    |> Runtime.submit_user_input()
  end

  defp maybe_put_known_thread_id(attrs, fields, false) do
    case Map.get(fields, :known_thread_id) do
      thread_id when is_binary(thread_id) and thread_id != "" ->
        Map.put(attrs, :thread_id, thread_id)

      _thread_id ->
        attrs
    end
  end

  defp maybe_put_known_thread_id(attrs, _fields, _new_thread?), do: attrs

  defp renderer_opts(state) do
    [
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 4000)
    ]
  end

  defp deliver_chunks(fields, chunks, state) do
    reply_target = reply_target(fields)

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, delivered} ->
      opts =
        state.client_opts
        |> put_quote_opts(reply_target)

      result =
        Client.send_message(
          Map.get(state.settings, "account_identifier"),
          fields.send_recipient,
          chunk,
          opts
        )

      case result do
        {:ok, response} ->
          provider_id = provider_message_id(response) || "out_#{Ecto.UUID.generate()}"

          {:cont,
           {:ok,
            delivered ++
              [
                %{
                  part_id: to_string(index),
                  message_id: provider_id,
                  message: response,
                  quote_timestamp_ms: fields.timestamp_ms
                }
              ]}}

        {:error, reason} ->
          {:halt, {:error, {:delivery_failed, reason}}}
      end
    end)
  end

  defp record_outbound_refs(response, fields, delivered) do
    delivered
    |> Enum.reduce_while(:ok, fn delivered_part, :ok ->
      attrs =
        fields.channel_thread_ref
        |> Map.put(:canonical_message_id, response_value(response, :assistant_message_id))
        |> Map.put(:canonical_thread_id, response_value(response, :thread_id))
        |> Map.put(:provider_message_id, delivered_part.message_id)
        |> Map.put(:part_id, delivered_part.part_id)
        |> Map.put(:direction, :out)
        |> Map.put(:trust_class, @trust_class)

      case ChannelThread.record_message_ref(attrs) do
        {:ok, _ref} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reply_target(fields) do
    descriptor = %{
      threading: :reply_chain,
      reply_key_type: :timestamp
    }

    case ChannelThread.resolve_reply_target(fields.channel_thread_ref, descriptor) do
      {:ok, target} -> target
      {:error, _reason} -> %{threading: :flat, reply_key: %{}}
    end
  end

  defp put_quote_opts(opts, %{threading: :reply_chain, reply_key: reply_key}) do
    opts
    |> Keyword.put(:quote_timestamp_ms, Map.get(reply_key, :timestamp_ms))
    |> Keyword.put(:quote_author, Map.get(reply_key, :author_ref))
  end

  defp put_quote_opts(opts, _reply_target), do: opts

  defp put_thread_fields(fields, state) do
    receiver_account_ref = receiver_account_ref(state)
    provider_thread_ref = provider_thread_ref(fields)

    fields
    |> Map.put(:receiver_account_ref, receiver_account_ref)
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(:channel_thread_ref, channel_thread_ref(receiver_account_ref, provider_thread_ref))
    |> Map.put(:known_thread_id, known_thread_id_from_relation(receiver_account_ref, fields))
  end

  defp maybe_isolate_new_provider_thread(fields, true) do
    provider_thread_ref =
      provider_thread_ref(%{fields | timestamp_ms: System.system_time(:millisecond)})

    fields
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(
      :channel_thread_ref,
      channel_thread_ref(fields.receiver_account_ref, provider_thread_ref)
    )
    |> Map.delete(:known_thread_id)
  end

  defp maybe_isolate_new_provider_thread(fields, _new_thread?), do: fields

  defp receiver_account_ref(state) do
    account =
      state.settings
      |> Map.get("local_aci", Map.get(state.settings, "account_identifier", "configured"))
      |> account_fingerprint()

    "signal:account:#{account}"
  end

  defp provider_thread_ref(fields) do
    %{
      provider: "signal",
      origin_identity_digest: ChannelThread.identity_digest(fields.source_aci),
      provider_thread_root: fields.source_aci,
      source_aci: fields.source_aci,
      message_timestamp_ms: fields.timestamp_ms,
      quote_timestamp_ms: fields.timestamp_ms,
      author_aci: fields.source_aci
    }
  end

  defp channel_thread_ref(receiver_account_ref, provider_thread_ref) do
    %{
      channel: "signal",
      receiver_account_ref: receiver_account_ref,
      provider_thread_ref: provider_thread_ref,
      trust_class: @trust_class
    }
  end

  defp known_thread_id_from_relation(receiver_account_ref, fields) do
    case ChannelThread.lookup_message_thread(%{
           channel: "signal",
           receiver_account_ref: receiver_account_ref,
           provider_message_id: fields.external_message_id
         }) do
      {:ok, thread_id} -> thread_id
      {:error, _reason} -> nil
    end
  end

  defp mark_processed(event, response, user_id, session_id) do
    Channels.update_event(event, %{
      status: "processed",
      user_id: user_id,
      session_id: session_id,
      thread_id: response_value(response, :thread_id),
      input_signal_id: response_value(response, :input_signal_id),
      trace_id: response_value(response, :trace_id)
    })
  end

  defp mark_rejected_or_failed(event, {:delivery_failed, reason}) do
    Channels.update_event(event, %{status: "failed", error: inspect(Redactor.redact(reason))})
  end

  defp mark_rejected_or_failed(event, reason) do
    status =
      if reason in [:disabled, :not_mapped, :signal_aci_not_allowed, :invalid_signal_aci],
        do: "rejected",
        else: "failed"

    Channels.update_event(event, %{status: status, reason: inspect(Redactor.redact(reason))})
  end

  defp event_result(result, inserted_status \\ nil)

  defp event_result({:ok, %AllbertAssist.Channels.Event{} = event}, nil), do: {:ok, event}
  defp event_result({:ok, _event}, inserted_status), do: {:ok, inserted_status}

  defp event_result({:error, %Ecto.Changeset{} = changeset}, _inserted_status) do
    if duplicate_event?(changeset), do: {:ok, :duplicate}, else: {:error, changeset}
  end

  defp duplicate_event?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp provider_message_id(%{"timestamp" => timestamp}), do: to_string(timestamp)
  defp provider_message_id(%{timestamp: timestamp}), do: to_string(timestamp)
  defp provider_message_id(%{"messageId" => id}) when is_binary(id), do: id
  defp provider_message_id(_response), do: nil

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp prompt_text("/new " <> text), do: {String.trim(text), true}
  defp prompt_text(text), do: {text, false}

  defp account_fingerprint(value) when is_binary(value) and value != "" do
    digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    "sha256:#{digest}"
  end

  defp account_fingerprint(_value), do: "configured"

  # v0.54 M10 (ADR 0063): outbound compose boundary callback. `target` is a Signal
  # recipient (ACI/number per the account's identity policy).
  @doc false
  def deliver_outbound(target, body, opts) when is_binary(target) and is_binary(body) do
    with :ok <- ReleaseAvailability.ensure_live_use_allowed({:channel, "signal"}) do
      case AllbertAssist.Channels.channel_settings("signal") do
        {:ok, settings} ->
          account = Map.get(settings, "account_identifier")

          case Client.send_message(account, target, body, Keyword.take(opts, [:req_options])) do
            {:ok, result} -> {:ok, %{channel: "signal", target: target, result: result}}
            {:error, reason} -> {:error, reason}
          end

        _other ->
          {:error, :signal_not_configured}
      end
    end
  end
end
