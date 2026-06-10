defmodule AllbertAssist.Channels.Discord.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Discord.Client
  alias AllbertAssist.Channels.Discord.Parser
  alias AllbertAssist.Channels.Discord.Renderer
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor

  @provider "discord_gateway"

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def simulate_gateway_event(server \\ __MODULE__, event) do
    GenServer.call(server, {:simulate_gateway_event, event})
  end

  @impl true
  def init(opts) do
    state = load_state(opts)
    {:ok, state}
  end

  @impl true
  def handle_call({:simulate_gateway_event, event}, _from, state) do
    {reply, state} = process_gateway_event(event, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:discord_gateway_event, event}, state) do
    {_reply, state} = process_gateway_event(event, state)
    {:noreply, state}
  end

  defp load_state(opts) do
    settings =
      case Channels.channel_settings("discord") do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    %{
      enabled?: Map.get(settings, "enabled", false),
      settings: settings,
      token_ref: Map.get(settings, "bot_token_ref", "secret://channels/discord/bot_token"),
      client_opts: Keyword.get(opts, :client_opts, []),
      diagnostics: AllbertDiscord.Settings.Fragment.required_when_enabled(settings),
      last_ready: nil
    }
  end

  defp process_gateway_event(event, state) do
    case Parser.parse_gateway_event(event) do
      {:ready, fields} ->
        {{:ok, {:ready, fields}}, %{state | last_ready: DateTime.utc_now()}}

      {:message_create, fields} ->
        {handle_message(fields, state), state}

      {:interaction_create, fields} ->
        {insert_rejected_event(fields.external_event_id, "interaction_deferred_to_m5"), state}

      {:unsupported, fields} ->
        {insert_rejected_event(fields.external_event_id, fields.type), state}

      {:malformed, reason} ->
        {{:error, {:malformed, reason}}, state}
    end
  end

  defp handle_message(fields, state) do
    case insert_received_event(fields, "inbound") do
      {:ok, %AllbertAssist.Channels.Event{} = event} ->
        process_received_message(event, fields, state)

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: "discord",
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

  defp insert_rejected_event(external_event_id, reason) do
    %{
      channel: "discord",
      provider: @provider,
      direction: "inbound",
      external_event_id: external_event_id,
      status: "rejected",
      reason: to_string(reason),
      payload_summary: "unsupported discord event"
    }
    |> Channels.create_event()
    |> event_result(:rejected)
  end

  defp process_received_message(event, fields, state) do
    with :ok <- validate_allowlist(fields, state),
         :ok <- validate_text(fields, state),
         :ok <- reject_echo(fields),
         {:ok, user_id} <- resolve_identity(fields, state),
         session_id <- session_id(fields),
         {:ok, response} <- submit_runtime(fields, user_id, session_id),
         {:ok, rendered} <- Renderer.render_response(response, renderer_opts(state)),
         {:ok, delivered} <- deliver_rendered(fields, rendered, state),
         :ok <- record_outbound_refs(response, fields, delivered),
         {:ok, event} <- mark_processed(event, response, user_id, session_id) do
      {:ok, {:processed, event, rendered}}
    else
      {:error, reason} ->
        Logger.debug("discord simulated event rejected: #{inspect(Redactor.redact(reason))}")
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        {:ok, :rejected}
    end
  end

  defp validate_allowlist(fields, state) do
    allowed_guild_ids = Map.get(state.settings, "allowed_guild_ids", [])
    allowed_channel_ids = Map.get(state.settings, "allowed_channel_ids", [])

    cond do
      fields.dm? ->
        :ok

      fields.guild_id not in allowed_guild_ids ->
        {:error, :guild_not_allowed}

      allowed_channel_ids != [] and fields.channel_id not in allowed_channel_ids and
          fields.parent_channel_id not in allowed_channel_ids ->
        {:error, :channel_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_text(fields, state) do
    max_text_bytes = Map.get(state.settings, "max_text_bytes", 2000)

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
         channel: "discord",
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
      "discord",
      fields.external_user_id,
      Map.get(state.settings, "identity_map", [])
    )
  end

  defp session_id(fields) do
    Channels.derive_session_id(
      "discord",
      fields.external_user_id,
      fields.thread_channel_id || fields.channel_id
    )
  end

  defp submit_runtime(fields, user_id, session_id) do
    Runtime.submit_user_input(%{
      text: fields.text,
      channel: "discord",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      channel_thread_ref: fields.channel_thread_ref,
      provider_message_id: fields.external_message_id,
      metadata: %{
        channel: "discord",
        provider: @provider,
        external_event_id: fields.external_event_id,
        external_user_id: fields.external_user_id,
        external_chat_id: fields.external_chat_id,
        external_message_id: fields.external_message_id,
        receiver_account_ref: fields.receiver_account_ref,
        provider_thread_ref: fields.provider_thread_ref,
        message_reference: fields.message_reference
      }
    })
  end

  defp renderer_opts(state) do
    [
      max_text_bytes: Map.get(state.settings, "max_text_bytes", 2000),
      render_buttons: Map.get(state.settings, "render_approval_buttons", true)
    ]
  end

  defp deliver_rendered(fields, rendered, state) do
    rendered
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {payload, index}, {:ok, delivered} ->
      payload = put_reply_reference(payload, fields)

      case Client.create_message(
             state.token_ref,
             fields.thread_channel_id || fields.channel_id,
             payload,
             state.client_opts
           ) do
        {:ok, message} ->
          {:cont, {:ok, delivered ++ [%{part_id: to_string(index), message: message}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp put_reply_reference(payload, %{message_reference: nil}), do: payload

  defp put_reply_reference(payload, fields) do
    Map.put(payload, :message_reference, fields.message_reference)
  end

  defp record_outbound_refs(response, fields, delivered) do
    delivered
    |> Enum.reduce_while(:ok, fn delivered_part, :ok ->
      message = delivered_part.message

      attrs =
        fields.channel_thread_ref
        |> Map.put(:canonical_message_id, response_value(response, :assistant_message_id))
        |> Map.put(:canonical_thread_id, response_value(response, :thread_id))
        |> Map.put(:provider_message_id, Map.get(message, "id"))
        |> Map.put(:part_id, delivered_part.part_id)
        |> Map.put(:direction, :out)

      case ChannelThread.record_message_ref(attrs) do
        {:ok, _ref} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
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

  defp mark_rejected_or_failed(event, reason) do
    status =
      case reason do
        reason
        when reason in [:guild_not_allowed, :channel_not_allowed, :not_mapped, :disabled] ->
          "rejected"

        _reason ->
          "failed"
      end

    Channels.update_event(event, %{status: status, reason: inspect(Redactor.redact(reason))})
  end

  defp event_result({:ok, %AllbertAssist.Channels.Event{} = event}, success),
    do: {:ok, success || event}

  defp event_result({:error, %Ecto.Changeset{errors: errors} = changeset}, _success) do
    if Keyword.has_key?(errors, :external_event_id) do
      {:ok, :duplicate}
    else
      {:error, changeset}
    end
  end

  defp event_result(result, _success), do: result
  defp event_result(result), do: event_result(result, nil)

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end
end
