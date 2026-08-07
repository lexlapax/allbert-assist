defmodule AllbertAssistWeb.SignalBridgeSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias AllbertAssistWeb.PackReadiness

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec open(map(), DynamicSupervisor.supervisor()) :: {:ok, pid()} | {:error, term()}
  def open(epoch, supervisor \\ __MODULE__) when is_map(epoch) do
    with :ok <- PackReadiness.validate(epoch) do
      open_child(epoch, supervisor)
    else
      {:error, _reason} -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp open_child(epoch, supervisor) do
    case DynamicSupervisor.start_child(supervisor, {AllbertAssistWeb.SignalBridge, []}) do
      {:ok, pid} ->
        case AllbertAssistWeb.SignalBridge.open(pid, epoch) do
          :ok ->
            {:ok, pid}

          {:error, _reason} = error ->
            _ = DynamicSupervisor.terminate_child(supervisor, pid)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
