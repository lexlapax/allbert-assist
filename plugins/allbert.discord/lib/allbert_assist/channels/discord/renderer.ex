defmodule AllbertAssist.Channels.Discord.Renderer do
  @moduledoc false

  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @discord_limit 2000
  @descriptor %{
    primitives: [:button, :typed_command, :list],
    threading: :native_threads,
    payload: :message,
    media_outputs: true
  }

  def render_response(runtime_response, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_text_bytes, @discord_limit) |> min(@discord_limit)
    descriptor = effective_descriptor(opts)

    with {:ok, rendered} <-
           SurfaceRenderer.render_response(runtime_response, descriptor,
             max_text_bytes: max_bytes
           ) do
      case rendered.kind do
        :approval_handoff -> {:ok, [approval_message(rendered.primitive, rendered.payload)]}
        _kind -> {:ok, Enum.map(rendered.chunks, &%{content: &1})}
      end
    end
  end

  def render_approval_handoff(handoff_data, opts \\ []) do
    with {:ok, rendered} <-
           SurfaceRenderer.render_approval_handoff(handoff_data, effective_descriptor(opts)) do
      {:ok, [approval_message(rendered.primitive, rendered.payload)]}
    end
  end

  defp effective_descriptor(opts) do
    primitives =
      if Keyword.get(opts, :render_buttons, true) do
        [:button, :typed_command, :list]
      else
        [:typed_command, :list]
      end

    Map.put(@descriptor, :primitives, primitives)
  end

  defp approval_message(:button, %{text: text, buttons: buttons}) do
    %{
      content: text,
      components: [
        %{
          type: 1,
          components:
            Enum.map(buttons, fn button ->
              %{
                type: 2,
                style: button_style(Map.get(button, :action)),
                label: Map.get(button, :label),
                custom_id: Map.get(button, :callback_data)
              }
            end)
        }
      ]
    }
  end

  defp approval_message(:typed_command, %{text: text, commands: commands}) do
    %{content: text <> "\n" <> Enum.join(commands, "\n")}
  end

  defp approval_message(_primitive, %{text: text}), do: %{content: text}

  defp button_style(:approve), do: 3
  defp button_style(:deny), do: 4
  defp button_style(_action), do: 2
end
