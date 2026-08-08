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

    test "kernel test files are part of the closure, not just kernel sources" do
      # M7.2 splits owning tests because a test that reaches a residual fixture
      # breaks the invariant in the test dimension rather than the compile one.
      # The gate has to see that dimension or the split cannot be verified.
      kernel_tests =
        Path.wildcard(Path.expand("apps/allbert_kernel/test/**/*.exs", repository_root()))

      assert kernel_tests != []

      for path <- kernel_tests do
        relative = Path.relative_to(path, repository_root())
        assert is_list(Ledger.references(relative))
      end

      assert {:ok, findings} = Ledger.findings()
      refute Enum.any?(findings, &(&1.concern == :kernel_test))
    end

    test "a nested test stub resolves to its parent rather than a bare module" do
      # `defmodule ReadyBarrier` inside a test module is auto-aliased by Elixir,
      # so a resolver that missed it would report a module existing nowhere and
      # the closure proof would be noise instead of signal.
      references =
        Ledger.references(
          "apps/allbert_kernel/test/allbert_assist/pack/activation_guard_test.exs"
        )

      refute ReadyBarrier in references
      assert Enum.any?(references, &(Atom.to_string(&1) =~ ~r/\.ReadyBarrier$/))
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

  describe "the R2 move manifest" do
    @manifest "docs/validation/v1.4-m8-move-manifest.csv"

    test "the committed manifest matches a live regeneration byte for byte" do
      assert {:ok, rows} = Ledger.move_manifest()

      committed =
        @manifest
        |> Path.expand(repository_root())
        |> File.read!()
        |> String.split("\n", trim: true)

      [header | committed_rows] = committed
      headers = String.split(header, ",")

      regenerated =
        Enum.map(rows, fn row ->
          headers |> Enum.map(&Map.fetch!(row, &1)) |> Enum.join(",")
        end)

      assert committed_rows == regenerated,
             "the frozen move manifest has drifted; M8 must consume the exact " <>
               "bytes R2 froze. Regenerate deliberately, never to make this pass."
    end

    test "every row moves one file into the kernel under the same module name" do
      assert {:ok, rows} = Ledger.move_manifest()
      assert length(rows) == 25

      for row <- rows do
        assert row["disposition"] == "move"

        assert row["destination"] ==
                 String.replace_prefix(
                   row["source"],
                   "apps/allbert_assist/",
                   "apps/allbert_kernel/"
                 )

        # A module name is independent of its application on the BEAM, which is
        # the whole reason relocation is a file move rather than a rewrite.
        assert String.starts_with?(row["module"], "AllbertAssist.")
        assert String.length(row["source_sha256"]) == 64
      end
    end

    test "a source digest tracks its file, so a content change cannot pass as a move" do
      assert {:ok, rows} = Ledger.move_manifest()

      row = Enum.find(rows, &(&1["module"] == "AllbertAssist.Paths"))

      actual =
        row["source"]
        |> Path.expand(repository_root())
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert row["source_sha256"] == actual
    end

    test "concern-wide suites are recorded as shared rather than claimed by one module" do
      shared = Ledger.shared_tests()

      assert Map.keys(shared) == [:security_central]
      assert length(shared.security_central) == 4

      dedicated =
        Ledger.move_manifest()
        |> elem(1)
        |> Enum.map(& &1["test_source"])
        |> Enum.reject(&(&1 == ""))

      for path <- shared.security_central do
        refute path in dedicated,
               "#{path} proves the Security plane as a unit and cannot also be " <>
                 "one module's dedicated owner"
      end

      assert length(Ledger.relocating_tests()) == 16
    end

    test "every path in the manifest exists" do
      assert {:ok, rows} = Ledger.move_manifest()

      for row <- rows do
        assert File.exists?(Path.expand(row["source"], repository_root()))

        if row["test_source"] != "" do
          assert File.exists?(Path.expand(row["test_source"], repository_root()))
        end
      end

      for path <- Ledger.relocating_tests() do
        assert File.exists?(Path.expand(path, repository_root()))
      end
    end
  end

  defp repository_root, do: Path.expand("../../../../..", __DIR__)
end
