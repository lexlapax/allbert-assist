defmodule AllbertAssist.Objectives.Runs.Cancel do
  @moduledoc "Tiered cancellation coordinator for one supervised objective run."

  alias AllbertAssist.Execution.ProcessOwner
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Settings

  @spec cancel(String.t(), keyword()) :: {:ok, :cooperative | :supervised | :os_kill}
  def cancel(child_id, opts \\ []) when is_binary(child_id) do
    grace_ms = Keyword.get_lazy(opts, :grace_ms, &grace_ms/0)

    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:run, child_id}) do
      [] ->
        {:ok, cancel_execution(child_id, :cooperative)}

      [{run_pid, %CancelToken{} = token}] ->
        :ok = CancelToken.cancel(token)
        await_checkpoint(run_pid, child_id, grace_ms)
    end
  end

  defp await_checkpoint(run_pid, child_id, grace_ms) do
    monitor = Process.monitor(run_pid)

    receive do
      {:DOWN, ^monitor, :process, ^run_pid, _reason} -> {:ok, :cooperative}
    after
      grace_ms ->
        Process.demonitor(monitor, [:flush])
        tier = cancel_execution(child_id, :supervised)
        _ = DynamicSupervisor.terminate_child(AllbertAssist.Objectives.Runs.Supervisor, run_pid)
        {:ok, tier}
    end
  end

  defp cancel_execution(child_id, fallback) do
    case ProcessOwner.cancel(child_id) do
      {:ok, :os_kill} -> :os_kill
      _other -> fallback
    end
  end

  defp grace_ms do
    case Settings.get("execution.cancel.grace_ms") do
      {:ok, value} when is_integer(value) -> value
      _other -> 5_000
    end
  end
end
