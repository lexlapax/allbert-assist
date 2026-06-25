defmodule AllbertAssist.Channels.Signal.Renderer do
  @moduledoc false

  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @default_limit 4000
  @descriptor %{
    primitives: [:typed_command, :link, :list],
    threading: :reply_chain,
    payload: :message
  }

  def render_response(runtime_response, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_text_bytes, @default_limit) |> min(@default_limit)

    with {:ok, rendered} <-
           SurfaceRenderer.render_response(runtime_response, @descriptor,
             max_text_bytes: max_bytes
           ) do
      {:ok, rendered.chunks}
    end
  end
end
