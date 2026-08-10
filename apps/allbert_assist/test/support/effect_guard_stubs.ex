defmodule AllbertAssist.TestSupport.EffectGuardStubs do
  @moduledoc """
  The two `EffectGuard` stub shapes tests inject, defined once.

  These existed as five hand-copied `defmodule`s across five test files, and two
  of those copies silently rotted: `SameDigestReplacementGuard` in both
  `result_readback_test` and `router_index_reindex_test` defined
  `admit_ready/1` and `validate/2` while their consumers call `/0` and `/1`.
  Every call raised `:undef`, the consumer reported its own "unavailable" error,
  and the stale-epoch path each test exists to prove was never exercised. Two
  independent copies drifted the same way, which is what copies do.

  There are genuinely two shapes because production injects a guard two ways:

  - a bare module, called as `guard.admit_ready()` / `guard.validate(epoch)` —
    `ResultReadbackSweeper` and `Router.Index`. Use `StaleEpoch`.
  - a `{module, server}` pair, called as `guard.admit_ready(server)` /
    `guard.validate(server, epoch)` — `Reconciler`, `ReportComposer`, and the
    notify channel. Use `Recording`.

  `AllbertAssist.TestSupport.EffectGuardStubsTest` asserts both shapes stay a
  subset of what `AllbertAssist.Pack.EffectGuard` actually exports, so an arity
  change in production fails one loud test instead of silently disabling
  several quiet ones.
  """

  defmodule StaleEpoch do
    @moduledoc """
    Admits an epoch, then rejects it as stale — the same-digest barrier
    replacement. Mirrors the arities a bare-module consumer calls.
    """

    @digest String.duplicate("a", 64)

    def admit_ready, do: {:ok, %{barrier_pid: self(), snapshot_digest: @digest}}

    def validate(_epoch), do: {:error, :stale_epoch}
  end

  defmodule Recording do
    @moduledoc """
    Agent-backed guard that reports every admission and validation to the test
    and counts both. Validation succeeds only for the agent's `:replacement`
    epoch, so a test can prove a stale epoch is refused.

    Agent state: `:epoch`, `:replacement`, `:test_pid`, `:admit_count`,
    `:validate_count`, and optionally `:admitted_tag` / `:validated_tag` to name
    the messages sent (defaulting to `:epoch_admitted` / `:epoch_validated`).
    """

    def admit_ready(agent) do
      Agent.get_and_update(agent, fn state ->
        send(state.test_pid, {tag(state, :admitted_tag, :epoch_admitted), state.epoch})
        {{:ok, state.epoch}, Map.update!(state, :admit_count, &(&1 + 1))}
      end)
    end

    def validate(agent, epoch) do
      Agent.get_and_update(agent, fn state ->
        send(state.test_pid, {tag(state, :validated_tag, :epoch_validated), epoch})

        result = if epoch == state.replacement, do: :ok, else: {:error, :stale_epoch}

        {result, Map.update!(state, :validate_count, &(&1 + 1))}
      end)
    end

    defp tag(state, key, default), do: Map.get(state, key, default)
  end
end
