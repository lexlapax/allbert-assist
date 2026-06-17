defmodule AllbertAssist.Channels.WhatsApp.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ConfirmationCallback
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.WhatsApp.Client
  alias AllbertAssist.Channels.WhatsApp.Parser
  alias AllbertAssist.Channels.WhatsApp.Renderer
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings.Secrets

  @provider "whatsapp_cloud_api"
  @redacted_phone "[REDACTED_PHONE]"

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def handle_webhook_payload(payload, auth_context \\ %{}, opts \\ []) do
    with {:ok, server} <- server(opts),
         {:ok, server} <- live_server(server) do
      GenServer.call(server, {:handle_webhook_payload, payload, auth_context})
    end
  end

  def simulate_webhook_event(server \\ __MODULE__, payload) do
    GenServer.call(server, {:handle_webhook_payload, payload, %{surface: "whatsapp_simulate"}})
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
    {:reply, if(state.enabled?, do: :running, else: :disabled), state}
  end

  def handle_call({:handle_webhook_payload, payload, auth_context}, _from, state) do
    {reply, state} = process_webhook(payload, auth_context, state)
    {:reply, reply, state}
  end

  defp server(opts) do
    case Keyword.get(opts, :server, __MODULE__) do
      pid when is_pid(pid) -> {:ok, pid}
      name when is_atom(name) and not is_nil(name) -> {:ok, name}
      nil -> {:error, :adapter_not_started}
    end
  end

  defp live_server(pid) when is_pid(pid), do: {:ok, pid}

  defp live_server(name) when is_atom(name) do
    case GenServer.whereis(name) do
      nil -> {:error, :adapter_not_started}
      _pid -> {:ok, name}
    end
  end

  defp load_state(opts) do
    settings =
      case Channels.channel_settings("whatsapp") do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    access_token =
      settings
      |> Map.get("access_token_ref")
      |> resolve_access_token()

    %{
      enabled?: Map.get(settings, "enabled", false),
      settings: settings,
      access_token: access_token,
      req_options: Keyword.get(opts, :req_options, []),
      diagnostics: AllbertWhatsApp.Settings.Fragment.required_when_enabled(settings)
    }
  end

  defp resolve_access_token(secret_ref) do
    case Secrets.get_secret(secret_ref) do
      {:ok, token} when is_binary(token) ->
        token = String.trim(token)
        if token == "", do: nil, else: token

      _error ->
        nil
    end
  end

  defp process_webhook(payload, auth_context, state) do
    events = Parser.parse_webhook(payload)

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

  defp process_parsed_event({:button_reply, fields}, auth_context, state),
    do: process_button_event(fields, auth_context, state)

  defp process_parsed_event({:unsupported, fields}, _auth_context, _state),
    do: insert_rejected_event(fields)

  defp process_parsed_event({:malformed, reason}, _auth_context, _state),
    do: {:error, {:malformed, reason}}

  defp process_text_event(fields, auth_context, state) do
    fields = put_thread_fields(fields, state)
    {text, new_thread?} = prompt_text(fields.text)
    command = ConfirmationCallback.parse_typed_command(text)
    fields = maybe_isolate_new_provider_thread(fields, new_thread?)

    case insert_received_event(fields, event_direction(command)) do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        handle_text_event(event, fields, auth_context, state, text, new_thread?, command)

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp event_direction({:ok, _action, _confirmation_id}), do: "callback"
  defp event_direction(:ignore), do: "inbound"

  defp handle_text_event(event, fields, auth_context, state, text, new_thread?, command) do
    with :ok <- validate_enabled(state),
         :ok <- validate_phone(fields, auth_context, state),
         :ok <- validate_text(fields, state),
         :ok <- reject_echo(fields),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id, inbound_surface(command)),
         session_id <-
           Channels.derive_session_id("whatsapp", fields.external_user_id, fields.phone_number_id),
         {:ok, response, callback?} <-
           process_text_or_callback(
             command,
             text,
             user_id,
             session_id,
             fields,
             new_thread?,
             inbound_trust,
             state
           ),
         {:ok, rendered} <- render_processed_response(response, callback?, state),
         {:ok, delivered} <- deliver_rendered(fields, rendered, state),
         :ok <- maybe_record_outbound_refs(callback?, response, fields, delivered),
         {:ok, _event} <- mark_text_processed(callback?, event, response, user_id, session_id) do
      {:ok, :processed}
    else
      {:error, {:delivery_failed, _reason} = reason} ->
        Logger.debug("whatsapp event failed: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:error, reason}

      {:error, reason} ->
        Logger.debug("whatsapp event rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp inbound_surface({:ok, _action, _confirmation_id}), do: :callback
  defp inbound_surface(:ignore), do: :message

  defp process_text_or_callback(
         {:ok, action, confirmation_id},
         _text,
         user_id,
         session_id,
         fields,
         _new_thread?,
         inbound_trust,
         state
       ) do
    with {:ok, response} <-
           ConfirmationCallback.run(%{
             action: action,
             confirmation_id: confirmation_id,
             channel: "whatsapp",
             user_id: user_id,
             identity_proof: identity_proof(fields, state, user_id),
             session_id: session_id,
             surface: "whatsapp_typed_command",
             resolver_metadata: %{
               provider: @provider,
               external_event_id: fields.external_event_id,
               external_user_id: fields.external_user_id,
               external_chat_id: fields.phone_number_id,
               external_message_id: fields.external_message_id,
               command: "ALLBERT:#{String.upcase(to_string(action))}:#{confirmation_id}",
               inbound_trust: inbound_trust
             }
           }) do
      {:ok, response, true}
    end
  end

  defp process_text_or_callback(
         :ignore,
         text,
         user_id,
         session_id,
         fields,
         new_thread?,
         inbound_trust,
         _state
       ) do
    with {:ok, response} <-
           submit_runtime(text, user_id, session_id, fields, new_thread?, inbound_trust) do
      {:ok, response, false}
    end
  end

  defp render_processed_response(response, true, state),
    do: render_confirmation_response(response, state)

  defp render_processed_response(response, false, state) do
    Renderer.render_response(response, renderer_opts(state))
  end

  defp maybe_record_outbound_refs(true, _response, _fields, _delivered), do: :ok

  defp maybe_record_outbound_refs(false, response, fields, delivered) do
    record_outbound_refs(response, fields, delivered)
  end

  defp mark_text_processed(true, event, response, user_id, session_id) do
    mark_callback_processed(event, response, user_id, session_id)
  end

  defp mark_text_processed(false, event, response, user_id, session_id) do
    mark_processed(event, response, user_id, session_id)
  end

  defp process_button_event(fields, auth_context, state) do
    fields = put_thread_fields(fields, state)

    case insert_received_event(fields, "callback") do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        handle_button_event(event, fields, auth_context, state)

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_button_event(event, fields, auth_context, state) do
    with :ok <- validate_enabled(state),
         :ok <- validate_phone(fields, auth_context, state),
         {:ok, user_id} <- resolve_identity(fields, state),
         {:ok, inbound_trust} <- authorize_inbound(fields, user_id, :callback),
         session_id <-
           Channels.derive_session_id("whatsapp", fields.external_user_id, fields.phone_number_id),
         {:ok, response} <-
           run_confirmation_callback(fields, state, user_id, session_id, inbound_trust),
         {:ok, rendered} <- render_confirmation_response(response, state),
         {:ok, _delivered} <- deliver_rendered(fields, rendered, state),
         {:ok, _event} <- mark_callback_processed(event, response, user_id, session_id) do
      {:ok, :processed}
    else
      {:error, {:delivery_failed, _reason} = reason} ->
        Logger.debug("whatsapp callback failed: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:error, reason}

      {:error, reason} ->
        Logger.debug("whatsapp callback rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: "whatsapp",
      provider: @provider,
      direction: direction,
      external_event_id: fields.external_event_id,
      external_user_id: fields.external_user_id,
      external_chat_id: fields.phone_number_id,
      external_message_id: fields.external_message_id,
      status: "received",
      payload_summary: fields.raw_summary
    }
    |> Channels.create_event()
    |> event_result()
  end

  defp insert_rejected_event(fields) do
    %{
      channel: "whatsapp",
      provider: @provider,
      direction: "inbound",
      external_event_id:
        Map.get(fields, :external_event_id) || "malformed_#{Ecto.UUID.generate()}",
      external_chat_id: Map.get(fields, :external_chat_id),
      status: "rejected",
      reason: Map.get(fields, :type, "unsupported_event"),
      payload_summary: "unsupported whatsapp event"
    }
    |> Channels.create_event()
    |> event_result(:rejected)
  end

  defp validate_enabled(%{enabled?: true}), do: :ok
  defp validate_enabled(_state), do: {:error, :disabled}

  defp validate_phone(fields, auth_context, state) do
    configured = Map.get(state.settings, "phone_number_id")
    path_phone = auth_field(auth_context, :phone_number_id)

    cond do
      blank?(fields.phone_number_id) ->
        {:error, :missing_phone_number_id}

      not blank?(configured) and fields.phone_number_id != configured ->
        {:error, :phone_number_id_mismatch}

      not blank?(path_phone) and fields.phone_number_id != path_phone ->
        {:error, :webhook_phone_number_id_mismatch}

      true ->
        :ok
    end
  end

  defp validate_text(fields, state) do
    max_text_bytes = Map.get(state.settings, "max_text_bytes", 4096)

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
         channel: "whatsapp",
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
      "whatsapp",
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp authorize_inbound(fields, user_id, surface) do
    InboundTrust.authorize(%{
      user_id: user_id,
      channel: "whatsapp",
      provider: @provider,
      surface: "whatsapp_#{surface}",
      external_user_id: fields.external_user_id,
      external_chat_id: fields.phone_number_id,
      receiver_account_ref: fields.receiver_account_ref
    })
  end

  defp submit_runtime(text, user_id, session_id, fields, new_thread?, inbound_trust) do
    %{
      text: text,
      channel: "whatsapp",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      new_thread: new_thread?,
      channel_thread_ref: fields.channel_thread_ref,
      provider_message_id: fields.external_message_id,
      metadata: %{
        channel: "whatsapp",
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.phone_number_id,
        external_message_id: fields.external_message_id,
        receiver_account_ref: fields.receiver_account_ref,
        provider_thread_ref: fields.provider_thread_ref,
        context_message_id: fields.context_message_id,
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

  defp run_confirmation_callback(fields, state, user_id, session_id, inbound_trust) do
    ConfirmationCallback.run(%{
      action: fields.verb,
      confirmation_id: fields.confirmation_id,
      channel: "whatsapp",
      user_id: user_id,
      identity_proof: identity_proof(fields, state, user_id),
      session_id: session_id,
      surface: "whatsapp_button",
      resolver_metadata: %{
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.phone_number_id,
        external_message_id: fields.external_message_id,
        callback_data: fields.button_id,
        inbound_trust: inbound_trust
      }
    })
  end

  defp identity_proof(fields, state, user_id) do
    %{
      channel: "whatsapp",
      external_user_id: fields.external_user_id,
      user_id: user_id,
      identity_map: Map.get(state.settings, "identity_map", []),
      receiver_account_ref: fields.receiver_account_ref,
      external_chat_id: fields.phone_number_id
    }
  end

  defp render_confirmation_response(response, state) do
    Renderer.render_response(%{message: ConfirmationCallback.reply_text(response)},
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 4096),
      render_buttons: false
    )
  end

  defp renderer_opts(state) do
    [
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 4096),
      render_buttons: Map.get(state.settings, "render_approval_buttons", true)
    ]
  end

  defp deliver_rendered(fields, rendered, state) do
    rendered
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, delivered} ->
      opts =
        [
          context_message_id: context_message_id(fields, state),
          api_version: Map.get(state.settings, "graph_api_version", "v23.0")
        ] ++ state.req_options

      result =
        case message do
          %{type: :interactive_buttons, body: body, buttons: buttons} ->
            Client.send_interactive_buttons(
              state.access_token,
              fields.phone_number_id,
              fields.external_user_id,
              body,
              buttons,
              opts
            )

          %{type: :text, body: body} ->
            Client.send_text(
              state.access_token,
              fields.phone_number_id,
              fields.external_user_id,
              body,
              opts
            )
        end

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
                  payload: message,
                  quote_degradation: quote_degradation(fields, state)
                }
              ]}}

        {:error, reason} ->
          {:halt, {:error, {:delivery_failed, reason}}}
      end
    end)
  end

  defp context_message_id(fields, state) do
    case reply_target(fields, state) do
      %{threading: :reply_chain} -> fields.external_message_id
      _target -> nil
    end
  end

  defp quote_degradation(fields, state) do
    case reply_target(fields, state) do
      %{degradation: degradation} -> degradation
      _target -> :none
    end
  end

  defp reply_target(fields, state) do
    descriptor = %{
      threading: :reply_chain,
      reply_key_type: :opaque_id,
      quote_ttl_ms: Map.get(state.settings, "quote_ttl_ms", 86_400_000)
    }

    case ChannelThread.resolve_reply_target(fields.channel_thread_ref, descriptor) do
      {:ok, target} -> target
      {:error, _reason} -> %{threading: :flat, degradation: :none}
    end
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

      case ChannelThread.record_message_ref(attrs) do
        {:ok, _ref} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_thread_fields(fields, state) do
    receiver_account_ref = receiver_account_ref(fields, state)
    provider_thread_ref = provider_thread_ref(fields)

    fields
    |> Map.put(:receiver_account_ref, receiver_account_ref)
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(:channel_thread_ref, channel_thread_ref(receiver_account_ref, provider_thread_ref))
    |> Map.put(:known_thread_id, known_thread_id_from_relation(receiver_account_ref, fields))
  end

  defp maybe_isolate_new_provider_thread(fields, true) do
    provider_thread_ref = provider_thread_ref(%{fields | context_message_id: nil})

    fields
    |> Map.put(:provider_thread_ref, provider_thread_ref)
    |> Map.put(
      :channel_thread_ref,
      channel_thread_ref(fields.receiver_account_ref, provider_thread_ref)
    )
    |> Map.delete(:known_thread_id)
  end

  defp maybe_isolate_new_provider_thread(fields, _new_thread?), do: fields

  defp receiver_account_ref(fields, state) do
    waba_id = Map.get(state.settings, "waba_id") || fields.waba_id || "unknown"
    display = fields.display_phone_number || fields.phone_number_id || "unknown"
    "whatsapp:waba:#{waba_id}:phone:#{redact_phone(display)}"
  end

  defp provider_thread_ref(fields) do
    %{
      provider: "whatsapp",
      phone_number_id: fields.phone_number_id,
      provider_thread_root: fields.context_message_id || fields.external_message_id,
      context_message_id: fields.context_message_id,
      quoted_message_id: fields.external_message_id,
      quote_timestamp_ms: fields.timestamp_ms,
      from: redact_phone(fields.external_user_id)
    }
    |> compact()
  end

  defp channel_thread_ref(receiver_account_ref, provider_thread_ref) do
    %{
      channel: "whatsapp",
      receiver_account_ref: receiver_account_ref,
      provider_thread_ref: provider_thread_ref
    }
  end

  defp known_thread_id_from_relation(receiver_account_ref, fields) do
    [fields.context_message_id]
    |> Enum.find_value(fn message_id ->
      if is_binary(message_id) and message_id != "" do
        case ChannelThread.lookup_message_thread(%{
               channel: "whatsapp",
               receiver_account_ref: receiver_account_ref,
               provider_message_id: message_id
             }) do
          {:ok, thread_id} -> thread_id
          {:error, _reason} -> nil
        end
      end
    end)
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

  defp mark_callback_processed(event, response, user_id, session_id) do
    Channels.update_event(event, %{
      status: "processed",
      user_id: user_id,
      session_id: session_id,
      input_signal_id:
        response_value(response_value(response, :runner_metadata) || %{}, :requested_signal_id)
    })
  end

  defp mark_rejected_or_failed(event, {:delivery_failed, reason}) do
    Channels.update_event(event, %{status: "failed", error: inspect(Redactor.redact(reason))})
  end

  defp mark_rejected_or_failed(event, reason) do
    status =
      if reason in [
           :disabled,
           :not_mapped,
           :phone_number_id_mismatch,
           :webhook_phone_number_id_mismatch
         ] do
        "rejected"
      else
        "failed"
      end

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

  defp provider_message_id(%{"messages" => [%{"id" => id} | _rest]}) when is_binary(id), do: id
  defp provider_message_id(%{messages: [%{id: id} | _rest]}) when is_binary(id), do: id
  defp provider_message_id(_response), do: nil

  defp auth_field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp auth_field(_map, _key), do: nil

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp prompt_text("/new " <> text), do: {String.trim(text), true}
  defp prompt_text(text), do: {text, false}

  defp blank?(value), do: value in [nil, ""]

  defp redact_phone(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> case do
        "+" <> _rest = phone -> phone
        <<digit, _rest::binary>> = phone when digit in ?0..?9 -> "+" <> phone
        other -> other
      end

    case Redactor.redact(value) do
      ^value -> @redacted_phone
      redacted -> redacted
    end
  end

  defp redact_phone(_value), do: @redacted_phone

  defp compact(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", %{}, []] end)
  end

  # v0.54 M10 (ADR 0063): outbound compose boundary callback. `target` is a WhatsApp
  # recipient phone number (E.164).
  @doc false
  def deliver_outbound(target, body, _opts) when is_binary(target) and is_binary(body) do
    with {:ok, settings} <- AllbertAssist.Channels.channel_settings("whatsapp"),
         {:ok, token} <-
           AllbertAssist.Settings.Secrets.get_secret(Map.get(settings, "access_token_ref")),
         phone_id when is_binary(phone_id) <- Map.get(settings, "phone_number_id"),
         {:ok, result} <- Client.send_text(token, phone_id, target, body, []) do
      {:ok, %{channel: "whatsapp", target: target, result: result}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :whatsapp_not_configured}
    end
  end
end
