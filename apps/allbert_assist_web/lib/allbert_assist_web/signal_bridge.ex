defmodule AllbertAssistWeb.SignalBridge do
  @moduledoc """
  Bridges objective lifecycle signals from Jido.Signal.Bus to Phoenix.PubSub.

  The bridge is web-only. Headless CLI deployments do not need it; objective
  signals still publish normally through the core signal bus.
  """

  use GenServer

  require Logger

  alias Jido.Signal
  alias Jido.Signal.Bus

  @objective_pattern "allbert.objective.**"
  @topic_prefix "objectives:"

  @spec topic_for(String.t()) :: String.t()
  def topic_for(user_id) when is_binary(user_id), do: @topic_prefix <> user_id

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    case Bus.subscribe(AllbertAssist.SignalBus, @objective_pattern) do
      {:ok, subscription_id} ->
        {:ok, %{subscription_id: subscription_id}}

      {:error, reason} ->
        Logger.warning("objective signal bridge subscription failed: #{inspect(reason)}")
        {:ok, %{subscription_id: nil}}
    end
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    if String.starts_with?(signal.type, "allbert.objective.") do
      broadcast(signal)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp broadcast(%Signal{data: data} = signal) when is_map(data) do
    case Map.get(data, :user_id) || Map.get(data, "user_id") do
      user_id when is_binary(user_id) and user_id != "" ->
        Phoenix.PubSub.broadcast(
          AllbertAssistWeb.PubSub,
          topic_for(user_id),
          {:objective_event, signal}
        )

      _other ->
        :ok
    end
  end

  defp broadcast(_signal), do: :ok
end
