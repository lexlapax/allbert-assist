defmodule AllbertAssist.Channels.TUI.SlashCommands do
  @moduledoc false

  @canonical_commands [
    "/status",
    "/confirmations",
    "/events",
    "/channels",
    "/settings get",
    "/help"
  ]

  @spec slash?(term()) :: boolean()
  def slash?(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.starts_with?("/")
  end

  def slash?(_text), do: false

  @spec canonical_commands() :: [String.t()]
  def canonical_commands, do: @canonical_commands

  @spec dispatch(String.t(), map()) :: {:ok, map()}
  def dispatch(text, _context \\ %{}) when is_binary(text) do
    text
    |> normalize()
    |> route()
  end

  defp normalize(text), do: String.trim(text)

  defp route("/help") do
    {:ok,
     %{
       status: :completed,
       surface_payload: help_text(),
       model_payload: "TUI operator slash help."
     }}
  end

  defp route(_unknown) do
    {:ok,
     %{
       status: :completed,
       surface_payload: "Unknown slash command. Type /help for available commands.",
       model_payload: "Unknown TUI operator slash command."
     }}
  end

  defp help_text do
    [
      "Available slash commands:",
      Enum.map_join(@canonical_commands, "\n", &"- #{&1}")
    ]
    |> Enum.join("\n")
  end
end
