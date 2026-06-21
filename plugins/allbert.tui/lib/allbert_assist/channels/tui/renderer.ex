defmodule AllbertAssist.Channels.TUI.Renderer do
  @moduledoc false

  @default_max_text_bytes 12_000

  @spec banner(String.t()) :: [Owl.Data.t()]
  def banner(profile) do
    [["Allbert TUI ", Owl.Data.tag("(#{profile})", :cyan)], "Type /quit to exit."]
  end

  @spec prompt(String.t()) :: Owl.Data.t()
  def prompt(profile), do: [Owl.Data.tag("allbert", :cyan), ":", profile, "> "]

  @spec status(String.t(), atom()) :: Owl.Data.t()
  def status(profile, state), do: [prompt(profile), Owl.Data.tag(to_string(state), :light_black)]

  @spec render_response(map(), keyword()) :: {:ok, [String.t()]}
  def render_response(response, opts \\ []) when is_map(response) do
    max_text_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)

    response
    |> surface_text()
    |> normalize_text()
    |> bound_text(max_text_bytes)
    |> then(&{:ok, [&1]})
  end

  defp surface_text(%{surface_payload: payload}) when is_binary(payload), do: payload
  defp surface_text(%{"surface_payload" => payload}) when is_binary(payload), do: payload
  defp surface_text(%{message: message}) when is_binary(message), do: message
  defp surface_text(%{"message" => message}) when is_binary(message), do: message
  defp surface_text(%{model_payload: payload}) when is_binary(payload), do: payload
  defp surface_text(%{"model_payload" => payload}) when is_binary(payload), do: payload
  defp surface_text(_response), do: ""

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.trim_trailing()
  end

  defp bound_text(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp bound_text(text, max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> String.trim_trailing()
    |> Kernel.<>("...")
  end
end
