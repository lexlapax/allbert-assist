defmodule AllbertAssist.Channels.Email.Adapter do
  @moduledoc false

  use GenServer

  require Logger

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email.Parser
  alias AllbertAssist.Channels.Email.Renderer
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Runtime
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
          status = process_uid(state, client, conn, uid)
          Map.update!(summary, status, &(&1 + 1))
        end)

      client.logout(conn)
      {:ok, summary}
    end
  end

  defp process_uid(state, client, conn, uid) do
    case client.fetch_message(conn, uid) do
      {:ok, raw_email} ->
        process_raw_email(state, client, conn, uid, raw_email)

      {:error, _reason} ->
        :failed
    end
  end

  defp process_raw_email(state, client, conn, uid, raw_email) do
    status =
      case Parser.parse_email(raw_email) do
        {:ok, fields} ->
          case insert_received_event(fields, uid, event_direction(fields, state)) do
            {:ok, %AllbertAssist.Channels.Event{} = event} ->
              process_parsed_email(state, event, fields, uid)

            {:ok, :duplicate} ->
              :duplicates

            {:error, _reason} ->
              :failed
          end

        {:error, reason} ->
          Logger.warning("email parse rejected uid=#{uid}: #{inspect(reason)}")
          :rejected
      end

    _mark_seen_result = client.mark_seen(conn, uid)
    status
  end

  defp process_parsed_email(state, event, fields, uid) do
    with {:regular_text, text_body} <- email_text_body(fields, state),
         :ok <- validate_body_size(text_body, state),
         {:ok, user_id} <- resolve_identity(fields, state),
         session_id <- Channels.derive_session_id("email", fields.from_address, nil),
         {text, new_thread?} <- prompt_text(fields.subject, text_body),
         {:ok, response} <- submit_runtime(text, user_id, session_id, fields, uid, new_thread?),
         {:ok, subject, body, _html_body} <- render_response(response, fields, state),
         :ok <- deliver_reply(fields, subject, body, state),
         {:ok, _event} <- mark_processed(event, response, user_id, session_id) do
      :processed
    else
      {:command, action, confirmation_id} ->
        handle_email_command(state, event, fields, uid, action, confirmation_id)

      {:error, reason} ->
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        rejected_or_failed(reason)
    end
  end

  defp insert_received_event(fields, uid, direction) do
    %{
      channel: "email",
      provider: @provider,
      direction: direction,
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

  defp event_direction(fields, state) do
    case command_from_selected_body(fields, state) do
      {:command, _action, _confirmation_id} -> "callback"
      :regular_text -> "inbound"
    end
  end

  defp email_text_body(fields, state) do
    with {:ok, body} <- selected_email_body(fields, state) do
      case command_from_text(body) do
        {:command, action, confirmation_id} -> {:command, action, confirmation_id}
        :regular_text -> {:regular_text, String.trim(body)}
      end
    end
  end

  defp selected_email_body(fields, state) do
    cond do
      present?(fields.text_body) ->
        {:ok, fields.text_body}

      present?(fields.html_body) and Map.get(state.settings, "allow_html_replies", false) ->
        {:ok, strip_html(fields.html_body)}

      present?(fields.html_body) ->
        {:error, :html_only}

      true ->
        {:error, :empty_body}
    end
  end

  defp validate_body_size(text_body, state) do
    max_body_bytes = Map.get(state.settings, "max_body_bytes", 65_536)

    if byte_size(text_body) <= max_body_bytes do
      :ok
    else
      {:error, :oversized}
    end
  end

  defp resolve_identity(fields, state) do
    Identity.resolve("email", fields.from_address, Map.get(state.settings, "identity_map", []))
  end

  defp handle_email_command(state, event, fields, uid, action, confirmation_id) do
    with {:ok, user_id} <- resolve_identity(fields, state),
         session_id <- Channels.derive_session_id("email", fields.from_address, nil),
         {:ok, response} <-
           run_confirmation_action(action, confirmation_id, user_id, session_id, fields, uid),
         {:ok, subject, body, _html_body} <- render_confirmation_response(response, fields, state),
         :ok <- deliver_reply(fields, subject, body, state),
         {:ok, _event} <- mark_callback_processed(event, response, user_id, session_id) do
      :processed
    else
      {:error, reason} ->
        {:ok, _event} = mark_rejected_or_failed(event, reason)
        rejected_or_failed(reason)
    end
  end

  defp run_confirmation_action(action, confirmation_id, user_id, session_id, fields, uid) do
    Runner.run(confirmation_action_name(action), %{id: confirmation_id}, %{
      actor: user_id,
      channel: "email",
      surface: "email_command",
      session_id: session_id,
      request: %{
        user_id: user_id,
        operator_id: user_id,
        channel: "email",
        session_id: session_id
      },
      resolver_metadata: %{
        provider: @provider,
        external_event_id: fields.message_id,
        external_user_id: fields.from_address,
        external_chat_id: nil,
        external_message_id: to_string(uid),
        in_reply_to: fields.in_reply_to
      }
    })
  end

  defp confirmation_action_name("approve"), do: "approve_confirmation"
  defp confirmation_action_name("deny"), do: "deny_confirmation"
  defp confirmation_action_name("show"), do: "show_confirmation"

  defp render_confirmation_response(response, fields, state) do
    Renderer.render_response(%{message: confirmation_reply(response)},
      subject: fields.subject,
      max_body_bytes: Map.get(state.settings, "max_body_bytes", 65_536)
    )
  end

  defp prompt_text(_subject, "/new " <> text), do: {String.trim(text), true}

  defp prompt_text("New: " <> subject, text) do
    prompt = subject |> String.trim() |> empty_to(text)
    {prompt, true}
  end

  defp prompt_text(_subject, text), do: {text, false}

  defp submit_runtime(text, user_id, session_id, fields, uid, new_thread?) do
    Runtime.submit_user_input(%{
      text: text,
      channel: "email",
      user_id: user_id,
      operator_id: user_id,
      session_id: session_id,
      new_thread: new_thread?,
      metadata: %{
        channel: "email",
        provider: @provider,
        external_event_id: fields.message_id,
        external_user_id: fields.from_address,
        external_chat_id: nil,
        external_message_id: to_string(uid),
        subject: fields.subject,
        in_reply_to: fields.in_reply_to
      }
    })
  end

  defp render_response(response, fields, state) do
    Renderer.render_response(response,
      subject: fields.subject,
      max_body_bytes: Map.get(state.settings, "max_body_bytes", 65_536)
    )
  end

  defp deliver_reply(fields, subject, body, state) do
    settings = state.settings

    opts =
      [
        host: Map.fetch!(settings, "smtp_host"),
        port: Map.fetch!(settings, "smtp_port"),
        username: Map.get(settings, "smtp_username"),
        password: state.credentials.smtp_password,
        tls: Map.get(settings, "smtp_tls", true),
        from_name: Map.get(settings, "from_name"),
        in_reply_to: fields.message_id,
        references: references(fields),
        test_pid: Keyword.get(state.client_opts, :test_pid)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case state.smtp_client.send(
           Map.fetch!(settings, "from_address"),
           fields.from_address,
           subject,
           body,
           opts
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:delivery_failed, reason}}
    end
  end

  defp references(%{references: references, message_id: message_id})
       when is_binary(references) and references != "" do
    references <> " <#{message_id}>"
  end

  defp references(fields), do: "<#{fields.message_id}>"

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
    Channels.update_event(event, %{status: "failed", error: inspect(redact(reason))})
  end

  defp mark_rejected_or_failed(event, reason) do
    Channels.update_event(event, %{status: "rejected", reason: inspect(reason)})
  end

  defp mark_callback_processed(event, response, user_id, session_id) do
    runner_metadata = response_value(response, :runner_metadata) || %{}

    Channels.update_event(event, %{
      status: "processed",
      user_id: user_id,
      session_id: session_id,
      input_signal_id: response_value(runner_metadata, :requested_signal_id)
    })
  end

  defp rejected_or_failed({:delivery_failed, _reason}), do: :failed
  defp rejected_or_failed(_reason), do: :rejected

  defp command_from_selected_body(fields, state) do
    case selected_email_body(fields, state) do
      {:ok, body} -> command_from_text(body)
      {:error, _reason} -> :regular_text
    end
  end

  defp command_from_text(text) when is_binary(text), do: Parser.detect_command(text)
  defp command_from_text(_text), do: :regular_text

  defp confirmation_reply(%{message: message}) when is_binary(message), do: message
  defp confirmation_reply(%{"message" => message}) when is_binary(message), do: message

  defp confirmation_reply(%{confirmation: %{"id" => id, "status" => status}}) do
    "Confirmation #{id}: #{status}."
  end

  defp confirmation_reply(%{"confirmation" => %{"id" => id, "status" => status}}) do
    "Confirmation #{id}: #{status}."
  end

  defp confirmation_reply(response), do: inspect(response, pretty: true)

  defp payload_summary(fields) do
    [
      "from=#{fields.from_address}",
      "subject=#{fields.subject}",
      "attachments=#{fields.attachment_count}"
    ]
    |> Enum.join(" ")
  end

  defp event_result({:ok, event}), do: {:ok, event}

  defp event_result({:error, %Ecto.Changeset{} = changeset}) do
    if duplicate_event?(changeset), do: {:ok, :duplicate}, else: {:error, changeset}
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

  defp strip_html(html) do
    html
    |> String.replace(~r/<script.*?<\/script>/is, "")
    |> String.replace(~r/<style.*?<\/style>/is, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp empty_to("", fallback), do: fallback
  defp empty_to(value, _fallback), do: value

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
