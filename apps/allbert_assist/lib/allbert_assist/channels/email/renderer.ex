defmodule AllbertAssist.Channels.Email.Renderer do
  @moduledoc false

  alias AllbertAssist.Intent.ApprovalHandoff

  def render_response(runtime_response, opts \\ []) do
    subject = reply_subject(Keyword.get(opts, :subject, "Allbert"))

    if handoff = response_field(runtime_response, :approval_handoff) do
      render_approval_handoff(handoff, Keyword.put(opts, :subject, subject))
    else
      body =
        runtime_response
        |> response_field(:message, "")
        |> to_string()

      {:ok, subject, bound_body(body, opts), nil}
    end
  end

  def render_approval_handoff(handoff_data, opts \\ []) do
    subject = reply_subject(Keyword.get(opts, :subject, "Approval required"))
    confirmation_id = response_field(handoff_data, :confirmation_id)

    body =
      [
        "Allbert needs your approval:",
        "",
        ApprovalHandoff.lines(handoff_data),
        "",
        "To approve, reply with this exact line:",
        "ALLBERT:APPROVE:#{confirmation_id}",
        "",
        "To deny:",
        "ALLBERT:DENY:#{confirmation_id}",
        "",
        "To see current status:",
        "ALLBERT:SHOW:#{confirmation_id}"
      ]
      |> List.flatten()
      |> Enum.join("\n")

    {:ok, subject, bound_body(body, opts), nil}
  end

  defp reply_subject(""), do: "Re: Allbert"
  defp reply_subject("Re: " <> _rest = subject), do: sanitize_subject(subject)
  defp reply_subject(subject), do: "Re: " <> sanitize_subject(subject)

  defp bound_body(body, opts) do
    max_body_bytes = Keyword.get(opts, :max_body_bytes, 65_536)

    if byte_size(body) > max_body_bytes do
      byte_safe_prefix(body, max_body_bytes) <>
        "\n\n[Truncated locally; full trace remains in Allbert.]"
    else
      body
    end
  end

  defp byte_safe_prefix(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, bytes} ->
      next_bytes = bytes + byte_size(grapheme)

      if next_bytes > max_bytes do
        {:halt, {acc, bytes}}
      else
        {:cont, {acc <> grapheme, next_bytes}}
      end
    end)
    |> elem(0)
  end

  defp sanitize_subject(subject) do
    subject
    |> to_string()
    |> String.replace(["\r", "\n"], " ")
    |> String.slice(0, 200)
  end

  defp response_field(map, key, default \\ nil)

  defp response_field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp response_field(_map, _key, default), do: default
end
