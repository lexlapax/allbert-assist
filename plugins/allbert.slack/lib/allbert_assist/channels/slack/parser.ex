defmodule AllbertAssist.Channels.Slack.Parser do
  @moduledoc false

  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime.Redactor

  @callback_re ~r/\Aallbert:v1:(approve|deny|show):([A-Za-z0-9_-]+)\z/

  def parse_socket_envelope(%{"type" => "hello"} = envelope) do
    {:hello,
     %{
       external_event_id: envelope_id(envelope, "hello"),
       envelope_id: Map.get(envelope, "envelope_id"),
       raw_summary: "slack socket hello"
     }}
  end

  def parse_socket_envelope(%{"type" => "events_api", "payload" => payload} = envelope)
      when is_map(payload) do
    event = Map.get(payload, "event", %{})

    case Map.get(event, "type") do
      type when type in ["app_mention", "message"] ->
        parse_message_event(envelope, payload, event)

      type ->
        {:unsupported, %{external_event_id: envelope_id(envelope, type), type: type}}
    end
  end

  def parse_socket_envelope(%{"type" => "interactive", "payload" => payload} = envelope)
      when is_map(payload) do
    with {:ok, action_id} <- action_id(payload),
         {:ok, {verb, confirmation_id}} <- parse_callback_id(action_id),
         {:ok, user_id} <- required(get_map(payload, "user"), "id") do
      {:interactive,
       %{
         external_event_id: envelope_id(envelope, Map.get(payload, "trigger_id", action_id)),
         envelope_id: Map.get(envelope, "envelope_id"),
         external_user_id: user_id,
         external_chat_id: get_in(payload, ["channel", "id"]),
         external_message_id: get_in(payload, ["message", "ts"]),
         team_id: get_in(payload, ["team", "id"]),
         channel_id: get_in(payload, ["channel", "id"]),
         thread_ts:
           get_in(payload, ["message", "thread_ts"]) || get_in(payload, ["message", "ts"]),
         callback_data: action_id,
         verb: verb,
         confirmation_id: confirmation_id,
         raw_summary: "slack interaction #{action_id}"
       }}
    else
      {:error, reason} -> {:malformed, reason}
    end
  end

  def parse_socket_envelope(%{"type" => type} = envelope) do
    {:unsupported, %{external_event_id: envelope_id(envelope, type), type: type}}
  end

  def parse_socket_envelope(_envelope), do: {:malformed, "missing socket envelope type"}

  def simulated_event(attrs) when is_map(attrs) do
    channel_id = to_string(field(attrs, :channel_id) || field(attrs, :channel))
    team_id = to_string(field(attrs, :team_id) || field(attrs, :team))
    user_id = to_string(field(attrs, :user_id) || field(attrs, :user))
    ts = to_string(field(attrs, :ts) || simulated_ts())
    thread_ts = field(attrs, :thread_ts)
    text = to_string(field(attrs, :text) || "")
    event_type = to_string(field(attrs, :type) || field(attrs, :event_type) || "app_mention")

    %{
      "type" => "events_api",
      "envelope_id" => "env_" <> Ecto.UUID.generate(),
      "accepts_response_payload" => false,
      "payload" => %{
        "type" => "event_callback",
        "team_id" => team_id,
        "event" =>
          %{
            "type" => event_type,
            "user" => user_id,
            "channel" => channel_id,
            "channel_type" => field(attrs, :channel_type),
            "subtype" => field(attrs, :subtype),
            "bot_id" => field(attrs, :bot_id),
            "text" => text,
            "ts" => ts,
            "event_ts" => ts,
            "thread_ts" => thread_ts
          }
          |> compact()
      }
    }
  end

  def simulated_interactive(attrs) when is_map(attrs) do
    %{
      "type" => "interactive",
      "envelope_id" => "env_" <> Ecto.UUID.generate(),
      "payload" => %{
        "type" => "block_actions",
        "team" => %{"id" => to_string(field(attrs, :team_id) || field(attrs, :team))},
        "user" => %{"id" => to_string(field(attrs, :user_id) || field(attrs, :user))},
        "channel" => %{"id" => to_string(field(attrs, :channel_id) || field(attrs, :channel))},
        "message" => %{"ts" => to_string(field(attrs, :message_ts) || simulated_ts())},
        "actions" => [
          %{
            "type" => "button",
            "action_id" => to_string(field(attrs, :action_id)),
            "value" => to_string(field(attrs, :action_id))
          }
        ]
      }
    }
  end

  defp parse_message_event(envelope, payload, event) do
    with {:ok, team_id} <- required(payload, "team_id"),
         {:ok, channel_id} <- required(event, "channel"),
         {:ok, user_id} <- required(event, "user"),
         {:ok, ts} <- required(event, "ts") do
      thread_ts = optional_string(Map.get(event, "thread_ts")) || ts
      receiver_account_ref = "slack:team:" <> team_id

      provider_thread_ref =
        %{
          provider: "slack",
          team_id: team_id,
          channel_id: channel_id,
          thread_ts: thread_ts,
          provider_message_id: ts
        }
        |> compact()

      channel_thread_ref = %{
        channel: "slack",
        receiver_account_ref: receiver_account_ref,
        provider_thread_ref: provider_thread_ref,
        provider_thread_key:
          ChannelThread.provider_thread_key(%{
            receiver_account_ref: receiver_account_ref,
            team_id: team_id,
            channel_id: channel_id,
            thread_ts: thread_ts,
            external_user_id: user_id
          })
      }

      channel_type = optional_string(Map.get(event, "channel_type"))

      {:message,
       %{
         external_event_id: Map.get(event, "client_msg_id") || ts,
         envelope_id: Map.get(envelope, "envelope_id"),
         external_user_id: user_id,
         external_chat_id: channel_id,
         external_message_id: ts,
         team_id: team_id,
         channel_id: channel_id,
         thread_ts: thread_ts,
         text: Map.get(event, "text", ""),
         # Provider-fidelity signals: faithfully surface the Slack event shape so
         # the adapter (not the parser) can apply response_style / DM gating and
         # bot/own/subtype echo filtering. The parser stays policy-free.
         event_type: optional_string(Map.get(event, "type")),
         channel_type: channel_type,
         subtype: optional_string(Map.get(event, "subtype")),
         bot_id: optional_string(Map.get(event, "bot_id")),
         is_dm?: channel_type == "im",
         receiver_account_ref: receiver_account_ref,
         provider_thread_ref: Redactor.redact(provider_thread_ref),
         channel_thread_ref: channel_thread_ref,
         raw_summary: "slack message #{ts}"
       }}
    else
      {:error, reason} -> {:malformed, reason}
    end
  end

  defp action_id(%{"actions" => [action | _rest]}) when is_map(action) do
    case Map.get(action, "action_id") || Map.get(action, "value") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, "missing action_id"}
    end
  end

  defp action_id(_payload), do: {:error, "missing action_id"}

  defp parse_callback_id(action_id) do
    case Regex.run(@callback_re, action_id) do
      [_full, verb, confirmation_id] -> {:ok, {String.to_atom(verb), confirmation_id}}
      _match -> {:error, "invalid action_id"}
    end
  end

  defp envelope_id(envelope, fallback) do
    Map.get(envelope, "envelope_id") || "unsupported:" <> to_string(fallback || "unknown")
  end

  defp required(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when value in [nil, ""] -> {:error, "missing #{key}"}
      value -> {:ok, to_string(value)}
    end
  end

  defp required(_map, key), do: {:error, "missing #{key}"}

  defp get_map(map, key), do: Map.get(map, key, %{})

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp optional_string(value) when value in [nil, ""], do: nil
  defp optional_string(value), do: to_string(value)

  defp simulated_ts do
    {mega, seconds, micro} = :os.timestamp()

    Integer.to_string(mega * 1_000_000 + seconds) <>
      "." <> String.pad_leading(to_string(micro), 6, "0")
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}, []] end)
    |> Map.new()
  end
end
