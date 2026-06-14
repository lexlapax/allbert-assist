defmodule AllbertAssist.Channels.Email.Parser do
  @moduledoc false

  @command_re ~r/^\s*(?:ALLBERT:)?(APPROVE|DENY|SHOW)(?::|\s+)([A-Za-z0-9_-]+)\s*$/i

  def parse_email(raw_bytes) when is_binary(raw_bytes) do
    with {:ok, headers, body} <- split_message(raw_bytes),
         {:ok, message_id} <- required_header(headers, "message-id"),
         {:ok, from_address} <- from_address(headers),
         {text_body, html_body} <- extract_body(headers, body) do
      {:ok,
       %{
         from_address: normalize_email(from_address),
         subject: Map.get(headers, "subject", ""),
         message_id: normalize_message_id(message_id),
         in_reply_to: normalize_optional_message_id(Map.get(headers, "in-reply-to")),
         references: Map.get(headers, "references"),
         text_body: text_body,
         html_body: html_body,
         date: Map.get(headers, "date"),
         attachment_count: attachment_count(raw_bytes)
       }}
    end
  rescue
    _exception -> {:error, :malformed}
  end

  def parse_email(_raw_bytes), do: {:error, :malformed}

  def detect_command(text_body) when is_binary(text_body) do
    text_body
    |> strip_quoted_reply()
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(:regular_text, &command_from_line/1)
  end

  def detect_command(_text_body), do: :regular_text

  defp split_message(raw_bytes) do
    case :binary.split(raw_bytes, ["\r\n\r\n", "\n\n"]) do
      [header_bytes, body] -> {:ok, parse_headers(header_bytes), body}
      _other -> {:error, :malformed}
    end
  end

  defp parse_headers(header_bytes) do
    header_bytes
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> unfold_headers()
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          Map.put(
            acc,
            name |> String.downcase() |> String.trim(),
            value |> String.trim() |> decode_header_value()
          )

        _other ->
          acc
      end
    end)
  end

  defp unfold_headers(lines) do
    Enum.reduce(lines, [], fn line, acc ->
      if String.starts_with?(line, [" ", "\t"]) and acc != [] do
        [previous | rest] = acc
        [previous <> " " <> String.trim(line) | rest]
      else
        [line | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp required_header(headers, name) do
    case Map.get(headers, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :"missing_#{String.replace(name, "-", "_")}"}
    end
  end

  defp from_address(headers) do
    with {:ok, from} <- required_header(headers, "from") do
      case Regex.run(~r/<([^>]+)>/, from) do
        [_, address] -> {:ok, address}
        _match -> {:ok, from}
      end
    end
  end

  defp extract_body(headers, body) do
    content_type = headers |> Map.get("content-type", "text/plain") |> String.downcase()

    cond do
      String.contains?(content_type, "multipart/") ->
        extract_multipart(content_type, body)

      String.contains?(content_type, "text/html") ->
        {nil, decode_part_body(headers, body)}

      true ->
        {decode_part_body(headers, body), nil}
    end
  end

  defp extract_multipart(content_type, body) do
    case multipart_boundary(content_type) do
      nil ->
        {nil, nil}

      boundary ->
        body
        |> String.split("--" <> boundary)
        |> Enum.reduce({nil, nil}, &extract_multipart_part/2)
    end
  end

  defp multipart_boundary(content_type) do
    case Regex.run(~r/boundary="?([^";]+)"?/i, content_type) do
      [_, value] -> value
      _match -> nil
    end
  end

  defp extract_multipart_part(part, acc) do
    case split_message(normalize_multipart_part(part)) do
      {:ok, headers, part_body} ->
        part_type = headers |> Map.get("content-type", "text/plain") |> String.downcase()
        put_multipart_part(part_type, decode_part_body(headers, part_body), acc)

      {:error, _reason} ->
        acc
    end
  end

  defp normalize_multipart_part(part) do
    Regex.replace(~r/\A(?:\r\n|\n)+/, part, "")
  end

  defp put_multipart_part(part_type, part_body, {text, html}) do
    cond do
      String.contains?(part_type, "text/plain") -> {text || part_body, html}
      String.contains?(part_type, "text/html") -> {text, html || part_body}
      true -> {text, html}
    end
  end

  defp command_from_line(line) do
    case Regex.run(@command_re, line) do
      [_, action, confirmation_id] ->
        {:command, action |> String.downcase(), confirmation_id}

      _match ->
        nil
    end
  end

  defp strip_quoted_reply(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.take_while(fn line ->
      not String.starts_with?(String.trim_leading(line), ">") and
        not Regex.match?(~r/^On .+ wrote:$/i, String.trim(line))
    end)
    |> Enum.join("\n")
  end

  defp normalize_email(value), do: value |> String.trim() |> String.downcase()

  defp normalize_message_id(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end

  defp normalize_optional_message_id(nil), do: nil
  defp normalize_optional_message_id(value), do: normalize_message_id(value)

  defp decode_header_value(value) do
    Regex.replace(~r/=\?([^?]+)\?([bBqQ])\?([^?]+)\?=/, value, fn original, charset, encoding,
                                                                   encoded ->
      with {:ok, bytes} <- decode_encoded_word(encoding, encoded),
           {:ok, text} <- decode_charset(bytes, charset) do
        text
      else
        _error -> original
      end
    end)
  end

  defp decode_encoded_word(encoding, encoded) when encoding in ["B", "b"] do
    encoded
    |> String.replace(~r/\s+/, "")
    |> Base.decode64()
  end

  defp decode_encoded_word(encoding, encoded) when encoding in ["Q", "q"] do
    encoded
    |> String.replace("_", " ")
    |> decode_quoted_printable()
  end

  defp decode_part_body(headers, body) do
    headers
    |> Map.get("content-transfer-encoding", "7bit")
    |> String.downcase()
    |> String.trim()
    |> decode_transfer_body(body)
    |> case do
      {:ok, bytes} ->
        headers
        |> Map.get("content-type", "text/plain")
        |> charset()
        |> then(&decode_charset(bytes, &1))
        |> case do
          {:ok, text} -> text
          {:error, _reason} -> bytes
        end

      {:error, _reason} ->
        body
    end
  end

  defp decode_transfer_body("base64", body) do
    body
    |> String.replace(~r/\s+/, "")
    |> Base.decode64()
  end

  defp decode_transfer_body("quoted-printable", body), do: decode_quoted_printable(body)
  defp decode_transfer_body(_encoding, body), do: {:ok, body}

  defp decode_quoted_printable(body) do
    body
    |> String.replace("=\r\n", "")
    |> String.replace("=\n", "")
    |> decode_quoted_printable_bytes(<<>>)
  end

  defp decode_quoted_printable_bytes("", acc), do: {:ok, acc}

  defp decode_quoted_printable_bytes("=" <> rest, acc) do
    case rest do
      <<hex::binary-size(2), tail::binary>> ->
        case Integer.parse(hex, 16) do
          {value, ""} -> decode_quoted_printable_bytes(tail, <<acc::binary, value>>)
          _other -> decode_quoted_printable_bytes(rest, <<acc::binary, "=">>)
        end

      _rest ->
        decode_quoted_printable_bytes(rest, <<acc::binary, "=">>)
    end
  end

  defp decode_quoted_printable_bytes(<<char, rest::binary>>, acc) do
    decode_quoted_printable_bytes(rest, <<acc::binary, char>>)
  end

  defp charset(content_type) do
    case Regex.run(~r/charset="?([^";]+)"?/i, content_type) do
      [_, value] -> value
      _match -> "utf-8"
    end
  end

  defp decode_charset(bytes, charset) when is_binary(bytes) and is_binary(charset) do
    case charset |> String.downcase() |> String.replace("_", "-") do
      "utf-8" ->
        if String.valid?(bytes), do: {:ok, bytes}, else: {:error, :invalid_utf8}

      "us-ascii" ->
        if String.valid?(bytes), do: {:ok, bytes}, else: {:error, :invalid_ascii}

      "iso-8859-1" ->
        {:ok, :unicode.characters_to_binary(bytes, :latin1, :utf8)}

      _other ->
        if String.valid?(bytes), do: {:ok, bytes}, else: {:error, :unsupported_charset}
    end
  end

  defp attachment_count(raw_bytes) do
    Regex.scan(~r/content-disposition:\s*attachment/iu, raw_bytes)
    |> length()
  end
end
