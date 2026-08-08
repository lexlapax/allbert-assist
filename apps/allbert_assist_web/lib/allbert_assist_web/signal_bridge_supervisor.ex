defmodule AllbertAssistWeb.SignalBridgeSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias AllbertAssistWeb.PackReadiness

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec open(map(), GenServer.server(), GenServer.server()) ::
          {:ok, pid()} | {:error, term()}
  def open(epoch, supervisor \\ __MODULE__, readiness_server \\ PackReadiness)
      when is_map(epoch) do
    with :ok <- validate_epoch(readiness_server, epoch) do
      open_child(epoch, supervisor, readiness_server)
    else
      {:error, _reason} -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp validate_epoch(PackReadiness, epoch), do: PackReadiness.validate(epoch)

  defp validate_epoch(readiness_server, epoch) do
    try do
      GenServer.call(readiness_server, {:validate, epoch}, 150)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  defp open_child(epoch, supervisor, readiness_server) do
    validate_fun = fn candidate_epoch -> validate_epoch(readiness_server, candidate_epoch) end

    case DynamicSupervisor.start_child(
           supervisor,
           {AllbertAssistWeb.SignalBridge, validate_fun: validate_fun}
         ) do
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
