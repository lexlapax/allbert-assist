defmodule AllbertAssist.Channels.WhatsApp.Parser do
  @moduledoc false

  @button_callback_re ~r/\Aallbert:v1:(approve|deny|show):([A-Za-z0-9_-]+)\z/

  def parse_webhook(%{"entry" => entries}) when is_list(entries) do
    entries
    |> Enum.flat_map(&parse_entry/1)
  end

  def parse_webhook(_payload), do: []

  def simulated_text_webhook(attrs) when is_map(attrs) do
    phone_number_id = to_string(field(attrs, :phone_number_id) || "15551234567")
    from = to_string(field(attrs, :from) || "+15550001111")
    message_id = to_string(field(attrs, :message_id) || "wamid." <> Ecto.UUID.generate())
    timestamp = to_string(field(attrs, :timestamp) || now_unix_seconds())
    display_phone_number = to_string(field(attrs, :display_phone_number) || "+15551234567")

    %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => to_string(field(attrs, :waba_id) || "waba-fixture"),
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "metadata" => %{
                  "display_phone_number" => display_phone_number,
                  "phone_number_id" => phone_number_id
                },
                "contacts" => [
                  %{
                    "profile" => %{
                      "name" => to_string(field(attrs, :profile_name) || "Fixture User")
                    },
                    "wa_id" => String.trim_leading(from, "+")
                  }
                ],
                "messages" => [
                  %{
                    "from" => from,
                    "id" => message_id,
                    "timestamp" => timestamp,
                    "type" => "text",
                    "text" => %{"body" => to_string(field(attrs, :text) || "")}
                  }
                  |> maybe_put_context(field(attrs, :context_message_id))
                ]
              }
            }
          ]
        }
      ]
    }
  end

  def simulated_button_webhook(attrs) when is_map(attrs) do
    phone_number_id = to_string(field(attrs, :phone_number_id) || "15551234567")
    from = to_string(field(attrs, :from) || "+15550001111")
    message_id = to_string(field(attrs, :message_id) || "wamid." <> Ecto.UUID.generate())
    timestamp = to_string(field(attrs, :timestamp) || now_unix_seconds())
    button_id = to_string(field(attrs, :button_id) || "allbert:v1:approve:fixture")
    title = to_string(field(attrs, :title) || "Approve")

    %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => to_string(field(attrs, :waba_id) || "waba-fixture"),
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "metadata" => %{
                  "display_phone_number" =>
                    to_string(field(attrs, :display_phone_number) || "+15551234567"),
                  "phone_number_id" => phone_number_id
                },
                "contacts" => [
                  %{
                    "profile" => %{"name" => "Fixture User"},
                    "wa_id" => String.trim_leading(from, "+")
                  }
                ],
                "messages" => [
                  %{
                    "from" => from,
                    "id" => message_id,
                    "timestamp" => timestamp,
                    "type" => "interactive",
                    "interactive" => %{
                      "type" => "button_reply",
                      "button_reply" => %{"id" => button_id, "title" => title}
                    }
                  }
                  |> maybe_put_context(field(attrs, :context_message_id))
                ]
              }
            }
          ]
        }
      ]
    }
  end

  def parse_callback_id(custom_id) when is_binary(custom_id) do
    if custom_id == "ALLBERT:NOTIFY:ON" do
      {:ok, {:notify_consent, nil}}
    else
      case Regex.run(@button_callback_re, custom_id) do
        [_full, verb, confirmation_id] -> {:ok, {String.to_atom(verb), confirmation_id}}
        _match -> {:error, :invalid_callback_id}
      end
    end
  end

  def parse_callback_id(_custom_id), do: {:error, :invalid_callback_id}

  defp parse_entry(%{"changes" => changes, "id" => entry_id}) when is_list(changes) do
    Enum.flat_map(changes, &parse_change(&1, entry_id))
  end

  defp parse_entry(_entry), do: []

  defp parse_change(
         %{"field" => "messages", "value" => %{"messages" => messages} = value},
         entry_id
       )
       when is_list(messages) do
    Enum.map(messages, &parse_message(&1, value, entry_id))
  end

  defp parse_change(_change, _entry_id), do: []

  defp parse_message(%{"type" => "text", "text" => %{"body" => body}} = message, value, entry_id)
       when is_binary(body) do
    {:text_message, common_fields(message, value, entry_id) |> Map.put(:text, body)}
  end

  defp parse_message(
         %{
           "type" => "interactive",
           "interactive" => %{
             "type" => "button_reply",
             "button_reply" => %{"id" => id, "title" => title}
           }
         } = message,
         value,
         entry_id
       )
       when is_binary(id) do
    fields =
      message
      |> common_fields(value, entry_id)
      |> Map.merge(%{
        button_id: id,
        button_title: title,
        text: id
      })

    case parse_callback_id(id) do
      {:ok, {verb, confirmation_id}} ->
        {:button_reply, Map.merge(fields, %{verb: verb, confirmation_id: confirmation_id})}

      {:error, reason} ->
        {:unsupported, Map.put(fields, :type, reason)}
    end
  end

  defp parse_message(%{"id" => message_id, "type" => type} = message, value, entry_id) do
    {:unsupported,
     message
     |> common_fields(value, entry_id)
     |> Map.merge(%{
       external_event_id: to_string(message_id),
       type: to_string(type || "unsupported")
     })}
  end

  defp parse_message(_message, _value, _entry_id), do: {:malformed, :missing_message_fields}

  defp common_fields(message, value, entry_id) do
    metadata = Map.get(value, "metadata", %{})
    contacts = Map.get(value, "contacts", [])
    from = to_string(Map.get(message, "from", ""))
    message_id = to_string(Map.get(message, "id", ""))
    timestamp_seconds = parse_timestamp(Map.get(message, "timestamp"))
    context_message_id = get_in(message, ["context", "id"])

    %{
      external_event_id: message_id,
      external_user_id: from,
      external_chat_id: Map.get(metadata, "phone_number_id"),
      external_message_id: message_id,
      phone_number_id: Map.get(metadata, "phone_number_id"),
      display_phone_number: Map.get(metadata, "display_phone_number"),
      waba_id: to_string(entry_id || ""),
      from: from,
      wa_id: contact_wa_id(contacts, from),
      profile_name: contact_profile_name(contacts, from),
      timestamp_seconds: timestamp_seconds,
      timestamp_ms: timestamp_seconds && timestamp_seconds * 1000,
      context_message_id: context_message_id,
      raw_summary: "whatsapp message #{message_id}"
    }
  end

  defp contact_wa_id([%{"wa_id" => wa_id} | _rest], _from), do: to_string(wa_id)
  defp contact_wa_id(_contacts, from), do: String.trim_leading(from, "+")

  defp contact_profile_name([%{"profile" => %{"name" => name}} | _rest], _from), do: name
  defp contact_profile_name(_contacts, _from), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds
      _error -> nil
    end
  end

  defp parse_timestamp(value) when is_integer(value), do: value
  defp parse_timestamp(_value), do: nil

  defp maybe_put_context(message, value) when is_binary(value) and value != "",
    do: Map.put(message, "context", %{"id" => value})

  defp maybe_put_context(message, _value), do: message

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp now_unix_seconds, do: DateTime.utc_now() |> DateTime.to_unix()
end
