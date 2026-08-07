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
      runner = Keyword.get(opts, :runner, &FirstRun.reconcile_enablement/0)
      latch = Keyword.get(opts, :latch)

      result =
        if is_nil(latch) or not Latch.completed?(latch) do
          result = runner.()
          if latch, do: Latch.complete(latch)
          result
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
end
