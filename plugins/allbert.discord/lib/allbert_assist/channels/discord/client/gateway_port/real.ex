defmodule AllbertAssist.Channels.Discord.Client.GatewayPort.Real do
  @moduledoc false

  @behaviour AllbertAssist.Channels.Discord.Client.GatewayPort

  @impl true
  def start_link(_opts), do: {:error, :discord_gateway_real_transport_deferred_to_m4}
  @impl true
  def push(_server, _event), do: {:error, :discord_gateway_real_transport_deferred_to_m4}
end
