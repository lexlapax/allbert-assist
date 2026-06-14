defmodule AllbertAssist.Channels.Email.SmtpClient do
  @moduledoc false

  def send(from, to, subject, body, opts \\ []) do
    message = format_message(from, to, subject, body, opts)
    recipients = List.wrap(to)
    smtp_opts = smtp_options(opts)

    if Code.ensure_loaded?(:gen_smtp_client) do
      apply(:gen_smtp_client, :send_blocking, [{from, recipients, message}, smtp_opts])
      |> normalize_result()
    else
      {:error, :gen_smtp_unavailable}
    end
  end

  # Provider API placeholder: a future backend option can route send/5 through
  # Mailgun, SendGrid, or another bounded transactional API without changing
  # the Email.Adapter or Email.Renderer call shape.

  def format_message(from, to, subject, body, opts \\ []) do
    headers = [
      {"From", from_header(from, Keyword.get(opts, :from_name))},
      {"To", Enum.join(List.wrap(to), ", ")},
      {"Subject", sanitize_header(subject)},
      {"Message-ID", "<#{message_id(opts)}>"},
      {"Date", rfc5322_date(Keyword.get(opts, :date))},
      {"MIME-Version", "1.0"},
      {"Content-Type", "text/plain; charset=utf-8"},
      {"Content-Transfer-Encoding", "8bit"}
    ]

    headers =
      headers
      |> maybe_header("In-Reply-To", Keyword.get(opts, :in_reply_to))
      |> maybe_header("References", Keyword.get(opts, :references))

    encoded_headers =
      headers
      |> Enum.map(fn {name, value} -> "#{name}: #{encode_header_value(name, value)}" end)
      |> Enum.join("\r\n")

    encoded_headers <> "\r\n\r\n" <> body
  end

  defp smtp_options(opts) do
    [
      relay: Keyword.fetch!(opts, :host),
      port: Keyword.fetch!(opts, :port),
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      tls: if(Keyword.get(opts, :tls, true), do: :always, else: :never),
      auth: if(Keyword.get(opts, :username) in [nil, ""], do: :never, else: :always)
    ]
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _receipt}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, other}

  defp message_id(opts) do
    case Keyword.get(opts, :message_id) do
      value when is_binary(value) and value != "" -> value
      _value -> "#{Ecto.UUID.generate()}@allbert.local"
    end
  end

  defp from_header(address, nil), do: address
  defp from_header(address, ""), do: address
  defp from_header(address, name), do: "#{encode_phrase(name)} <#{sanitize_header(address)}>"

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, _name, ""), do: headers
  defp maybe_header(headers, name, value), do: headers ++ [{name, value}]

  defp sanitize_header(value) do
    value
    |> to_string()
    |> String.replace(["\r", "\n"], " ")
    |> String.slice(0, 500)
  end

  defp encode_header_value("Subject", value), do: value |> sanitize_header() |> encode_phrase()
  defp encode_header_value("From", value), do: sanitize_header(value)
  defp encode_header_value(_name, value), do: sanitize_header(value)

  defp encode_phrase(value) do
    value = sanitize_header(value)

    if ascii_printable?(value) do
      value
    else
      "=?UTF-8?B?#{Base.encode64(value)}?="
    end
  end

  defp ascii_printable?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 in 32..126))
  end

  defp rfc5322_date(nil), do: DateTime.utc_now() |> rfc5322_date()

  defp rfc5322_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S +0000")
  end

  defp rfc5322_date(value), do: sanitize_header(value)
end
