defmodule AllbertAssist.Intent.Eval.GateTest do
  # v1.0.3 M1 pilot conversion (ADR 0086 contract 2): app_env_serial →
  # pure_async through the process-scoped configuration context
  # (`AllbertAssist.ConfigContext`). Red-first serial-requirement proof
  # (recorded in the plan's M1 Build Progress entry): the pre-conversion file
  # mutated VM-global state — `System.put_env("ALLBERT_HOME", …)` plus
  # `Application.delete_env` of the Paths/Settings config — so every other
  # process in the VM observed its home while a test ran; running the
  # "contract-2 context isolation proof" test below with that idiom in both
  # children reproduces the cross-contamination deterministically (both
  # children read the LAST-written global home and one gate verdict flips).
  # Post-conversion each Gate call runs inside a bounded
  # `ConfigContext.with_context([home: …], …)` whose overrides are visible
  # only to the calling process, and descriptor resolution reads a PRIVATE
  # shipped-baseline registry pair (ADR 0082 seam) instead of re-asserting
  # corpus domains into the global registries.
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.ConfigContext
  alias AllbertAssist.Intent.Eval.Gate
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  setup do
    # Private full shipped baseline (complete by construction) replaces the
    # v1.0.2 ProviderPreconditions global re-assertions: the promotion check
    # resolves live descriptors, so it receives this context's resolution
    # through the public `descriptors:` option.
    registry = Fixtures.start_shipped_registries(:intent_eval_gate)
    descriptors = DescriptorResolver.resolve(registry)

    home = owned_home("gate")

    %{home: home, descriptors: descriptors}
  end

  test "passes a score above floors with no negatives", %{home: home} do
    ConfigContext.with_context([home: home], fn ->
      assert :ok =
               Gate.check(%{
                 overall_accuracy: 1.0,
                 per_domain: %{"notes" => %{accuracy: 1.0}},
                 negative_violations: [],
                 gate: %{regressions: []}
               })
    end)
  end

  test "fails below floors and on negative-route violations", %{home: home} do
    ConfigContext.with_context([home: home], fn ->
      assert {:error, failures} =
               Gate.check(%{
                 overall_accuracy: 0.5,
                 per_domain: %{"notes" => %{accuracy: 0.5}},
                 negative_violations: [%{id: "operator-negative-001"}],
                 gate: %{regressions: []}
               })

      assert Enum.any?(failures, &(&1.reason == :accuracy_below_floor))
      assert Enum.any?(failures, &(&1.reason == :domain_accuracy_below_floor))
      assert Enum.any?(failures, &(&1.reason == :negative_route_violation))
    end)
  end

  test "blocks regressions while block_on_regression is enabled", %{home: home} do
    ConfigContext.with_context([home: home], fn ->
      assert {:error, failures} =
               Gate.check(%{
                 overall_accuracy: 1.0,
                 per_domain: %{"notes" => %{accuracy: 1.0}},
                 negative_violations: [],
                 gate: %{regressions: [%{metric: :overall_accuracy, previous: 1.0, current: 0.9}]}
               })

      assert [%{reason: :regression, metric: :overall_accuracy}] = failures
    end)
  end

  test "promotion check passes a compatible descriptor and rejects a regressing candidate", %{
    home: home,
    descriptors: descriptors
  } do
    ConfigContext.with_context([home: home], fn ->
      assert :ok =
               Gate.check_promotion(
                 %{
                   app_id: :allbert,
                   action_name: "list_channels",
                   label: "List channels",
                   examples: ["list my channels"],
                   synonyms: ["channels"],
                   required_slots: []
                 },
                 descriptors: descriptors
               )

      assert {:error, failures} =
               Gate.check_promotion(
                 %{
                   app_id: :allbert,
                   action_name: "list_channels",
                   label: "List channels",
                   examples: ["list my channels"],
                   synonyms: ["channels"],
                   required_slots: [:channel]
                 },
                 descriptors: descriptors
               )

      assert Enum.any?(failures, &(&1.reason in [:regression, :domain_accuracy_below_floor]))
    end)
  end

  # ADR 0086 contract-2 context isolation proof (v1.0.3 M1, release.v103
  # `v103_pilot_app_env`): two CONCURRENT configuration contexts — different
  # homes, contradictory operator floors written through Settings Central —
  # cannot cross-contaminate: each child's Gate verdict follows only its own
  # context, and the parent (no context) still resolves the untouched
  # defaults. Substituting the pre-conversion global idiom
  # (`System.put_env("ALLBERT_HOME", …)` + `Application.delete_env`) for
  # `with_context/2` in the children makes this test RED — the recorded
  # red-first proof of why the file previously required the serial
  # app_env lane.
  test "contract-2 context isolation proof: concurrent configuration contexts cannot cross-contaminate" do
    parent = self()

    score = %{
      overall_accuracy: 0.8,
      per_domain: %{"notes" => %{accuracy: 0.9}},
      negative_violations: [],
      gate: %{regressions: []}
    }

    strict_home = owned_home("ctx-strict")
    lenient_home = owned_home("ctx-lenient")

    run_gate = fn tag, home, floor ->
      ConfigContext.with_context([home: home], fn ->
        assert {:ok, _setting} =
                 Settings.put("intent.eval.min_accuracy", floor, %{audit?: false})

        send(parent, {:ready, self()})

        receive do
          :check -> send(parent, {tag, Gate.check(score)})
        end
      end)
    end

    strict = spawn_link(fn -> run_gate.(:strict, strict_home, 0.9) end)
    lenient = spawn_link(fn -> run_gate.(:lenient, lenient_home, 0.7) end)

    # Rendezvous: both contexts exist CONCURRENTLY, with contradictory
    # floors already written, before either child reads its verdict.
    assert_receive {:ready, pid_a}, 5_000
    assert_receive {:ready, pid_b}, 5_000
    assert Enum.sort([pid_a, pid_b]) == Enum.sort([strict, lenient])
    send(strict, :check)
    send(lenient, :check)

    assert_receive {:strict, {:error, strict_failures}}, 5_000

    assert [%{reason: :accuracy_below_floor, floor: 0.9, actual: 0.8}] =
             Enum.filter(strict_failures, &(&1.reason == :accuracy_below_floor))

    assert_receive {:lenient, :ok}, 5_000

    # The parent process carries NO context: neither child's floor leaked —
    # the same score still fails against the untouched 0.85 default.
    assert {:error, parent_failures} = Gate.check(score)

    assert [%{reason: :accuracy_below_floor, floor: 0.85, actual: 0.8}] =
             Enum.filter(parent_failures, &(&1.reason == :accuracy_below_floor))
  end

  # Contract-4/M8.3 owned-home idiom: OS-pid-qualified (bare unique_integer
  # restarts each BEAM boot), pre-cleaned against pid reuse, deleted on exit.
  defp owned_home(tag) do
    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-intent-eval-gate-#{tag}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(home) end)
    home
  end
end
