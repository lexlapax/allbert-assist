defmodule AllbertAssist.DevGates.V14M71ClosureLedgerTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.V14M71ClosureLedger, as: Ledger

  @registry "apps/allbert_assist/lib/allbert_assist/actions/registry.ex"
  @runner "apps/allbert_assist/lib/allbert_assist/actions/runner.ex"
  @decision "apps/allbert_assist/lib/allbert_assist/security/decision.ex"
  @status "apps/allbert_assist/lib/allbert_assist/security/status.ex"
  @paths "apps/allbert_assist/lib/allbert_assist/paths.ex"

  describe "the frozen roster" do
    test "covers the three locked concerns and every file exists" do
      roster = Ledger.roster()
      assert length(roster) == 25

      by_concern = Enum.group_by(roster, &elem(&1, 1), &elem(&1, 0))

      assert Map.keys(by_concern) |> Enum.sort() ==
               [:capability_plane, :home_identity, :security_central]

      assert length(by_concern.home_identity) == 3
      assert length(by_concern.security_central) == 14
      assert length(by_concern.capability_plane) == 8

      for {path, _concern} <- roster do
        assert File.exists?(Path.expand(path, repository_root())), "missing roster file: #{path}"
      end
    end

    test "WriterLock.Holder is deliberately excluded as a retained startup host" do
      paths = Enum.map(Ledger.roster(), &elem(&1, 0))

      assert "apps/allbert_assist/lib/allbert_assist/runtime/writer_lock.ex" in paths

      refute "apps/allbert_assist/lib/allbert_assist/runtime/writer_lock/holder.ex" in paths
    end
  end

  describe "alias resolution" do
    # These pin the resolver itself. A resolver that reported the source token
    # instead of the module it binds would make the closure proof green while
    # the boundary was broken, so each form is asserted on a real target.

    test "a plain alias resolves to the aliased module" do
      assert AllbertAssist.Kernel.Contract.Membership in Ledger.references(@runner)
    end

    test "an `as:` alias resolves to its target, not its binding name" do
      references = Ledger.references(@decision)

      # `alias AllbertAssist.Kernel.Contract.Grants, as: CommandGrants`
      assert AllbertAssist.Kernel.Contract.Grants in references
      refute AllbertAssist.Coding.CommandGrants in references
      refute CommandGrants in references
    end

    test "a multi-alias expands to its members and not to its bare prefix" do
      references = Ledger.references(@registry)

      # `alias AllbertAssist.Actions.{Capability, SnapshotCatalog}`
      assert AllbertAssist.Actions.Capability in references
      assert AllbertAssist.Actions.SnapshotCatalog in references
      refute AllbertAssist.Actions in references
      refute Capability in references
      refute SnapshotCatalog in references
    end

    test "the seam repointings are visible in the resolved references" do
      status = Ledger.references(@status)

      assert AllbertAssist.Kernel.Contract.Settings in status
      assert AllbertAssist.Security.Redactor in status
      refute AllbertAssist.Settings.Store in status
      refute AllbertAssist.Settings.VersionContract in status
      refute AllbertAssist.Runtime.Redactor in status

      paths = Ledger.references(@paths)

      assert AllbertAssist.Kernel.Contract.HomeRoots in paths
      # The five subsystem owners were module atoms used as configuration keys,
      # never calls. They are still forbidden kernel-names-a-pack references.
      refute AllbertAssist.Settings in paths
      refute AllbertAssist.Memory in paths
      refute AllbertAssist.Artifacts in paths
      refute AllbertAssist.Confirmations in paths
      refute AllbertAssist.Execution.Audit in paths
    end
  end

  describe "closure" do
    test "no relocation target depends on the residual pack or an unadmitted library" do
      assert {:ok, findings} = Ledger.findings()

      assert findings == [],
             "M8 cannot begin with an open edge:\n" <>
               Enum.map_join(findings, "\n", fn finding ->
                 "  #{finding.path}: #{inspect(finding.module)} (#{finding.reason})"
               end)
    end

    test "the external dependencies the kernel will declare at M8 are named, not discovered" do
      assert Ledger.admitted_applications() == [:exqlite, :jason, :jido_action, :jido_signal]

      # Each admission traces to a real call or struct match, so the list cannot
      # quietly grow to launder a residual dependency as a library.
      assert Map.fetch!(Ledger.admitted_libraries(), Exqlite.Sqlite3) == :exqlite
      assert Map.fetch!(Ledger.admitted_libraries(), Jido.Signal) == :jido_signal
      assert Map.fetch!(Ledger.admitted_libraries(), Jason) == :jason
    end

    test "the ledger record is stable evidence with no line numbers" do
      assert {:ok, ledger} = Ledger.ledger()

      assert ledger["schema_version"] == 1
      assert ledger["roster_size"] == 25
      assert ledger["findings"] == []
      assert ledger["admitted_applications"] == ~w[exqlite jason jido_action jido_signal]

      assert Map.keys(ledger["concerns"]) |> Enum.sort() ==
               ~w[capability_plane home_identity security_central]
    end
  end

  defp repository_root, do: Path.expand("../../../../..", __DIR__)
end
