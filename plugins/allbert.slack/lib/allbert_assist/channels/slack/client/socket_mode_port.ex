defmodule AllbertAssist.Channels.Slack.Client.SocketModePort do
  @moduledoc false

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback push(pid() | atom(), map()) :: :ok | {:error, term()}
  @callback ack(pid() | atom(), String.t(), map() | nil) :: :ok | {:error, term()}
end
