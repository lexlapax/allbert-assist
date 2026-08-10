defmodule AllbertAssist.TestSupport.EffectGuardStubsTest do
  @moduledoc """
  Keeps the shared `EffectGuard` stubs honest, and the epoch's opts key single.

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

  # ADR 0098: EffectGuard validates the epoch "through the sole public
  # `:allbert_pack_epoch` context/option key". A second opts key carrying the
  # same thing existed anyway, and it cost a real defect -- one opts list in
  # Runs.Coordinator was read by TerminalTransitions under `:effect_context` and
  # by Objectives.Lifecycle under `:allbert_pack_epoch`, so whichever module read
  # the key the caller had not set failed closed with `:product_not_ready`.
  #
  # Nothing tested the key, only that some epoch arrived, so the drift was
  # invisible. This tests the key.
  #
  # `effect_context` survives as a *data field* -- on the composition claim, on
  # Lifecycle state, in Jido signal payloads -- which is why this looks for
  # `Keyword.*` calls naming the atom rather than for the atom itself.
  @forbidden_opts_key ~r/Keyword\.[a-z_!?]+\([^)]*:effect_context/

  defp umbrella_root, do: Path.expand("../../../../..", __DIR__)

  defp production_sources do
    ["apps/*/lib/**/*.ex", "plugins/*/lib/**/*.ex"]
    |> Enum.flat_map(&Path.wildcard(Path.join(umbrella_root(), &1)))
  end

  test "the readiness epoch has exactly one opts key in production source" do
    sources = production_sources()

    # Guards the guard: a wildcard that matched nothing would pass vacuously.
    assert length(sources) > 100,
           "expected the umbrella's production sources, found #{length(sources)} files " <>
             "under #{umbrella_root()}"

    offenders =
      for path <- sources,
          line <- String.split(File.read!(path), "\n"),
          Regex.match?(@forbidden_opts_key, line),
          do: "#{Path.relative_to(path, umbrella_root())}: #{String.trim(line)}"

    assert offenders == [],
           "ADR 0098 makes :allbert_pack_epoch the sole public option key for the " <>
             "readiness epoch. These read or write a second one:\n" <>
             Enum.join(offenders, "\n")
  end
end
