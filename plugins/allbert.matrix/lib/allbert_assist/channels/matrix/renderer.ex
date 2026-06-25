defmodule AllbertAssist.Channels.Matrix.Renderer do
  @moduledoc false

  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @default_limit 4000
  @descriptor %{
    primitives: [:typed_command, :link, :list],
    threading: :native_threads,
    payload: :message
  }

  def render_response(runtime_response, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_text_bytes, @default_limit)

    with {:ok, rendered} <-
           SurfaceRenderer.render_response(runtime_response, @descriptor,
             max_text_bytes: max_bytes
           ) do
      {:ok, rendered.chunks}
    end
  end

  def message_content(text, fields \\ %{}) do
    %{
      "msgtype" => "m.text",
      "body" => text
    }
    |> maybe_put_relation(fields)
  end

  defp maybe_put_relation(content, fields) do
    root = Map.get(fields, :thread_root_event_id)
    reply_to = Map.get(fields, :reply_to_event_id) || Map.get(fields, :external_message_id)

    cond do
      is_binary(root) and root != "" and is_binary(reply_to) and reply_to != "" ->
        Map.put(content, "m.relates_to", %{
          "rel_type" => "m.thread",
          "event_id" => root,
          "m.in_reply_to" => %{"event_id" => reply_to},
          "is_falling_back" => true
        })

      is_binary(root) and root != "" ->
        Map.put(content, "m.relates_to", %{"rel_type" => "m.thread", "event_id" => root})

      is_binary(reply_to) and reply_to != "" ->
        Map.put(content, "m.relates_to", %{"m.in_reply_to" => %{"event_id" => reply_to}})

      true ->
        content
    end
  end
end
