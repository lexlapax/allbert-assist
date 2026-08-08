defmodule AllbertAssist.Kernel.Contract.OwnerTest do
  # Owns the one global publication for the duration of each row.
  use ExUnit.Case, async: false

  alias AllbertAssist.Kernel.Contract
  alias AllbertAssist.Kernel.Contract.Owner
  alias AllbertAssist.Kernel.Contract.TestProviders

  setup do
    restore = Contract.current()

    on_exit(fn ->
      case restore do
        {:ok, binding} ->
          Contract.bind(
            Enum.map(binding.providers, fn {contract, provider} ->
              {contract, provider.implementation, provider.application}
            end),
            binding.generation,
            binding.barrier_pid
          )

        {:error, :unbound} ->
          Contract.release()
      end
    end)

    {:ok, owner} = start_supervised({Owner, [name: :"contract_owner_#{System.unique_integer()}"]})
    barrier = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(barrier, :kill) end)

    %{owner: owner, barrier: barrier}
  end

  test "binding through the owner publishes the validated set", ctx do
    assert {:ok, _binding} =
             Owner.bind(ctx.owner, TestProviders.complete(), "epoch-1", ctx.barrier)

    assert {:ok, "epoch-1"} = Contract.generation()
    assert {:ok, TestProviders} = Contract.fetch(:settings)
  end

  test "a rejected set is reported with the binder's own reason and publishes nothing", ctx do
    assert {:error, {:missing_contracts, [:signals]}} =
             Owner.bind(ctx.owner, TestProviders.without(:signals), "epoch-1", ctx.barrier)

    assert {:error, :unbound} = Contract.generation()
  end

  test "losing the barrier releases the whole set", ctx do
    assert {:ok, _binding} =
             Owner.bind(ctx.owner, TestProviders.complete(), "epoch-1", ctx.barrier)

    assert {:ok, TestProviders} = Contract.fetch(:settings)

    Process.exit(ctx.barrier, :kill)

    # The owner releases on the monitor message; wait for the observable effect
    # rather than for a sleep to elapse.
    assert eventually(fn -> Contract.generation() == {:error, :unbound} end)

    for contract <- Contract.ids() do
      assert {:error, :unbound} = Contract.fetch(contract)
    end
  end

  test "rebinding a new generation replaces the previous one rather than layering", ctx do
    assert {:ok, _first} = Owner.bind(ctx.owner, TestProviders.complete(), "epoch-1", ctx.barrier)

    second_barrier = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(second_barrier, :kill) end)

    assert {:ok, _second} =
             Owner.bind(ctx.owner, TestProviders.complete(), "epoch-2", second_barrier)

    assert {:ok, "epoch-2"} = Contract.generation()

    # The first barrier is no longer the one being watched, so its death must
    # not tear down the generation that replaced it.
    Process.exit(ctx.barrier, :kill)
    Process.sleep(20)
    assert {:ok, "epoch-2"} = Contract.generation()

    # The one it is watching still does.
    Process.exit(second_barrier, :kill)
    assert eventually(fn -> Contract.generation() == {:error, :unbound} end)
  end

  test "the owner terminating releases the binding", ctx do
    assert {:ok, _binding} =
             Owner.bind(ctx.owner, TestProviders.complete(), "epoch-1", ctx.barrier)

    :ok = stop_supervised(Owner)
    assert {:error, :unbound} = Contract.generation()
  end

  test "a starting owner clears a publication left by an earlier epoch", ctx do
    assert {:ok, _stale} = Contract.bind(TestProviders.complete(), "stale-epoch", ctx.barrier)
    assert {:ok, "stale-epoch"} = Contract.generation()

    {:ok, _replacement} =
      start_supervised(
        Supervisor.child_spec(
          {Owner, [name: :"contract_owner_replacement_#{System.unique_integer()}"]},
          id: :contract_owner_replacement
        )
      )

    assert {:error, :unbound} = Contract.generation()
  end

  test "explicit release deletes the set and stops watching", ctx do
    assert {:ok, _binding} =
             Owner.bind(ctx.owner, TestProviders.complete(), "epoch-1", ctx.barrier)

    assert :ok = Owner.release(ctx.owner)
    assert {:error, :unbound} = Contract.generation()

    # The owner survives the barrier's later death rather than acting on a
    # monitor it already dropped.
    Process.exit(ctx.barrier, :kill)
    Process.sleep(20)
    assert Process.alive?(ctx.owner)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
