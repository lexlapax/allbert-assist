defmodule AllbertAssist.Channels.Email.Renderer do
  @moduledoc false

  alias AllbertAssist.Approval.Handoff
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Confirmations.ObjectiveContext
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  def render_response(runtime_response, opts \\ []) do
    subject = reply_subject(Keyword.get(opts, :subject, "Allbert"))

    if handoff = response_field(runtime_response, :approval_handoff) do
      render_approval_handoff(handoff, Keyword.put(opts, :subject, subject))
    else
      body = SurfaceRenderer.response_text(runtime_response, %{payload: :message})

      {:ok, subject, bound_body(body, opts), nil}
    end
  end

  def render_approval_handoff(handoff_data, opts \\ []) do
    subject = reply_subject(Keyword.get(opts, :subject, "Approval required"))
    confirmation_id = response_field(handoff_data, :confirmation_id)

    with {:ok, {:typed_command, payload}} <-
           Handoff.render(handoff_data, %{
             primitives: [:typed_command, :list],
             threading: :reply_chain
           }) do
      commands = Map.get(payload, :commands, typed_commands(confirmation_id))

      body =
        [
          "Allbert needs your approval:",
          "",
          ObjectiveContext.lines(handoff_data),
          "",
          ApprovalHandoff.lines(handoff_data),
          "",
          "To approve, reply with this exact line:",
          Enum.at(commands, 0, "ALLBERT:APPROVE:#{confirmation_id}"),
          "",
          "To deny:",
          Enum.at(commands, 1, "ALLBERT:DENY:#{confirmation_id}"),
          "",
          "To see current status:",
          Enum.at(commands, 2, "ALLBERT:SHOW:#{confirmation_id}")
        ]
        |> List.flatten()
        |> Enum.join("\n")

      {:ok, subject, bound_body(body, opts), nil}
    end
  end

  defp typed_commands(confirmation_id) do
    [
      "ALLBERT:APPROVE:#{confirmation_id}",
      "ALLBERT:DENY:#{confirmation_id}",
      "ALLBERT:SHOW:#{confirmation_id}"
    ]
  end

  defp reply_subject(""), do: "Re: Allbert"
  defp reply_subject("Re: " <> _rest = subject), do: sanitize_subject(subject)
  defp reply_subject(subject), do: "Re: " <> sanitize_subject(subject)

  defp bound_body(body, opts) do
    max_body_bytes = Keyword.get(opts, :max_body_bytes, 65_536)

    if byte_size(body) > max_body_bytes do
      SurfaceRenderer.bound_text(body, max_body_bytes, "") <>
        "\n\n[Truncated locally; full trace remains in Allbert.]"
    else
      body
    end
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
