defmodule AllbertAssist.Channels.Telegram.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Telegram.Client
  alias AllbertAssist.Channels.Telegram.Parser
  alias AllbertAssist.Settings.Secrets

  @provider "telegram_bot_api"
  @max_backoff_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def poll_once(server \\ __MODULE__), do: GenServer.call(server, :poll_once)

  @impl true
  def init(opts) do
    state = load_state(opts)

    if state.enabled? and Keyword.get(opts, :auto_poll?, true) do
      Process.send_after(self(), :poll, 0)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:poll_once, _from, state) do
    {reply, state} = poll(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_reply, state} = poll(state)
    schedule_poll(state)
    {:noreply, state}
  end

  defp load_state(opts) do
    base = %{
      enabled?: false,
      diagnostics: [],
      token: nil,
      settings: %{},
      offset: 0,
      backoff_ms: 0,
      poll_interval_ms: 2000,
      poll_timeout_seconds: 25,
      req_options: Keyword.get(opts, :req_options, [])
    }

    with {:ok, settings} <- Channels.channel_settings("telegram"),
         true <- Map.get(settings, "enabled", false),
         {:ok, token} <- resolve_token(settings) do
      %{
        base
        | enabled?: true,
          token: token,
          settings: settings,
          offset: Channels.max_inbound_integer_event_id("telegram") + 1,
          poll_interval_ms: Map.get(settings, "poll_interval_ms", 2000),
          poll_timeout_seconds: Map.get(settings, "poll_timeout_seconds", 25)
      }
    else
      false -> %{base | diagnostics: [:disabled]}
      {:error, reason} -> %{base | diagnostics: [reason]}
    end
  end

  defp resolve_token(settings) do
    ref = Map.get(settings, "bot_token_ref")

    case Secrets.get_secret(ref) do
      {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _token} -> {:error, :missing_bot_token}
      {:error, _reason} -> {:error, :missing_bot_token}
    end
  end

  defp poll(%{enabled?: false} = state), do: {{:error, :disabled}, state}

  defp poll(%{enabled?: true} = state) do
    case Client.get_updates(
           state.token,
           state.offset,
           state.poll_timeout_seconds,
           state.req_options
         ) do
      {:ok, updates} when is_list(updates) ->
        {summary, offset} = process_updates(updates, state.offset)
        {{:ok, summary}, %{state | offset: offset, backoff_ms: 0}}

      {:error, reason} ->
        Logger.warning("telegram poll failed: #{inspect(redact(reason))}")
        {{:error, reason}, %{state | backoff_ms: next_backoff(state.backoff_ms)}}
    end
  end

  defp process_updates(updates, offset) do
    Enum.reduce(
      updates,
      {%{processed: 0, duplicates: 0, rejected: 0, failed: 0}, offset},
      fn update, {summary, offset} ->
        next_offset = max(offset, update_id(update) + 1)

        case process_update(update) do
          {:ok, :processed} -> {Map.update!(summary, :processed, &(&1 + 1)), next_offset}
          {:ok, :duplicate} -> {Map.update!(summary, :duplicates, &(&1 + 1)), next_offset}
          {:ok, :rejected} -> {Map.update!(summary, :rejected, &(&1 + 1)), next_offset}
          {:error, _reason} -> {Map.update!(summary, :failed, &(&1 + 1)), next_offset}
        end
      end
    )
  end

  defp process_update(update) do
    case Parser.parse_update(update) do
      {:text_message, fields} ->
        insert_received_event(fields, "inbound")

      {:callback_query, fields} ->
        insert_received_event(fields, "callback")

      {:unsupported, %{external_event_id: external_event_id, type: type}} ->
        insert_rejected_event(external_event_id, type)

      {:malformed, reason} ->
        {:error, {:malformed, reason}}
    end
  end

  defp insert_received_event(fields, direction) do
    %{
      channel: "telegram",
      provider: @provider,
      direction: direction,
      external_event_id: fields.external_event_id,
      external_user_id: Map.get(fields, :external_user_id),
      external_chat_id: Map.get(fields, :external_chat_id),
      external_message_id: Map.get(fields, :external_message_id),
      status: "received",
      payload_summary: Map.get(fields, :raw_summary)
    }
    |> Channels.create_event()
    |> event_result()
  end

  defp insert_rejected_event(external_event_id, reason) do
    %{
      channel: "telegram",
      provider: @provider,
      direction: "inbound",
      external_event_id: external_event_id,
      status: "rejected",
      reason: reason,
      payload_summary: "unsupported telegram update"
    }
    |> Channels.create_event()
    |> event_result(:rejected)
  end

  defp event_result(result, inserted_status \\ :processed)

  defp event_result({:ok, _event}, inserted_status), do: {:ok, inserted_status}

  defp event_result({:error, %Ecto.Changeset{} = changeset}, _inserted_status) do
    if duplicate_event?(changeset), do: {:ok, :duplicate}, else: {:error, changeset}
  end

  defp duplicate_event?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp update_id(%{"update_id" => update_id}) when is_integer(update_id), do: update_id

  defp update_id(%{"update_id" => update_id}) do
    case Integer.parse(to_string(update_id)) do
      {integer, ""} -> integer
      _other -> 0
    end
  end

  defp update_id(_update), do: 0

  defp next_backoff(0), do: 1000
  defp next_backoff(backoff_ms), do: min(backoff_ms * 2, @max_backoff_ms)

  defp schedule_poll(%{enabled?: false}), do: :ok

  defp schedule_poll(state) do
    delay = if state.backoff_ms > 0, do: state.backoff_ms, else: state.poll_interval_ms
    Process.send_after(self(), :poll, delay)
    :ok
  end

  defp redact({:telegram_error, status, body}), do: {:telegram_error, status, body}
  defp redact({:transport_error, reason}), do: {:transport_error, reason}
  defp redact(reason), do: reason
end
