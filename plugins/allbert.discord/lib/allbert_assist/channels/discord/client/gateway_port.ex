defmodule AllbertAssist.Channels.Discord.Client.GatewayPort do
  @moduledoc false

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback push(pid() | atom(), map()) :: :ok | {:error, term()}
end
