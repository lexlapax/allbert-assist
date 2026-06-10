defmodule AllbertAssist.Channels.Slack.Client.SocketModePort.Real do
  @moduledoc false

  @behaviour AllbertAssist.Channels.Slack.Client.SocketModePort

  @impl true
  def start_link(_opts), do: {:error, :slack_socket_mode_real_transport_deferred_to_m4}

  @impl true
  def push(_server, _envelope), do: {:error, :slack_socket_mode_real_transport_deferred_to_m4}

  @impl true
  def ack(_server, _envelope_id, _payload \\ nil),
    do: {:error, :slack_socket_mode_real_transport_deferred_to_m4}
end
