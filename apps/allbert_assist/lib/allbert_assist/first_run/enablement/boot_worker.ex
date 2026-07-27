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

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    runner = Keyword.get(opts, :runner, &FirstRun.reconcile_enablement/0)
    result = runner.()
    {:ok, result, {:continue, :stop}}
  end

  @impl true
  def handle_continue(:stop, state), do: {:stop, :normal, state}
end
