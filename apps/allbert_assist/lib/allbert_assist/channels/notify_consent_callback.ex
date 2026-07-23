defmodule AllbertAssist.Channels.NotifyConsentCallback do
  @moduledoc "Identity-reproved typed-command callback for ADR 0084 consent."

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Runtime.Response

  @command "ALLBERT:NOTIFY:ON"

  def command, do: @command
  def typed_command?(text) when is_binary(text), do: String.trim(text) == @command
  def typed_command?(_text), do: false

  def run(request) when is_map(request) do
    channel = request |> field(:channel) |> to_string()
    user_id = field(request, :user_id)
    metadata = field(request, :metadata) || field(request, :resolver_metadata) || %{}
    external_user_id = field(metadata, :external_user_id)

    with {:ok, settings} <- Channels.channel_settings(channel),
         {:ok, resolved_user_id} <-
           Identity.resolve(
             channel,
             to_string(external_user_id),
             Map.get(settings, "identity_map", [])
           ),
         true <- resolved_user_id == user_id,
         {:ok, result} <-
           Runner.run(
             "configure_channel_setting",
             %{channel: channel, key: "autonomous_notify.enabled", value: true},
             %{request: request, actor: user_id, operator_id: user_id, channel: channel}
           ),
         :ok <- Notify.accept_consent(channel, user_id) do
      {:ok, result}
    else
      false -> {:error, :wrong_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def response({:ok, %{status: :completed}}),
    do: Response.completed("Autonomous completion reports are now enabled for this channel.")

  def response({:ok, response}), do: response

  def response({:error, reason}),
    do: Response.error("I could not enable channel notifications.", reason)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
