defmodule AllbertAssist.Channels.TUI.SlashCommands do
  @moduledoc false

  alias AllbertAssist.Actions.Runner

  @canonical_commands [
    "/status",
    "/confirmations",
    "/events",
    "/channels",
    "/intents",
    "/models",
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

  @spec requires_identity?(String.t()) :: boolean()
  def requires_identity?(text) when is_binary(text) do
    case text |> normalize() |> route() do
      {:action, _name, _params} -> true
      {:local, _response} -> false
    end
  end

  def requires_identity?(_text), do: false

  @spec dispatch(String.t(), map()) :: {:ok, map()}
  def dispatch(text, context \\ %{}) when is_binary(text) do
    case text |> normalize() |> route() do
      {:local, response} ->
        {:ok, response}

      {:action, action_name, params} ->
        Runner.run(action_name, params, context)
    end
  end

  @spec unavailable_response(atom()) :: map()
  def unavailable_response(:disabled) do
    local_response(
      "Slash command unavailable: terminal profile is disabled.",
      "TUI operator slash command unavailable: disabled identity."
    )
  end

  def unavailable_response(_reason) do
    local_response(
      "Slash command unavailable: terminal profile is not mapped to an Allbert user.",
      "TUI operator slash command unavailable: unmapped identity."
    )
  end

  defp normalize(text), do: String.trim(text)

  defp route(text) do
    case String.split(text, ~r/\s+/, parts: 3, trim: true) do
      ["/help"] ->
        {:local, local_response(help_text(), "TUI operator slash help.")}

      ["/status"] ->
        {:action, "operator_status", %{}}

      ["/confirmations"] ->
        {:action, "operator_confirmations", %{status: "all"}}

      ["/events"] ->
        {:action, "operator_events", %{limit: 10}}

      ["/channels"] ->
        {:action, "operator_channels", %{}}

      ["/intents"] ->
        {:action, "intent_coverage", %{}}

      ["/models"] ->
        {:action, "model_doctor", %{}}

      ["/settings", "get", key] ->
        key = String.trim(key)

        cond do
          key == "" ->
            {:local,
             local_response("Usage: /settings get <key>", "Malformed TUI settings slash command.")}

          not valid_setting_key?(key) ->
            {:local,
             local_response("Invalid setting key.", "Malformed TUI settings slash command.")}

          true ->
            {:action, "operator_setting_get", %{key: key}}
        end

      ["/settings", "get"] ->
        {:local,
         local_response("Usage: /settings get <key>", "Malformed TUI settings slash command.")}

      _unknown ->
        {:local,
         local_response(
           "Unknown slash command. Type /help for available commands.",
           "Unknown TUI operator slash command."
         )}
    end
  end

  defp valid_setting_key?(key), do: Regex.match?(~r/^[A-Za-z0-9_.-]+$/, key)

  defp local_response(surface_payload, model_payload) do
    %{
      status: :completed,
      surface_payload: surface_payload,
      model_payload: model_payload
    }
  end

  defp help_text do
    [
      "Available slash commands:",
      Enum.map_join(@canonical_commands, "\n", &"- #{&1}")
    ]
    |> Enum.join("\n")
  end
end
