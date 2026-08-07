defmodule AllbertAssist.DynamicPlugins.ReconcilerTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.DynamicPlugins.Reconciler

  defmodule EpochGuard do
    def admit_ready(agent) do
      Agent.get_and_update(agent, fn state ->
        send(state.test_pid, {:reconciler_epoch_admitted, state.epoch})
        {{:ok, state.epoch}, Map.update!(state, :admit_count, &(&1 + 1))}
      end)
    end

    def validate(agent, epoch) do
      Agent.get_and_update(agent, fn state ->
        send(state.test_pid, {:reconciler_epoch_validated, epoch})

        result =
          if epoch == state.replacement,
            do: :ok,
            else: {:error, :stale_epoch}

        {result, Map.update!(state, :validate_count, &(&1 + 1))}
      end)
    end
  end

  defmodule LoaderSpy do
    def reconcile(agent) do
      Agent.update(agent, fn state -> Map.update!(state, :calls, &(&1 + 1)) end)
      {:ok, %{status: :completed, integrations: []}}
    end
  end

  test "same-digest replacement after admission does not load dynamic integrations" do
    digest = String.duplicate("c", 64)
    barrier_one = spawn(fn -> Process.sleep(:infinity) end)
    barrier_two = spawn(fn -> Process.sleep(:infinity) end)
    epoch = %{barrier_pid: barrier_one, snapshot_digest: digest}
    test_pid = self()

    on_exit(fn ->
      if Process.alive?(barrier_one), do: Process.exit(barrier_one, :kill)
      if Process.alive?(barrier_two), do: Process.exit(barrier_two, :kill)
    end)

    guard =
      start_supervised!(
        {Agent,
         fn ->
           %{
             epoch: epoch,
             replacement: %{barrier_pid: barrier_two, snapshot_digest: digest},
             test_pid: test_pid,
             admit_count: 0,
             validate_count: 0
           }
         end},
        id: :reconciler_epoch_guard
      )

    loader = start_supervised!({Agent, fn -> %{calls: 0} end}, id: :reconciler_loader_spy)
    name = :"dynamic-plugins-reconciler-#{System.unique_integer([:positive])}"

    reconciler =
      start_supervised!(
        {Reconciler, name: name, effect_guard: {EpochGuard, guard}, loader: {LoaderSpy, loader}}
      )

    assert_receive {:reconciler_epoch_admitted, ^epoch}, 1_000
    assert_receive {:reconciler_epoch_validated, ^epoch}, 1_000
    assert eventually(fn -> Reconciler.last_result(name) == {:error, :product_not_ready} end)
    assert Agent.get(loader, & &1.calls) == 0
    assert Agent.get(guard, & &1.admit_count) == 1
    assert Agent.get(guard, & &1.validate_count) == 1
    assert Process.alive?(reconciler)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
