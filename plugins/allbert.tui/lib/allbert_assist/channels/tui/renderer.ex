defmodule AllbertAssist.Channels.TUI.Renderer do
  @moduledoc false

  alias AllbertAssist.Coding.StreamRenderer
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @default_max_text_bytes 12_000
  @descriptor %{
    primitives: [:typed_command, :list],
    threading: :rich,
    payload: :surface_payload,
    stream_events: true,
    append_approval_handoff: true,
    approval_text: :typed_and_list,
    typed_intro: "Type one exact command:",
    list_intro: "Approval options:",
    normalize_text: true,
    bound_text: true
  }

  @spec banner(String.t()) :: [Owl.Data.t()]
  def banner(profile) do
    [["Allbert TUI ", Owl.Data.tag("(#{profile})", :cyan)], "Type /quit to exit."]
  end

  @spec prompt(String.t()) :: Owl.Data.t()
  def prompt(profile), do: [Owl.Data.tag("allbert", :cyan), ":", profile, "> "]

  @spec status(String.t(), atom()) :: Owl.Data.t()
  def status(profile, state) do
    [
      Owl.Data.tag("tui", :light_black),
      "(",
      profile,
      ") ",
      Owl.Data.tag(to_string(state), :light_black)
    ]
  end

  @spec render_response(map(), keyword()) :: {:ok, [String.t()]}
  def render_response(response, opts \\ []) when is_map(response) do
    max_text_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)

    with {:ok, rendered} <-
           SurfaceRenderer.render_response(response, @descriptor, max_text_bytes: max_text_bytes) do
      {:ok, [rendered.text]}
    end
  end

  @spec render_stream_events(Enumerable.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def render_stream_events(events, opts \\ []) do
    turn_id = Keyword.fetch!(opts, :turn_id)
    max_text_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)

    with {:ok, rendered} <-
           StreamRenderer.render_events(events,
             turn_id: turn_id,
             max_text_bytes: max_text_bytes
           ) do
      {:ok, [rendered]}
    end
  end

  @spec stream_state(StreamRenderer.t(), keyword()) :: Owl.Data.t()
  def stream_state(state, opts \\ []) do
    max_text_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)
    StreamRenderer.render(state, max_text_bytes: max_text_bytes, mode: :live)
  end

  def render_approval_handoff(handoff_data) do
    {:ok, %{text: text}} = SurfaceRenderer.render_approval_handoff(handoff_data, @descriptor)
    text
  end

  def confirmation_reply(response) when is_map(response) do
    response
    |> response_field(:message, inspect(response, pretty: true))
    |> to_string()
  end

  defp response_field(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
