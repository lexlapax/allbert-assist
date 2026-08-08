defmodule AllbertAssist.Kernel.ContractTest do
  # The binding is one global publication, so these rows own it for their
  # duration rather than sharing it with a concurrent test.
  use ExUnit.Case, async: false

  alias AllbertAssist.Kernel.Contract
  alias AllbertAssist.Kernel.Contract.Binding
  alias AllbertAssist.Kernel.Contract.TestProviders

  setup do
    previous = Contract.current()
    Contract.release()

    on_exit(fn ->
      case previous do
        {:ok, %Binding{} = binding} ->
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

    %{barrier: self(), generation: "generation-under-test"}
  end

  # --- rejection before binding ------------------------------------------
  #
  # Every one of these must fail closed. A permissive binder would leave the
  # kernel answering from a provider composition never validated, which is the
  # failure mode the boundary exists to prevent.

  describe "rejects a set that cannot be trusted" do
    test "a missing contract fails the whole bind", ctx do
      assert {:error, {:missing_contracts, [:settings]}} =
               Contract.bind(TestProviders.without(:settings), ctx.generation, ctx.barrier)

      assert {:error, :unbound} = Contract.current()
    end

    test "every contract in the closed set is required, not just one", ctx do
      for contract <- Contract.ids() do
        assert {:error, {:missing_contracts, [^contract]}} =
                 Contract.bind(TestProviders.without(contract), ctx.generation, ctx.barrier)
      end

      assert {:error, :unbound} = Contract.current()
    end

    test "a duplicate provider for one contract fails rather than picking a winner", ctx do
      assert {:error, {:duplicate_providers, [:confirmations]}} =
               Contract.bind(TestProviders.duplicating(:confirmations), ctx.generation, ctx.barrier)

      assert {:error, :unbound} = Contract.current()
    end

    test "an unknown contract id is rejected instead of being carried along", ctx do
      providers = TestProviders.complete() ++ [{:not_a_contract, TestProviders, :allbert_kernel}]

      assert {:error, {:unknown_contracts, [:not_a_contract]}} =
               Contract.bind(providers, ctx.generation, ctx.barrier)

      assert {:error, :unbound} = Contract.current()
    end

    test "a malformed provider row never reaches validation", ctx do
      for row <- [{:confirmations, TestProviders}, %{contract: :confirmations}, :confirmations, nil] do
        assert {:error, {:malformed_provider, _row}} =
                 Contract.bind([row | TestProviders.complete()], ctx.generation, ctx.barrier)
      end

      assert {:error, :unbound} = Contract.current()
    end

    test "a blank atom cannot stand in for a module or application", ctx do
      for blank <- [nil, true, false] do
        providers = TestProviders.replacing(:confirmations, blank)

        assert {:error, {:malformed_provider, _provider}} =
                 Contract.bind(providers, ctx.generation, ctx.barrier)
      end

      assert {:error, :unbound} = Contract.current()
    end

    test "a provider module that does not exist is rejected", ctx do
      providers = TestProviders.replacing(:confirmations, AllbertAssist.Kernel.NoSuchProvider)

      assert {:error, {:provider_not_loaded, :confirmations, _module}} =
               Contract.bind(providers, ctx.generation, ctx.barrier)

      assert {:error, :unbound} = Contract.current()
    end

    test "a provider missing a required callback is malformed", ctx do
      # `Contract` itself is loaded and first-party, but exports none of the
      # membership callbacks. Every missing one is named, not just the first.
      providers = TestProviders.replacing(:membership, Contract)

      assert {:error, {:malformed_provider, :membership, Contract, missing}} =
               Contract.bind(providers, ctx.generation, ctx.barrier)

      assert Enum.sort(missing) == [
               app_id_for_action: 2,
               known_app_id?: 2,
               plugin_id_for_action: 2,
               registered_plugins: 1
             ]

      assert {:error, :unbound} = Contract.current()
    end

    test "a provider in an application that is not running is unavailable", ctx do
      providers = TestProviders.replacing(:confirmations, TestProviders, :no_such_application)

      assert {:error, {:provider_application_unavailable, :confirmations, :no_such_application}} =
               Contract.bind(providers, ctx.generation, ctx.barrier)

      assert {:error, :unbound} = Contract.current()
    end

    test "a provider that does not reside in the application it claims is rejected", ctx do
      # Loaded, first-party, exports the callbacks — but it belongs to
      # :allbert_kernel, not :elixir. Declaring residence is not proving it.
      providers = TestProviders.replacing(:confirmations, TestProviders, :elixir)

      assert {:error, {:provider_application_mismatch, :confirmations, TestProviders, :elixir}} =
               Contract.bind(providers, ctx.generation, ctx.barrier)

      assert {:error, :unbound} = Contract.current()
    end

    test "a generation that is not a non-empty binary is rejected", ctx do
      for generation <- ["", nil, :generation, 1] do
        assert {:error, {:invalid_generation, ^generation}} =
                 Contract.bind(TestProviders.complete(), generation, ctx.barrier)
      end

      assert {:error, :unbound} = Contract.current()
    end

    test "a dead or absent barrier is rejected", ctx do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      assert {:error, {:barrier_not_alive, ^dead}} =
               Contract.bind(TestProviders.complete(), ctx.generation, dead)

      assert {:error, {:invalid_barrier, :not_a_pid}} =
               Contract.bind(TestProviders.complete(), ctx.generation, :not_a_pid)

      assert {:error, :unbound} = Contract.current()
    end

    test "a rejected set leaves an existing binding untouched", ctx do
      assert {:ok, _binding} = Contract.bind(TestProviders.complete(), "first", ctx.barrier)

      assert {:error, {:missing_contracts, _missing}} =
               Contract.bind(TestProviders.without(:settings), "second", ctx.barrier)

      assert {:ok, "first"} = Contract.generation()
    end
  end

  # --- fail-closed reads --------------------------------------------------

  describe "unbound and stale reads" do
    test "every contract fails closed while unbound" do
      for contract <- Contract.ids() do
        assert {:error, :unbound} = Contract.fetch(contract)
      end
    end

    test "release deletes the set as a unit and retains nothing", ctx do
      assert {:ok, _binding} = Contract.bind(TestProviders.complete(), ctx.generation, ctx.barrier)
      assert {:ok, TestProviders} = Contract.fetch(:confirmations)

      assert :ok = Contract.release()

      for contract <- Contract.ids() do
        assert {:error, :unbound} = Contract.fetch(contract)
      end

      assert {:error, :unbound} = Contract.generation()
    end

    test "a caller carrying an earlier generation is refused, not upgraded", ctx do
      assert {:ok, _binding} = Contract.bind(TestProviders.complete(), "epoch-2", ctx.barrier)

      assert {:error, {:stale_generation, "epoch-2", "epoch-1"}} =
               Contract.fetch(:confirmations, "epoch-1")

      assert {:ok, TestProviders} = Contract.fetch(:confirmations, "epoch-2")
    end

    test "an id outside the closed set never resolves", ctx do
      assert {:ok, _binding} = Contract.bind(TestProviders.complete(), ctx.generation, ctx.barrier)

      assert {:error, {:unknown_contract, :anything}} = Contract.fetch(:anything)
      assert {:error, {:unknown_contract, :anything}} = Contract.fetch(:anything, ctx.generation)
    end
  end

  # --- positive binding, only after the rejections hold -------------------

  describe "binding a validated set" do
    test "publishes every contract atomically against one generation", ctx do
      assert {:ok, %Binding{} = binding} =
               Contract.bind(TestProviders.complete(), ctx.generation, ctx.barrier)

      assert binding.generation == ctx.generation
      assert binding.barrier_pid == ctx.barrier
      assert Map.keys(binding.providers) |> Enum.sort() == Contract.ids()

      for contract <- Contract.ids() do
        assert {:ok, TestProviders} = Contract.fetch(contract)
      end
    end

    test "the closed set and its required callbacks are declared, not inferred" do
      for contract <- Contract.ids() do
        callbacks = Contract.required_callbacks(contract)
        assert is_list(callbacks) and callbacks != []
        assert Enum.all?(callbacks, fn {fun, arity} -> is_atom(fun) and is_integer(arity) end)
      end

      assert Contract.required_callbacks(:not_a_contract) == nil
    end

    test "there is no generic lookup entry point" do
      # The absence of a service locator is the architectural property, so it is
      # asserted rather than left to review. `fetch/1,2` are the only resolvers
      # and both are guarded by the closed set.
      exported =
        Contract.__info__(:functions)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.sort()

      assert exported == [:bind, :current, :fetch, :generation, :ids, :release, :required_callbacks]
    end
  end
end
