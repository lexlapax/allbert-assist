defmodule AllbertAssist.TestSupport.EffectGuardStubsTest do
  @moduledoc """
  Keeps the shared `EffectGuard` stubs honest.

  Two hand-copied stubs drifted to arities their consumers do not call, so every
  call raised `:undef`, the consumer reported its own "unavailable" error, and
  the stale-epoch path each owning test existed to prove was never reached. The
  tests still passed their other rows, so nothing said anything.

  This asserts the stubs stay callable at the arities production uses. If
  `EffectGuard` changes shape, this fails once and loudly rather than quietly
  disabling several other tests.
  """

  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.TestSupport.EffectGuardStubs.Recording
  alias AllbertAssist.TestSupport.EffectGuardStubs.StaleEpoch

  defp arities(module, name) do
    module.__info__(:functions)
    |> Enum.filter(&(elem(&1, 0) == name))
    |> Enum.map(&elem(&1, 1))
    |> MapSet.new()
  end

  test "every stub arity is one EffectGuard actually exports" do
    for name <- [:admit_ready, :validate], stub <- [StaleEpoch, Recording] do
      stub_arities = arities(stub, name)

      if MapSet.size(stub_arities) > 0 do
        assert MapSet.subset?(stub_arities, arities(EffectGuard, name)),
               "#{inspect(stub)}.#{name} exports #{inspect(MapSet.to_list(stub_arities))}, " <>
                 "which EffectGuard does not: " <>
                 "#{inspect(MapSet.to_list(arities(EffectGuard, name)))}"
      end
    end
  end

  test "StaleEpoch covers the bare-module call shape" do
    assert 0 in arities(StaleEpoch, :admit_ready)
    assert 1 in arities(StaleEpoch, :validate)

    assert {:ok, epoch} = StaleEpoch.admit_ready()
    assert {:error, :stale_epoch} = StaleEpoch.validate(epoch)
  end

  test "Recording covers the module-plus-server call shape and reports both sides" do
    assert 1 in arities(Recording, :admit_ready)
    assert 2 in arities(Recording, :validate)

    test_pid = self()
    epoch = %{barrier_pid: test_pid, snapshot_digest: String.duplicate("b", 64)}
    replacement = %{epoch | snapshot_digest: String.duplicate("c", 64)}

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          epoch: epoch,
          replacement: replacement,
          test_pid: test_pid,
          admit_count: 0,
          validate_count: 0
        }
      end)

    assert {:ok, ^epoch} = Recording.admit_ready(agent)
    assert_receive {:epoch_admitted, ^epoch}

    assert {:error, :stale_epoch} = Recording.validate(agent, epoch)
    assert :ok = Recording.validate(agent, replacement)

    assert Agent.get(agent, & &1.admit_count) == 1
    assert Agent.get(agent, & &1.validate_count) == 2
  end

  test "Recording lets a caller name the messages it sends" do
    test_pid = self()
    epoch = %{barrier_pid: test_pid, snapshot_digest: String.duplicate("d", 64)}

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          epoch: epoch,
          replacement: epoch,
          test_pid: test_pid,
          admit_count: 0,
          validate_count: 0,
          admitted_tag: :custom_admitted,
          validated_tag: :custom_validated
        }
      end)

    assert {:ok, ^epoch} = Recording.admit_ready(agent)
    assert_receive {:custom_admitted, ^epoch}

    assert :ok = Recording.validate(agent, epoch)
    assert_receive {:custom_validated, ^epoch}
  end
end
