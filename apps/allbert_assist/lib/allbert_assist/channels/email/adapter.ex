defmodule AllbertAssist.Channels.Email.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email.Parser
  alias AllbertAssist.Settings.Secrets

  @provider "email_imap"
  @max_backoff_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def poll_once(server \\ __MODULE__), do: GenServer.call(server, :poll_once, 30_000)

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
      settings: %{},
      credentials: %{},
      backoff_ms: 0,
      poll_interval_ms: 60_000,
      imap_client: Keyword.get(opts, :imap_client, AllbertAssist.Channels.Email.ImapClient),
      smtp_client: Keyword.get(opts, :smtp_client, AllbertAssist.Channels.Email.SmtpClient),
      client_opts: Keyword.get(opts, :client_opts, [])
    }

    with {:ok, settings} <- Channels.channel_settings("email"),
         true <- Map.get(settings, "enabled", false),
         {:ok, credentials} <- resolve_credentials(settings) do
      %{
        base
        | enabled?: true,
          settings: settings,
          credentials: credentials,
          poll_interval_ms: Map.get(settings, "imap_poll_interval_ms", 60_000)
      }
    else
      false -> %{base | diagnostics: [:disabled]}
      {:error, reason} -> %{base | diagnostics: [reason]}
    end
  end

  defp resolve_credentials(settings) do
    with {:ok, imap_password} <- secret(settings, "imap_password_ref", :missing_imap_password),
         {:ok, smtp_password} <- secret(settings, "smtp_password_ref", :missing_smtp_password) do
      {:ok, %{imap_password: imap_password, smtp_password: smtp_password}}
    end
  end

  defp secret(settings, key, reason) do
    case Secrets.get_secret(Map.get(settings, key)) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp poll(%{enabled?: false} = state), do: {{:error, :disabled}, state}

  defp poll(%{enabled?: true} = state) do
    case poll_imap(state) do
      {:ok, summary} ->
        {{:ok, summary}, %{state | backoff_ms: 0}}

      {:error, reason} ->
        Logger.warning("email poll failed: #{inspect(redact(reason))}")
        {{:error, reason}, %{state | backoff_ms: next_backoff(state.backoff_ms)}}
    end
  end

  defp poll_imap(state) do
    settings = state.settings
    client = state.imap_client

    with {:ok, conn} <-
           client.connect(
             Map.fetch!(settings, "imap_host"),
             Map.fetch!(settings, "imap_port"),
             imap_opts(state)
           ),
         {:ok, conn} <-
           client.login(
             conn,
             Map.fetch!(settings, "imap_username"),
             state.credentials.imap_password
           ),
         {:ok, conn} <- client.select_mailbox(conn, Map.fetch!(settings, "imap_mailbox")),
         {:ok, uids} <- client.search_unseen(conn) do
      summary =
        Enum.reduce(uids, %{processed: 0, duplicates: 0, rejected: 0, failed: 0}, fn uid,
                                                                                     summary ->
          status = process_uid(client, conn, uid)
          Map.update!(summary, status, &(&1 + 1))
        end)

      client.logout(conn)
      {:ok, summary}
    end
  end

  defp process_uid(client, conn, uid) do
    case client.fetch_message(conn, uid) do
      {:ok, raw_email} ->
        process_raw_email(client, conn, uid, raw_email)

      {:error, _reason} ->
        :failed
    end
  end

  defp process_raw_email(client, conn, uid, raw_email) do
    status =
      case Parser.parse_email(raw_email) do
        {:ok, fields} ->
          insert_received_event(fields, uid)

        {:error, reason} ->
          Logger.warning("email parse rejected uid=#{uid}: #{inspect(reason)}")
          :rejected
      end

    _mark_seen_result = client.mark_seen(conn, uid)
    status
  end

  defp insert_received_event(fields, uid) do
    %{
      channel: "email",
      provider: @provider,
      direction: "inbound",
      external_event_id: fields.message_id,
      external_user_id: fields.from_address,
      external_chat_id: nil,
      external_message_id: to_string(uid),
      status: "received",
      payload_summary: payload_summary(fields)
    }
    |> Channels.create_event()
    |> event_result()
  end

  defp payload_summary(fields) do
    [
      "from=#{fields.from_address}",
      "subject=#{fields.subject}",
      "attachments=#{fields.attachment_count}"
    ]
    |> Enum.join(" ")
  end

  defp event_result({:ok, _event}), do: :processed

  defp event_result({:error, %Ecto.Changeset{} = changeset}) do
    if duplicate_event?(changeset), do: :duplicates, else: :failed
  end

  defp duplicate_event?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp imap_opts(state) do
    [
      ssl: Map.get(state.settings, "imap_ssl", true),
      test_pid: Keyword.get(state.client_opts, :test_pid),
      fake_name: Keyword.get(state.client_opts, :fake_name)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp next_backoff(0), do: 1000
  defp next_backoff(backoff_ms), do: min(backoff_ms * 2, @max_backoff_ms)

  defp schedule_poll(%{enabled?: false}), do: :ok

  defp schedule_poll(state) do
    delay = if state.backoff_ms > 0, do: state.backoff_ms, else: state.poll_interval_ms
    Process.send_after(self(), :poll, delay)
    :ok
  end

  defp redact({:imap_command_failed, response}), do: {:imap_command_failed, response}
  defp redact(reason), do: reason
end
