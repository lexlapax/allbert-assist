defmodule AllbertAssist.PublicProtocol.ResultReadbackSweeper do
  @moduledoc """
  Supervised TTL sweep for public protocol result readback rows.

  This process owns no read authority. It only calls
  `AllbertAssist.PublicProtocol.ResultReadback.sweep_expired/1` so expired
  result/error bytes are cleared even when a public client never polls again.
  """

  use GenServer

  require Logger

  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.Settings

  @default_interval_ms 60_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec run_once(GenServer.server(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run_once(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:run_once, opts})
  catch
    :exit, reason -> {:error, {:readback_sweeper_unavailable, reason}}
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, settings_interval_ms()),
      timer_ref: nil,
      result_readback: Keyword.get(opts, :result_readback, ResultReadback),
      schedule?: Keyword.get(opts, :schedule?, default_schedule?())
    }

    {:ok, maybe_schedule_next(state)}
  end

  @impl true
  def handle_call({:run_once, opts}, _from, state) do
    {:reply, sweep(state, opts), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _result = sweep(state, [])
    {:noreply, maybe_schedule_next(%{state | timer_ref: nil})}
  end

  defp sweep(%{result_readback: result_readback}, opts) do
    case result_readback.sweep_expired(opts) do
      {:ok, _count} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning("public protocol result readback sweep failed reason=#{inspect(reason)}")
        error
    end
  rescue
    exception ->
      Logger.warning(
        "public protocol result readback sweep failed reason=#{Exception.message(exception)}"
      )

      {:error, exception}
  end

  defp maybe_schedule_next(%{schedule?: true} = state), do: schedule_next(state)
  defp maybe_schedule_next(state), do: state

  defp schedule_next(%{interval_ms: interval} = state)
       when is_integer(interval) and interval > 0 do
    %{state | timer_ref: Process.send_after(self(), :sweep, interval)}
  end

  defp schedule_next(state), do: state

  defp default_schedule? do
    not repo_uses_sql_sandbox?()
  end

  defp repo_uses_sql_sandbox? do
    :allbert_assist
    |> Application.get_env(AllbertAssist.Repo, [])
    |> Keyword.get(:pool)
    |> Kernel.==(Ecto.Adapters.SQL.Sandbox)
  end

  defp settings_interval_ms do
    case Settings.get("public_protocol.result_readback_sweep_interval_ms") do
      {:ok, interval_ms} when is_integer(interval_ms) and interval_ms > 0 -> interval_ms
      _other -> @default_interval_ms
    end
  rescue
    _exception -> @default_interval_ms
  end
end
