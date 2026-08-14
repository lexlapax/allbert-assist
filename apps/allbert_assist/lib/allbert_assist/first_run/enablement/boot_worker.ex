defmodule AllbertAssist.FirstRun.Enablement.BootWorker do
  @moduledoc """
  Synchronous one-shot boot barrier for first-run enablement.

  This is a plain GenServer because OTP child initialization must not return
  until detection and the atomic Settings write finish; it has no durable
  state machine or composable skills that would justify Jido.Agent. The worker
  stops normally immediately after the supervisor crosses that barrier.
  """

  use GenServer, restart: :temporary

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstRun.Enablement.Latch
  alias AllbertAssist.Pack.{ActivationContext, ActivationGuard}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    context = Keyword.get(opts, :allbert_pack_activation)

    with %ActivationContext{} <- context,
         :ok <- ActivationGuard.validate(allbert_pack_activation: context) do
      runner =
        Keyword.get(opts, :runner, fn context ->
          FirstRun.reconcile_enablement(context: %{allbert_pack_activation: context})
        end)

      latch = Keyword.get(opts, :latch)

      result =
        if is_nil(latch) or not Latch.completed?(latch) do
          reconcile_and_latch(runner, context, latch)
        else
          :already_reconciled
        end

      # The carrier is deliberately not stored in state: FirstRun is an
      # authorizing boot completion, not a steady-state effect owner.
      {:ok, result, {:continue, :stop}}
    else
      _other -> {:stop, :product_not_ready}
    end
  end

  @impl true
  def handle_continue(:stop, state), do: {:stop, :normal, state}

  defp reconcile_and_latch(runner, context, latch) do
    result = run_authorizing_boot(runner, context)
    if latch, do: Latch.complete(latch)
    result
  end

  defp run_authorizing_boot(runner, context) do
    case :erlang.fun_info(runner, :arity) do
      {:arity, 1} -> runner.(context)
      {:arity, 0} -> runner.()
    end
  end
end
