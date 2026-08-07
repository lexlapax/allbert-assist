defmodule AllbertAssist.DynamicPlugins.Reconciler do
  @moduledoc """
  One-shot boot reconciliation for dynamic integration metadata.

  Plain GenServer is used only to sequence the post-start reconciliation after
  the overlay process exists. It stores the latest bounded result for
  observability; durable authority still lives in Allbert Home metadata.
  """

  use GenServer

  alias AllbertAssist.DynamicPlugins.Loader
  alias AllbertAssist.Pack.EffectGuard

  @retry_delay_ms 100

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return the last reconciliation result recorded by this node."
  def last_result(server \\ __MODULE__) do
    case Process.whereis(server) do
      nil -> nil
      _pid -> GenServer.call(server, :last_result)
    end
  end

  @impl true
  def init(opts) do
    send(self(), :reconcile)

    {:ok,
     %{
       last_result: nil,
       loader: Keyword.get(opts, :loader, Loader),
       effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
       retry_timer: nil
     }}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {result, retry?} = reconcile_when_ready(state)
    state = %{state | last_result: result, retry_timer: nil}
    {:noreply, if(retry?, do: schedule_retry(state), else: state)}
  end

  @impl true
  def handle_call(:last_result, _from, state) do
    {:reply, state.last_result, state}
  end

  defp reconcile_when_ready(state) do
    case admit_ready_epoch(state) do
      {:ok, epoch} ->
        case validate_epoch(epoch, state) do
          :ok -> {loader_reconcile(state.loader), false}
          {:error, _reason} -> {{:error, :product_not_ready}, false}
        end

      {:error, _reason} ->
        {{:error, :product_not_ready}, true}
    end
  end

  defp schedule_retry(%{retry_timer: nil} = state) do
    %{state | retry_timer: Process.send_after(self(), :reconcile, @retry_delay_ms)}
  end

  defp schedule_retry(state), do: state

  defp admit_ready_epoch(state), do: effect_guard_call(state.effect_guard, :admit_ready, [])

  defp validate_epoch(epoch, state), do: effect_guard_call(state.effect_guard, :validate, [epoch])

  defp effect_guard_call({module, owner}, function, args),
    do: apply(module, function, [owner | args])

  defp effect_guard_call(module, function, args), do: apply(module, function, args)

  defp loader_reconcile({module, owner}), do: module.reconcile(owner)
  defp loader_reconcile(module), do: module.reconcile()
end
