defmodule AllbertAssist.Channels.Signal.Parser do
  @moduledoc false

  @aci_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  def parse_notification(%{"method" => "receive", "params" => %{"envelope" => envelope}}) do
    case parse_envelope(envelope) do
      {:ok, fields} -> [{:text_message, fields}]
      {:error, reason, fields} -> [{:unsupported, Map.put(fields, :type, reason)}]
      {:error, reason} -> [{:malformed, reason}]
    end
  end

  def parse_notification(%{"method" => method, "params" => %{"envelope" => envelope}}) do
    [
      {:unsupported,
       %{
         external_event_id: event_id(envelope, method),
         external_chat_id: normalize_aci(Map.get(envelope, "sourceUuid")),
         type: "unsupported_signal_notification"
       }}
    ]
  end

  def parse_notification(_notification), do: []

  def simulated_receive_notification(attrs) when is_map(attrs) do
    aci =
      attrs
      |> field(:source_aci, "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001")
      |> normalize_aci()

    timestamp = field(attrs, :timestamp_ms, 1_781_477_600_000)
    message = field(attrs, :text, "")

    %{
      "jsonrpc" => "2.0",
      "method" => "receive",
      "params" => %{
        "envelope" => %{
          "sourceUuid" => aci,
          "sourceNumber" => field(attrs, :source_number),
          "timestamp" => timestamp,
          "dataMessage" => %{
            "message" => message,
            "timestamp" => timestamp
          }
        }
      }
    }
  end

  def normalize_aci(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("aci:", "")
  end

  def normalize_aci(value), do: value |> to_string() |> normalize_aci()

  def valid_aci?(value) when is_binary(value), do: Regex.match?(@aci_regex, normalize_aci(value))
  def valid_aci?(_value), do: false

  defp parse_envelope(%{"dataMessage" => %{"message" => text} = data_message} = envelope)
       when is_binary(text) do
    with {:ok, source_aci} <- source_aci(envelope),
         {:ok, timestamp_ms} <- timestamp_ms(data_message, envelope) do
      fields = %{
        external_event_id: "#{source_aci}:#{timestamp_ms}",
        external_user_id: source_aci,
        external_chat_id: source_aci,
        external_message_id: to_string(timestamp_ms),
        source_aci: source_aci,
        source_number: Map.get(envelope, "sourceNumber"),
        send_recipient: source_aci,
        timestamp_ms: timestamp_ms,
        text: text,
        raw_summary: "signal message #{timestamp_ms}"
      }

      {:ok, fields}
    end
  end

  defp parse_envelope(%{"dataMessage" => _data_message} = envelope) do
    {:error, :unsupported_signal_data_message,
     %{
       external_event_id: event_id(envelope, "receive"),
       external_chat_id: normalize_aci(Map.get(envelope, "sourceUuid")),
       type: "unsupported_signal_data_message"
     }}
  end

  defp parse_envelope(envelope) when is_map(envelope) do
    {:error, :unsupported_signal_envelope,
     %{
       external_event_id: event_id(envelope, "receive"),
       external_chat_id: normalize_aci(Map.get(envelope, "sourceUuid")),
       type: "unsupported_signal_envelope"
     }}
  end

  defp parse_envelope(_envelope), do: {:error, :missing_signal_envelope}

  defp source_aci(envelope) do
    envelope
    |> Map.get("sourceUuid")
    |> normalize_aci()
    |> case do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :missing_source_aci}
    end
  end

  defp timestamp_ms(data_message, envelope) do
    data_message
    |> Map.get("timestamp", Map.get(envelope, "timestamp"))
    |> normalize_timestamp()
    |> case do
      nil -> {:error, :missing_timestamp}
      timestamp -> {:ok, timestamp}
    end
  end

  defp normalize_timestamp(value) when is_integer(value), do: value

  defp normalize_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> timestamp
      _error -> nil
    end
  end

  defp normalize_timestamp(_value), do: nil

  defp event_id(envelope, fallback) when is_map(envelope) do
    source = envelope |> Map.get("sourceUuid", "unknown") |> normalize_aci()
    timestamp = Map.get(envelope, "timestamp", Ecto.UUID.generate())
    "#{source}:#{timestamp}:#{fallback}"
  end

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
