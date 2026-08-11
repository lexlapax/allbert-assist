defmodule AllbertAssist.DevGates.V14M71ClosureLedgerTest do
  use ExUnit.Case, async: true

  @moduletag :global_process_serial

  alias AllbertAssist.DevGates.V14M71ClosureLedger, as: Ledger

  @registry "apps/allbert_kernel/lib/allbert_assist/actions/registry.ex"
  @runner "apps/allbert_kernel/lib/allbert_assist/actions/runner.ex"
  @decision "apps/allbert_kernel/lib/allbert_assist/security/decision.ex"
  @status "apps/allbert_kernel/lib/allbert_assist/security/status.ex"
  @paths "apps/allbert_kernel/lib/allbert_assist/paths.ex"

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

      assert "apps/allbert_kernel/lib/allbert_assist/runtime/writer_lock.ex" in paths

      refute "apps/allbert_kernel/lib/allbert_assist/runtime/writer_lock/holder.ex" in paths
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

    test "an owning test that stays residual is named with its reason, not silently dropped" do
      residual = Ledger.residual_owned_tests()

      # The backlog can be emptied two ways: by splitting a test, or by
      # declaring it residual-owned. The second is legitimate but must stay
      # small and reasoned, or the gate becomes a list of excuses.
      assert map_size(residual) == 4

      for {path, reason} <- residual do
        assert File.exists?(Path.expand(path, repository_root())), "stale entry: #{path}"
        assert is_binary(reason) and String.length(reason) > 30
        refute path in Ledger.relocating_tests()
      end

      # Their modules still relocate; only their tests stay.
      {:ok, rows} = Ledger.move_manifest()

      for module <- ~w[
            AllbertAssist.Actions.ParamContract
            AllbertAssist.Actions.Registry
            AllbertAssist.Actions.Runner
            AllbertAssist.RegistryContext
          ] do
        row = Enum.find(rows, &(&1["module"] == module))
        assert row, "#{module} must still be a relocation target"
        assert row["test_source"] == ""
        assert row["test_sha256"] == ""
      end
    end

    test "the M7.2 split backlog only ever names residual reaches in owning tests" do
      assert {:ok, backlog} = Ledger.split_backlog()

      relocating = Ledger.relocating_tests()

      for row <- backlog do
        assert row.concern == :relocating_test
        assert row.reason == :residual_dependency
        assert row.path in relocating
      end

      # These two already close, so they can never appear. If they do, a split
      # regressed a test that was already kernel-pure.
      closed = [
        "apps/allbert_kernel/test/allbert_assist/runtime/writer_lock_test.exs",
        "apps/allbert_kernel/test/allbert_assist/runtime/safe_term_test.exs"
      ]

      for path <- closed, do: refute(Enum.any?(backlog, &(&1.path == path)))

      # The split is complete, so the backlog is empty and its rows now also
      # flow through findings/0. Both views must agree.
      assert backlog == []
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

    test "the committed manifest stays the R2 record, not a post-move regeneration" do
      # Before M8 this row compared the manifest against a live regeneration.
      # After the move that comparison is meaningless — a regeneration now reads
      # the kernel paths — so the manifest's job changes from "matches today" to
      # "records what R2 froze". Its source paths must still be the pre-move
      # ones, and `relocation_diffs/0` is what proves the bytes arrived.
      committed =
        @manifest
        |> Path.expand(repository_root())
        |> File.read!()
        |> String.split("\n", trim: true)
        |> tl()

      for row <- committed do
        [_concern, _module, source, destination | _rest] = String.split(row, ",")

        assert String.starts_with?(source, "apps/allbert_assist/"),
               "the manifest must keep its pre-move source paths as R2 evidence: #{source}"

        assert String.starts_with?(destination, "apps/allbert_kernel/")
      end

      assert {:ok, []} = Ledger.relocation_diffs()
    end

    test "every row moves one file into the kernel under the same module name" do
      assert {:ok, rows} = Ledger.move_manifest()
      assert length(rows) == 29

      module_rows = Enum.filter(rows, &(&1["disposition"] == "move"))
      shared_rows = Enum.filter(rows, &(&1["disposition"] == "move_shared_test"))

      assert length(module_rows) == 25
      # Concern-shared suites relocate too and must carry a frozen digest, or
      # four files would move at M8 with nothing to compare against.
      assert length(shared_rows) == 4
      assert Enum.all?(shared_rows, &(String.length(&1["source_sha256"]) == 64))

      for row <- module_rows do
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

    test "every relocated file still hashes to the byte R2 froze" do
      # M8's acceptance, stated as code. A relocation that changes content is
      # not a relocation, and this catches it rather than a review.
      assert {:ok, diffs} = Ledger.relocation_diffs()

      assert diffs == [],
             "relocated content changed:\n" <>
               Enum.map_join(diffs, "\n", &"  #{&1.file}")
    end

    test "an authorized post-move change is recorded with a reason, not waved through" do
      # The escape hatch must not become a rubber stamp. Every recorded delta
      # names a real manifest destination, carries a digest that matches the
      # file on disk right now, and states which milestone changed it and why.
      # A stale or invented row fails here rather than silently widening the
      # set of files the R2 freeze no longer covers.
      recorded = Ledger.recorded_post_move_changes()
      assert {:ok, rows} = Ledger.move_manifest()

      destinations =
        rows
        |> Enum.flat_map(&[&1["destination"], &1["test_destination"]])
        |> Enum.reject(&(&1 in [nil, ""]))
        |> MapSet.new()

      csv =
        "docs/validation/v1.4-post-move-changes.csv"
        |> Path.expand(repository_root())
        |> File.read!()
        |> String.split("\n", trim: true)

      assert hd(csv) == "file,post_move_sha256,milestone,reason"

      for row <- tl(csv) do
        [file, sha, milestone, reason] = String.split(row, ",", parts: 4)

        assert MapSet.member?(destinations, file),
               "#{file} is not a relocation destination in the move manifest"

        assert String.length(sha) == 64
        assert milestone != ""
        assert String.length(reason) > 20, "record why #{file} changed, not just that it did"

        actual =
          file
          |> Path.expand(repository_root())
          |> File.read!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        assert sha == actual, "the recorded delta for #{file} is stale"
        assert recorded[file] == sha
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
        assert String.starts_with?(path, "apps/allbert_kernel/")

        refute path in dedicated,
               "#{path} proves the Security plane as a unit and cannot also be " <>
                 "one module's dedicated owner"
      end

      # Sixteen owning tests, less the four recorded as residual-owned.
      assert length(Ledger.relocating_tests()) == 12
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
