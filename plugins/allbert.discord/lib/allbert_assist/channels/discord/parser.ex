defmodule AllbertAssist.Channels.Discord.Parser do
  @moduledoc false

  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime.Redactor

  @interaction_callback_re ~r/\Aallbert:v1:(approve|deny|show):([A-Za-z0-9_-]+)\z/

  def parse_gateway_event(%{"t" => "READY", "d" => data}) when is_map(data) do
    {:ready,
     %{
       external_event_id: "ready:" <> to_string(Map.get(data, "session_id", "unknown")),
       session_id: Map.get(data, "session_id"),
       user_id: get_in(data, ["user", "id"]),
       username: get_in(data, ["user", "username"]),
       raw_summary: "discord ready"
     }}
  end

  def parse_gateway_event(%{"t" => "MESSAGE_CREATE", "d" => data}) when is_map(data) do
    with {:ok, message_id} <- required(data, "id"),
         {:ok, author_id} <- required(get_map(data, "author"), "id"),
         {:ok, channel_id} <- required(data, "channel_id") do
      guild_id = optional_string(Map.get(data, "guild_id"))
      parent_channel_id = optional_string(Map.get(data, "parent_channel_id"))
      thread_channel_id = optional_string(Map.get(data, "thread_channel_id")) || channel_id
      dm? = is_nil(guild_id)
      thread_root = thread_channel_id || channel_id
      receiver_account_ref = receiver_account_ref(data)
      message_reference = normalize_message_reference(Map.get(data, "message_reference"))

      provider_thread_ref =
        %{
          provider: "discord",
          guild_id: guild_id || "dm",
          channel_id: parent_channel_id || channel_id,
          thread_channel_id: thread_root,
          provider_thread_root: thread_root,
          provider_message_id: message_id,
          message_reference: message_reference
        }
        |> compact()

      channel_thread_ref = %{
        channel: "discord",
        receiver_account_ref: receiver_account_ref,
        provider_thread_ref: provider_thread_ref,
        provider_thread_key:
          ChannelThread.provider_thread_key(%{
            receiver_account_ref: receiver_account_ref,
            guild_or_dm: guild_id || "dm",
            thread_channel_id: thread_root,
            external_user_id: author_id
          })
      }

      {:message_create,
       %{
         external_event_id: message_id,
         external_user_id: author_id,
         external_chat_id: channel_id,
         external_message_id: message_id,
         guild_id: guild_id,
         channel_id: channel_id,
         parent_channel_id: parent_channel_id,
         thread_channel_id: thread_root,
         dm?: dm?,
         text: Map.get(data, "content", ""),
         receiver_account_ref: receiver_account_ref,
         provider_thread_ref: Redactor.redact(provider_thread_ref),
         channel_thread_ref: channel_thread_ref,
         message_reference: message_reference,
         raw_summary: "discord message #{message_id}"
       }}
    else
      {:error, reason} -> {:malformed, reason}
    end
  end

  def parse_gateway_event(%{"t" => "INTERACTION_CREATE", "d" => data}) when is_map(data) do
    with {:ok, interaction_id} <- required(data, "id"),
         {:ok, interaction_token} <- required(data, "token"),
         {:ok, user_id} <- interaction_user_id(data),
         {:ok, custom_id} <- interaction_custom_id(data),
         {:ok, {verb, confirmation_id}} <- parse_callback_id(custom_id) do
      {:interaction_create,
       %{
         external_event_id: interaction_id,
         external_user_id: user_id,
         external_chat_id: Map.get(data, "channel_id"),
         external_message_id: interaction_id,
         interaction_token: interaction_token,
         guild_id: optional_string(Map.get(data, "guild_id")),
         channel_id: optional_string(Map.get(data, "channel_id")),
         callback_data: custom_id,
         verb: verb,
         confirmation_id: confirmation_id,
         raw_summary: "discord interaction #{interaction_id}"
       }}
    else
      {:error, reason} -> {:malformed, reason}
    end
  end

  def parse_gateway_event(%{"t" => event_type, "d" => data}) do
    external_event_id =
      case data do
        %{"id" => id} -> to_string(id)
        _data -> "unsupported:" <> to_string(event_type)
      end

    {:unsupported, %{external_event_id: external_event_id, type: event_type}}
  end

  def parse_gateway_event(_event), do: {:malformed, "missing gateway dispatch type"}

  def simulated_message_event(attrs) when is_map(attrs) do
    guild_id = optional_string(field(attrs, :guild_id) || field(attrs, :guild))
    channel_id = to_string(field(attrs, :channel_id) || field(attrs, :channel))
    thread_channel_id = field(attrs, :thread_channel_id) || field(attrs, :thread_channel)
    user_id = to_string(field(attrs, :user_id) || field(attrs, :user))
    message_id = to_string(field(attrs, :message_id) || "sim_" <> Ecto.UUID.generate())
    application_id = optional_string(field(attrs, :application_id))
    message_reference = field(attrs, :message_reference)
    text = to_string(field(attrs, :text) || "")

    %{
      "t" => "MESSAGE_CREATE",
      "d" =>
        %{
          "id" => message_id,
          "guild_id" => guild_id,
          "channel_id" => thread_channel_id || channel_id,
          "parent_channel_id" => if(thread_channel_id, do: channel_id, else: nil),
          "thread_channel_id" => thread_channel_id,
          "application_id" => application_id,
          "content" => text,
          "message_reference" => message_reference,
          "author" => %{"id" => user_id, "username" => "fixture-user", "bot" => false},
          "mentions" => mentions(application_id)
        }
        |> compact()
    }
  end

  defp mentions(nil), do: []
  defp mentions(application_id), do: [%{"id" => application_id}]

  defp receiver_account_ref(data) do
    application_id =
      Map.get(data, "application_id") || Map.get(data, "bot_application_id") || "unknown"

    guild_id = Map.get(data, "guild_id") || "dm"
    "discord:app:" <> to_string(application_id) <> ":guild:" <> to_string(guild_id)
  end

  defp normalize_message_reference(value) when is_map(value) do
    value
    |> Map.take(["message_id", "channel_id", "guild_id", :message_id, :channel_id, :guild_id])
    |> normalize_keys()
    |> compact()
  end

  defp normalize_message_reference(_value), do: nil

  defp normalize_keys(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, key |> to_string() |> String.trim_leading(":"), value)
    end)
  end

  defp interaction_user_id(%{"user" => %{"id" => id}}), do: {:ok, to_string(id)}
  defp interaction_user_id(%{"member" => %{"user" => %{"id" => id}}}), do: {:ok, to_string(id)}
  defp interaction_user_id(_data), do: {:error, "missing interaction user id"}

  defp interaction_custom_id(%{"data" => %{"custom_id" => custom_id}})
       when is_binary(custom_id),
       do: {:ok, custom_id}

  defp interaction_custom_id(_data), do: {:error, "missing interaction custom_id"}

  defp parse_callback_id(custom_id) do
    case Regex.run(@interaction_callback_re, custom_id) do
      [_full, verb, confirmation_id] -> {:ok, {String.to_atom(verb), confirmation_id}}
      _match -> {:error, "invalid interaction custom_id"}
    end
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

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}, []] end)
    |> Map.new()
  end
end
