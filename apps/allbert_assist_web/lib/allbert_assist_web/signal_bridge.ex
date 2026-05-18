defmodule AllbertAssistWeb.SignalBridge do
  @moduledoc """
  Bridges objective and workspace lifecycle signals from Jido.Signal.Bus to
  Phoenix.PubSub.

  The bridge is web-only. Headless CLI deployments do not need it; signals
  still publish normally through the core signal bus.
  """

  use GenServer

  require Logger

  alias Jido.Signal
  alias Jido.Signal.Bus

  @objective_pattern "allbert.objective.**"
  @workspace_pattern "allbert.workspace.**"
  @topic_prefix "objectives:"

  @spec topic_for(String.t()) :: String.t()
  def topic_for(user_id) when is_binary(user_id), do: @topic_prefix <> user_id

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    subscribe_fun = Keyword.get(opts, :subscribe_fun, &Bus.subscribe/2)

    subscription_ids =
      %{
        objective: @objective_pattern,
        workspace: @workspace_pattern
      }
      |> Enum.map(fn {kind, pattern} -> {kind, subscribe(kind, pattern, subscribe_fun)} end)
      |> Map.new()

    {:ok, %{subscription_ids: subscription_ids}}
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    cond do
      String.starts_with?(signal.type, "allbert.objective.") ->
        broadcast(signal, :objective_event)

      String.starts_with?(signal.type, "allbert.workspace.") ->
        broadcast(signal, :workspace_event)

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp subscribe(kind, pattern, subscribe_fun) do
    case subscribe_fun.(AllbertAssist.SignalBus, pattern) do
      {:ok, subscription_id} ->
        subscription_id

      {:error, reason} ->
        Logger.warning("#{kind} signal bridge subscription failed: #{inspect(reason)}")
        nil
    end
  end

  defp broadcast(%Signal{data: data} = signal, event) when is_map(data) do
    case Map.get(data, :user_id) || Map.get(data, "user_id") do
      user_id when is_binary(user_id) and user_id != "" ->
        Phoenix.PubSub.broadcast(
          AllbertAssistWeb.PubSub,
          topic_for(user_id),
          {event, signal}
        )

      _other ->
        :ok
    end
  end

  defp broadcast(_signal, _event), do: :ok
end
