defmodule Mix.Tasks.Allbert.TestTaskTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.DevGates.{GateBaseline, GateOwners, PhaseRunner}
  alias Mix.Tasks.Allbert.Test, as: AllbertTestTask

  @v13_fanout_fixture Path.expand("../../fixtures/v1.3/fanout_real_model_eval.json", __DIR__)

  setup do
    original_runner = Application.get_env(:allbert_assist, :gate_command_runner)
    original_evidence_root = Application.get_env(:allbert_assist, :gate_evidence_root)
    original_changed_files = Application.get_env(:allbert_assist, :gate_changed_files)
    original_metrics_store = Application.get_env(:allbert_assist, :test_metrics_store)

    original_focused_runner =
      Application.get_env(:allbert_assist, :focused_command_runner)

    original_test_files_runner =
      Application.get_env(:allbert_assist, :test_files_command_runner)

    original_preflight_verifier =
      Application.get_env(:allbert_assist, :preflight_attestation_verifier)

    evidence_root = temp_path("evidence")
    metrics_store = Path.join(temp_path("metrics"), "runs.jsonl")
    parent = self()

    runner = fn phase ->
      send(parent, {:phase, phase.id, phase.cwd, phase.args})
      send(parent, {:phase_env, phase.id, phase.env})
      {"#{phase.id} token=secret-token\n3 tests, 0 failures\n", 0}
    end

    Application.put_env(:allbert_assist, :gate_command_runner, runner)
    Application.put_env(:allbert_assist, :gate_evidence_root, evidence_root)
    # v1.0.2 M8.1: in-process gate runs must not append to the repo-local
    # .test_metrics store; redirect recording to an owned temp store.
    Application.put_env(:allbert_assist, :test_metrics_store, metrics_store)

    Application.put_env(:allbert_assist, :preflight_attestation_verifier, fn _root,
                                                                             _digest,
                                                                             _clean? ->
      :ok
    end)

    on_exit(fn ->
      restore_app_env(:gate_command_runner, original_runner)
      restore_app_env(:gate_evidence_root, original_evidence_root)
      restore_app_env(:gate_changed_files, original_changed_files)
      restore_app_env(:test_metrics_store, original_metrics_store)
      restore_app_env(:focused_command_runner, original_focused_runner)
      restore_app_env(:test_files_command_runner, original_test_files_runner)
      restore_app_env(:preflight_attestation_verifier, original_preflight_verifier)
      File.rm_rf!(evidence_root)
      File.rm_rf!(Path.dirname(metrics_store))
      Mix.Task.reenable("allbert.test")
      Mix.Task.reenable("precommit")
    end)

    {:ok, evidence_root: evidence_root, metrics_store: metrics_store}
  end

  test "fast-local uses each owner's declared test task from its own CWD" do
    parent = self()

    Application.put_env(:allbert_assist, :test_files_command_runner, fn command ->
      send(parent, {:fast_local_command, command})
      {"Running ExUnit with seed: 41004\n1 test, 0 failures\n", 0}
    end)

    capture_io(fn -> AllbertTestTask.run(["fast-local"]) end)

    repo_root = Path.expand("../../../../..", __DIR__)

    assert_received {:fast_local_command,
                     %{
                       owner: :kernel,
                       cwd: kernel_cwd,
                       args: ["test" | kernel_paths]
                     }}

    assert kernel_cwd == Path.join(repo_root, "apps/allbert_kernel")
    assert kernel_paths != []
    assert Enum.all?(kernel_paths, &String.starts_with?(&1, "test/"))

    assert_received {:fast_local_command,
                     %{
                       owner: :core,
                       cwd: core_cwd,
                       args: ["allbert.test.raw" | core_paths]
                     }}

    assert core_cwd == Path.join(repo_root, "apps/allbert_assist")
    assert core_paths != []
    assert Enum.all?(core_paths, &String.starts_with?(&1, "test/"))
  end

  test "focused records one structured metrics row per owner", %{
    metrics_store: metrics_store
  } do
    parent = self()

    invocation = [
      "focused",
      "--",
      "apps/allbert_kernel/test/allbert_assist/pack/data_contract_test.exs",
      "apps/allbert_assist/test/allbert_assist/actions/multiply_test.exs",
      "apps/allbert_assist/test/allbert_assist/actions/resource_refs_test.exs"
    ]

    Application.put_env(:allbert_assist, :focused_command_runner, fn command ->
      send(parent, {:focused_command, command})

      seed = if command.owner == :kernel, do: 41_001, else: 41_002

      {"""
       Running ExUnit with seed: #{seed}, max_cases: 40

       ..
       Finished in 0.1 seconds (0.1s async, 0.00s sync)
       2 tests, 0 failures

       Top 1 slowest (0.05s), 50.0% of total time:

         * records metrics (50.0ms) [test/example_test.exs:1]
       """, 0}
    end)

    capture_io(fn ->
      assert :ok = AllbertTestTask.run(invocation)
    end)

    assert_received {:focused_command,
                     %{
                       id: "focused-kernel",
                       owner: :kernel,
                       executable: "mix",
                       args: [
                         "test",
                         "--slowest",
                         "25",
                         "test/allbert_assist/pack/data_contract_test.exs"
                       ]
                     } = kernel_command}

    assert_received {:focused_command,
                     %{
                       id: "focused-core",
                       owner: :core,
                       executable: "mix",
                       args: [
                         "test",
                         "--slowest",
                         "25",
                         "test/allbert_assist/actions/multiply_test.exs",
                         "test/allbert_assist/actions/resource_refs_test.exs"
                       ]
                     } = core_command}

    assert kernel_command.cwd == Path.join(repo_root(), "apps/allbert_kernel")
    assert core_command.cwd == Path.join(repo_root(), "apps/allbert_assist")

    Enum.each([kernel_command, core_command], fn command ->
      home = command.env |> Map.new() |> Map.fetch!("ALLBERT_HOME")
      refute File.exists?(home)
    end)

    records = read_metrics!(metrics_store)
    records_by_owner = Map.new(records, &{&1["owner"], &1})

    assert Enum.map(records, & &1["gate"]) == ["focused", "focused"]
    assert Enum.sort(Enum.map(records, & &1["owner"])) == ["core", "kernel"]

    assert Enum.sort(Enum.map(records, & &1["phase_or_step"])) == [
             "focused-core",
             "focused-kernel"
           ]

    assert Enum.sort(Enum.map(records, & &1["seed"])) == [41_001, 41_002]
    assert Enum.all?(records, &(&1["status"] == "passed"))
    assert Enum.all?(records, &(&1["tests"] == 2 and &1["failures"] == 0))
    assert Enum.all?(records, &(is_integer(&1["wall_ms"]) and &1["wall_ms"] >= 0))
    assert Enum.all?(records, &match?([%{"ms" => 50.0}], &1["slowest"]))
    assert Enum.all?(records, &(&1["command"] == Enum.join(invocation, " ")))
    assert Enum.all?(records, &is_binary(&1["host_class"]))
    assert Enum.all?(records, &is_boolean(&1["dirty"]))
    assert Enum.all?(records, &Regex.match?(~r/^[0-9a-f]{40}$/, &1["full_sha"]))
    assert Enum.all?(records, &is_nil(&1["lane"]))
    assert Enum.all?(records, &is_nil(&1["partition"]))
    assert Enum.all?(records, &is_nil(&1["partitions"]))
    assert records_by_owner["kernel"]["cwd"] == "apps/allbert_kernel"
    assert records_by_owner["core"]["cwd"] == "apps/allbert_assist"
  end

  test "focused records a failed owner before raising", %{metrics_store: metrics_store} do
    parent = self()

    Application.put_env(:allbert_assist, :focused_command_runner, fn command ->
      send(parent, {:failed_focused_command, command})
      {"Running ExUnit with seed: 41003, max_cases: 40\n1 test, 1 failure\n", 2}
    end)

    assert_raise Mix.Error, ~r/^focused (core|kernel) failed with status 2$/, fn ->
      capture_io(fn ->
        AllbertTestTask.run([
          "focused",
          "--",
          "apps/allbert_kernel/test/allbert_assist/pack/data_contract_test.exs",
          "apps/allbert_assist/test/allbert_assist/actions/multiply_test.exs"
        ])
      end)
    end

    assert_received {:failed_focused_command, attempted_command}
    refute_received {:failed_focused_command, _second_command}

    assert [record] = read_metrics!(metrics_store)
    assert record["gate"] == "focused"
    assert record["phase_or_step"] == "focused-#{attempted_command.owner}"
    assert record["owner"] == Atom.to_string(attempted_command.owner)
    assert record["cwd"] == Path.relative_to(attempted_command.cwd, repo_root())
    assert record["status"] == "failed"
    assert record["seed"] == 41_003
    assert record["tests"] == 1
    assert record["failures"] == 1
  end

  test "a stale preflight refuses an expensive gate before any phase starts" do
    parent = self()

    Application.put_env(:allbert_assist, :preflight_attestation_verifier, fn _root,
                                                                             _digest,
                                                                             clean? ->
      send(parent, {:preflight_refusal, clean?})
      Mix.raise("preflight attestation refused: worktree_content_digest changed")
    end)

    assert_raise Mix.Error, ~r/preflight attestation refused/, fn ->
      AllbertTestTask.run(["release.v13"])
    end

    assert_received {:preflight_refusal, true}
    refute_received {:phase, _, _, _}
  end

  test "owner contract checks kernel and composition roots, CWDs, and declared lanes" do
    owners = AllbertTestTask.owner_contract()

    assert owners.kernel == %{
             test_root: "apps/allbert_kernel/test",
             cwd: "apps/allbert_kernel",
             lanes: [
               :pure_async,
               :app_env_serial,
               :home_fs_serial,
               :global_process_serial,
               :external_runtime_serial
             ]
           }

    assert owners.composition == %{
             test_root: "apps/allbert_composition/test",
             cwd: "apps/allbert_composition",
             lanes: [
               :pure_async,
               :app_env_serial,
               :global_process_serial,
               :external_runtime_serial
             ]
           }

    assert owners.core.test_root == "apps/allbert_assist/test"
    assert owners.core.cwd == "apps/allbert_assist"
    assert :security_eval_serial in owners.core.lanes
    assert owners.web.cwd == "apps/allbert_assist_web"
    assert :liveview_serial in owners.web.lanes

    records = AllbertTestTask.inventory_records()

    assert Enum.any?(records, fn record ->
             record.owner == :kernel and
               String.starts_with?(record.path, "apps/allbert_kernel/test/")
           end)

    assert Enum.any?(records, fn record ->
             record.owner == :composition and
               String.starts_with?(record.path, "apps/allbert_composition/test/")
           end)

    assert AllbertTestTask.owner_lane_contract_issues(records) == []

    assert AllbertTestTask.owner_path_contract_issues(Path.expand("../../../../..", __DIR__)) ==
             []
  end

  test "gate owners originate in application and Pack contributions with an independent census" do
    root = repo_root()
    records = GateOwners.load!(root)

    assert length(records) == 17

    assert MapSet.new(records, & &1.owner_id) ==
             MapSet.new(
               ~w[kernel composition web core stocksage telegram email discord slack matrix whatsapp signal notes_files artifacts browser research tui]a
             )

    assert Enum.all?(records, fn owner ->
             Map.keys(owner) |> Enum.sort() ==
               ~w[aggregate_policy allowed_primary_lanes application cwd historical_metrics_aliases owner_id production_source_roots target_resolver test_roots test_support_roots]a
               |> Enum.sort()
           end)

    independent = GateOwners.independent_test_files(root)
    inventory = AllbertTestTask.inventory_records()
    inventory_by_path = Map.new(inventory, &{&1.path, &1})
    assert length(independent) == length(inventory)

    assert Enum.all?(independent, fn path ->
             GateOwners.owner_for_test_path!(records, path).owner_id ==
               Map.fetch!(inventory_by_path, path).owner
           end)

    task_source =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()

    refute task_source =~ "@owner_contract"
    refute task_source =~ "@owner_order"
    assert length(Regex.scan(~r/cwd = release_step_cwd\(step\)/, task_source)) == 43
    assert length(Regex.scan(~r/resolve_release_step_args\(step, cwd\)/, task_source)) == 44
  end

  test "pre-M7 release definitions, target multiplicity, owners, and path dispositions are exact" do
    definitions = AllbertTestTask.all_release_step_definitions()

    assert map_size(definitions) == 42
    assert :ok = GateBaseline.verify!(repo_root(), definitions)

    fixture =
      Path.join(repo_root(), "apps/allbert_assist/test/fixtures/v1.4/m7_gate_path_baseline.json")
      |> File.read!()
      |> Jason.decode!()

    assert fixture["base_git_sha"] == "7ae566f59"
    assert length(fixture["path_references"]) == 297
    assert Enum.all?(fixture["path_references"], & &1["disposition"])
  end

  test "gate-owner projection loads without code-path mutation from every owner CWD" do
    root = repo_root()
    build = Path.join([root, "_build", "test", "lib"])

    kernel_ebin = Path.join([build, "allbert_kernel", "ebin"])
    core_ebin = Path.join([build, "allbert_assist", "ebin"])

    expression = """
    root = #{inspect(root)}
    before = :code.get_path()
    records = AllbertAssist.DevGates.GateOwners.load!(root)
    source = AllbertAssist.DevGates.GateOwners.read_owned_path!(root, "apps/allbert_assist/lib/allbert_assist/security.ex")
    true = length(records) == 17
    true = String.contains?(source, "defmodule AllbertAssist.Security")
    true = before == :code.get_path()
    IO.puts("gate-owner-cwd-ok")
    """

    for cwd <-
          ~w[apps/allbert_kernel apps/allbert_assist apps/allbert_composition apps/allbert_assist_web] do
      {output, status} =
        System.cmd("elixir", ["-pa", kernel_ebin, "-pa", core_ebin, "-e", expression],
          cd: Path.join(root, cwd),
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, "#{cwd} failed:\n#{output}"
      assert output =~ "gate-owner-cwd-ok"
    end
  end

  test "independent production census owns every source file and rejects nested overlaps" do
    root = repo_root()
    applications = GateOwners.application_census!(root)
    records = GateOwners.load!(root)

    # v1.4 M13 extracted browser, research, and TUI into their own applications
    # (and their own gate owners), so core no longer answers for their roots --
    # each pack now claims its own, the same shape every other extracted pack has.
    browser = Enum.find(records, &(&1.owner_id == :browser))
    research = Enum.find(records, &(&1.owner_id == :research))
    tui = Enum.find(records, &(&1.owner_id == :tui))

    assert "apps/allbert_browser/lib" in browser.production_source_roots
    assert "apps/allbert_research/lib" in research.production_source_roots
    assert "apps/allbert_tui/lib" in tui.production_source_roots

    assert GateOwners.independent_production_files(root) != []

    without_browser = %{
      browser
      | production_source_roots:
          Enum.reject(browser.production_source_roots, &(&1 == "apps/allbert_browser/lib"))
    }

    assert_raise ArgumentError,
                 ~r/unowned production file: apps\/allbert_browser\/lib\//,
                 fn ->
                   GateOwners.validate!(
                     [without_browser | List.delete(records, browser)],
                     root,
                     applications
                   )
                 end

    [other | _] = Enum.reject(records, &(&1.owner_id == :core))
    overlapping = %{other | production_source_roots: ["apps/allbert_assist/lib/allbert_assist"]}

    assert_raise ArgumentError, ~r/overlapping production source roots/, fn ->
      GateOwners.validate!([overlapping | List.delete(records, other)], root, applications)
    end
  end

  test "gate-owner validation fails closed on missing and duplicate owners" do
    root = repo_root()
    applications = GateOwners.application_census!(root)
    records = GateOwners.load!(root)

    without_artifacts = Enum.reject(records, &(&1.owner_id == :artifacts))

    assert_raise ArgumentError, ~r/unowned test file: apps\/allbert_artifacts\/test\//, fn ->
      GateOwners.validate!(without_artifacts, root, applications)
    end

    [first | _rest] = records

    assert_raise ArgumentError, ~r/owner id artifacts is contributed 2 times/, fn ->
      GateOwners.validate!([first | records], root, applications)
    end
  end

  test "historical test targets follow a logical test into a new owner root" do
    root = temp_path("gate-owner-move")
    old_cwd = Path.join(root, "apps/old")
    moved = Path.join(root, "apps/new/test/example/moved_test.exs")
    File.mkdir_p!(Path.dirname(moved))
    File.write!(moved, "defmodule Example.MovedTest do\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)

    owner = %{
      owner_id: :new,
      application: :new,
      cwd: "apps/new",
      production_source_roots: ["apps/new/lib"],
      test_roots: ["apps/new/test"],
      test_support_roots: [],
      allowed_primary_lanes: [:pure_async],
      aggregate_policy: :mix_test,
      target_resolver: {AllbertAssist.DevGates.GateTargetResolver, :resolve},
      historical_metrics_aliases: ["old", "new"]
    }

    assert %{
             owner_id: :new,
             path: "apps/new/test/example/moved_test.exs"
           } =
             GateOwners.resolve_test_target!(
               [owner],
               "test/example/moved_test.exs",
               old_cwd,
               root
             )

    File.mkdir_p!(Path.join(root, "apps/second/test/example"))
    File.write!(Path.join(root, "apps/second/test/example/moved_test.exs"), "duplicate\n")
    second = %{owner | owner_id: :second, cwd: "apps/second", test_roots: ["apps/second/test"]}

    assert_raise ArgumentError, ~r/duplicate gate test target/, fn ->
      GateOwners.resolve_test_target!(
        [owner, second],
        "test/example/moved_test.exs",
        old_cwd,
        root
      )
    end

    assert_raise ArgumentError, ~r/unresolved gate test target/, fn ->
      GateOwners.resolve_test_target!([owner], "test/example/missing_test.exs", old_cwd, root)
    end
  end

  test "serial-owner rejects unknown owners and lanes outside the checked owner contract" do
    assert_raise Mix.Error, "unknown serial owner stranger", fn ->
      AllbertTestTask.run([
        "serial-owner",
        "--owner",
        "stranger",
        "--lane",
        "app_env_serial"
      ])
    end

    assert_raise Mix.Error,
                 "lane db_serial is not declared for serial owner kernel; expected one of pure_async, app_env_serial, home_fs_serial, global_process_serial, external_runtime_serial",
                 fn ->
                   AllbertTestTask.run([
                     "serial-owner",
                     "--owner",
                     "kernel",
                     "--lane",
                     "db_serial"
                   ])
                 end

    assert_raise Mix.Error,
                 "external_runtime_serial must run as a single-VM serial or external smoke lane",
                 fn ->
                   AllbertTestTask.run([
                     "serial-owner",
                     "--owner",
                     "composition",
                     "--lane",
                     "external_runtime_serial",
                     "--partitions",
                     "2"
                   ])
                 end
  end

  test "serial-owner runs checked core lanes and serial-core retains its metrics identity", %{
    metrics_store: metrics_store
  } do
    original_runner = Application.get_env(:allbert_assist, :serial_owner_command_runner)
    parent = self()

    Application.put_env(:allbert_assist, :serial_owner_command_runner, fn command ->
      send(parent, {:serial_command, command})

      case command.id do
        "prepare_database" ->
          {"database ready\n", 0}

        "run_tests" ->
          {"Running ExUnit with seed: 1234, max_cases: 1\n2 tests, 0 failures\n", 0}
      end
    end)

    on_exit(fn -> restore_app_env(:serial_owner_command_runner, original_runner) end)

    capture_io(fn ->
      assert :ok =
               AllbertTestTask.run([
                 "serial-owner",
                 "--owner",
                 "core",
                 "--lane",
                 "app_env_serial",
                 "--partitions",
                 "1"
               ])
    end)

    assert_received {:serial_command,
                     %{
                       id: "prepare_database",
                       cwd: cwd,
                       executable: "mix",
                       args: ["ecto.migrate.allbert", "--quiet"]
                     }}

    assert cwd == Path.join(Path.expand("../../../../..", __DIR__), "apps/allbert_assist")

    assert_received {:serial_command,
                     %{
                       id: "run_tests",
                       cwd: ^cwd,
                       executable: "mix",
                       args: [
                         "allbert.test.raw",
                         "--only",
                         "app_env_serial",
                         "--max-cases",
                         "1",
                         "--slowest",
                         "25"
                         | test_paths
                       ]
                     }}

    assert test_paths != []

    capture_io(fn ->
      assert :ok =
               AllbertTestTask.run([
                 "serial-core",
                 "--lane",
                 "app_env_serial",
                 "--partitions",
                 "1"
               ])
    end)

    records =
      metrics_store
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(records, & &1["gate"]) == ["serial-owner", "serial-core"]
    assert Enum.map(records, & &1["owner"]) == ["core", "core"]
    assert Enum.map(records, & &1["lane"]) == ["app_env_serial", "app_env_serial"]
    assert Enum.all?(records, &(&1["partition"] == 1 and &1["partitions"] == 1))
  end

  test "composition serial-owner migrates the owned database before running from composition CWD" do
    original_runner = Application.get_env(:allbert_assist, :serial_owner_command_runner)
    parent = self()

    Application.put_env(:allbert_assist, :serial_owner_command_runner, fn command ->
      send(parent, {:composition_serial_command, command})
      {"0 tests, 0 failures\n", 0}
    end)

    on_exit(fn -> restore_app_env(:serial_owner_command_runner, original_runner) end)

    capture_io(fn ->
      assert :ok =
               AllbertTestTask.run([
                 "serial-owner",
                 "--owner",
                 "composition",
                 "--lane",
                 "global_process_serial",
                 "--partitions",
                 "1"
               ])
    end)

    repo_root = Path.expand("../../../../..", __DIR__)

    assert_received {:composition_serial_command,
                     %{
                       id: "prepare_database",
                       cwd: core_cwd,
                       args: ["ecto.migrate.allbert", "--quiet"],
                       env: prepare_env
                     }}

    assert core_cwd == Path.join(repo_root, "apps/allbert_assist")
    assert {"MIX_BUILD_PATH", Path.join([repo_root, "_build", "test"])} in prepare_env

    assert_received {:composition_serial_command,
                     %{
                       id: "run_tests",
                       cwd: composition_cwd,
                       env: test_env,
                       args: test_args
                     }}

    assert composition_cwd == Path.join(repo_root, "apps/allbert_composition")
    assert {"MIX_BUILD_PATH", Path.join([repo_root, "_build", "test"])} in test_env

    assert [
             "allbert.test.raw",
             "--only",
             "global_process_serial",
             "--max-cases",
             "1",
             "--slowest",
             "25"
             | composition_test_paths
           ] = test_args

    assert "test/allbert_assist/pack/application_boundary_test.exs" in composition_test_paths
  end

  test "kernel serial-owner runs from kernel CWD without residual database preparation" do
    original_runner = Application.get_env(:allbert_assist, :serial_owner_command_runner)
    parent = self()

    Application.put_env(:allbert_assist, :serial_owner_command_runner, fn command ->
      send(parent, {:kernel_serial_command, command})
      {"0 tests, 0 failures\n", 0}
    end)

    on_exit(fn -> restore_app_env(:serial_owner_command_runner, original_runner) end)

    capture_io(fn ->
      assert :ok =
               AllbertTestTask.run([
                 "serial-owner",
                 "--owner",
                 "kernel",
                 "--lane",
                 "pure_async",
                 "--partitions",
                 "1"
               ])
    end)

    refute_received {:kernel_serial_command, %{id: "prepare_database"}}

    assert_received {:kernel_serial_command,
                     %{
                       id: "run_tests",
                       cwd: kernel_cwd,
                       args: [
                         "test",
                         "--only",
                         "pure_async",
                         "--max-cases",
                         "1",
                         "--slowest",
                         "25"
                         | test_paths
                       ]
                     }}

    assert kernel_cwd == Path.join(Path.expand("../../../../..", __DIR__), "apps/allbert_kernel")
    assert test_paths != []
    assert Enum.all?(test_paths, &String.starts_with?(&1, "test/"))
  end

  test "release-assembly dispatches the clean guarded wrapper and records its checkpoint", %{
    metrics_store: metrics_store
  } do
    original_runner = Application.get_env(:allbert_assist, :release_assembly_command_runner)

    original_temp_root_factory =
      Application.get_env(:allbert_assist, :release_assembly_temp_root_factory)

    original_release_root =
      Application.get_env(:allbert_assist, :release_assembly_release_root)

    parent = self()
    sha = String.duplicate("a", 64)
    temp_root = temp_path("release-assembly-task")
    release_root = Path.join(temp_root, "release")
    stale_path = Path.join([release_root, "lib", "allbert_assist-1.2.6", "stale.beam"])

    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale release byte")

    verifier_line =
      "ALLBERT_RELEASE_ASSEMBLY_V1=" <>
        Jason.encode!(%{
          "schema_version" => 1,
          "status" => "PASS",
          "checkpoint" => "v14-m1a1",
          "rel_sha256" => sha,
          "app_sha256" => %{
            "allbert_kernel" => sha,
            "allbert_assist" => sha
          },
          "pack_projection_sha256" => sha
        }) <>
        "\n"

    Application.put_env(:allbert_assist, :preflight_attestation_verifier, fn _root,
                                                                             _digest,
                                                                             clean? ->
      send(parent, {:release_assembly_preflight, clean?})
      :ok
    end)

    Application.put_env(:allbert_assist, :release_assembly_command_runner, fn command ->
      send(parent, {:release_assembly_command, command})

      case command.id do
        "build_release" ->
          refute File.exists?(stale_path)
          File.mkdir_p!(Path.join(release_root, "bin"))
          File.write!(Path.join([release_root, "bin", "allbert"]), "packaged executable")
          File.chmod!(Path.join([release_root, "bin", "allbert"]), 0o755)
          {"release built\n", 0}

        "verify_projection" ->
          {verifier_line, 0}
      end
    end)

    Application.put_env(:allbert_assist, :release_assembly_temp_root_factory, fn ->
      File.mkdir_p!(temp_root)
      temp_root
    end)

    Application.put_env(:allbert_assist, :release_assembly_release_root, release_root)

    on_exit(fn ->
      restore_app_env(:release_assembly_command_runner, original_runner)
      restore_app_env(:release_assembly_temp_root_factory, original_temp_root_factory)
      restore_app_env(:release_assembly_release_root, original_release_root)
      File.rm_rf!(temp_root)
    end)

    output =
      capture_io(fn ->
        assert %{status: "passed", checkpoint: "v14-m1a1"} =
                 AllbertTestTask.run([
                   "release-assembly",
                   "--checkpoint",
                   "v14-m1a1"
                 ])
      end)

    assert output =~ "release-assembly v14-m1a1 PASS"
    assert_received {:release_assembly_preflight, true}

    assert_received {:release_assembly_command,
                     %{
                       id: "build_release",
                       env: build_env,
                       args: ["release", "allbert", "--overwrite"]
                     }}

    temp_root = Map.new(build_env)["ALLBERT_RELEASE_ASSEMBLY_ROOT"]
    refute File.exists?(temp_root)
    assert Map.new(build_env)["ALLBERT_RELEASE_ROOT"] == release_root

    assert_received {:release_assembly_command,
                     %{
                       id: "verify_projection",
                       executable: verifier_executable,
                       args: ["eval", _verifier_eval]
                     }}

    assert verifier_executable == Path.join(release_root, "bin/allbert")

    assert [record] =
             metrics_store
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)

    assert record["gate"] == "release-assembly"
    assert record["checkpoint"] == "v14-m1a1"
    assert record["command"] == "release-assembly --checkpoint v14-m1a1"
  end

  test "release runs explicit phases and does not delegate to precommit", %{
    evidence_root: root,
    metrics_store: metrics_store
  } do
    output =
      capture_io(fn ->
        assert %{status: "passed"} = AllbertTestTask.run(["release"])
      end)

    phases = drain_phases()
    phase_ids = Enum.map(phases, fn {id, _cwd, _args} -> id end)

    assert {"hex_audit", _cwd, ["allbert.hex_audit"]} = List.first(phases)

    assert phase_ids == [
             "hex_audit",
             "static_compile",
             "deps_unused",
             "format",
             "credo",
             "high_coverage_fast_local",
             "core_external_runtime_serial",
             "core_security_eval_serial",
             "web_tests",
             "kernel_tests",
             "composition_tests",
             "stocksage_tests",
             "channel_plugin_tests",
             "dialyzer"
           ]

    assert {"channel_plugin_tests", _cwd, plugin_test_args} =
             Enum.find(phases, fn {id, _cwd, _args} -> id == "channel_plugin_tests" end)

    assert "../../apps/allbert_notes_files/test" in plugin_test_args
    assert "../../apps/allbert_artifacts/test" in plugin_test_args
    assert "../../apps/allbert_browser/test" in plugin_test_args
    assert "../../apps/allbert_research/test" in plugin_test_args

    refute Enum.any?(phases, fn {_id, _cwd, args} -> args == ["precommit"] end)
    assert output =~ "release static_compile started"
    assert output =~ "release dialyzer finished"

    [evidence_path] = Path.wildcard(Path.join(root, "release-*.json"))
    evidence = Jason.decode!(File.read!(evidence_path))
    assert evidence["gate"] == "release"
    assert evidence["status"] == "passed"
    assert evidence["phases"] |> List.last() |> Map.fetch!("id") == "dialyzer"
    refute File.read!(evidence_path) =~ "secret-token"

    phase_logs = Enum.map(evidence["phases"], &Map.fetch!(&1, "redacted_output_log_path"))
    assert length(phase_logs) == 14
    assert Enum.all?(phase_logs, &File.exists?/1)
    refute Enum.any?(phase_logs, &(File.read!(&1) =~ "secret-token"))

    # v1.0.2 M8.1: the phase runner emits one metrics record per phase.
    records =
      metrics_store
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(records) == 14
    assert Enum.all?(records, &(&1["gate"] == "release"))
    assert Enum.all?(records, &(&1["status"] == "passed"))
    assert Enum.map(records, & &1["phase_or_step"]) |> List.last() == "dialyzer"
    assert Enum.all?(records, &(&1["tests"] == 3 and &1["failures"] == 0))
    assert Enum.all?(records, &is_integer(&1["wall_ms"]))
  end

  test "release gates clear inherited roots and confine defaults to their owned Home" do
    inherited =
      ~w[
        ALLBERT_SETTINGS_ROOT
        ALLBERT_MEMORY_ROOT
        ALLBERT_ARTIFACTS_ROOT
        ALLBERT_PLUGINS_ROOT
        ALLBERT_VAULT_BACKEND
        XDG_CONFIG_HOME
        XDG_DATA_HOME
        XDG_STATE_HOME
        XDG_CACHE_HOME
        XDG_RUNTIME_DIR
      ]

    originals = Map.new(inherited, &{&1, System.get_env(&1)})
    Enum.each(inherited, &System.put_env(&1, "/hostile/outside-gate"))

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    capture_io(fn ->
      assert %{status: "passed"} = AllbertTestTask.run(["release"])
    end)

    [{"hex_audit", env} | _rest] = drain_phase_envs()
    env = Map.new(env)
    home = Map.fetch!(env, "ALLBERT_HOME")

    on_exit(fn -> File.rm_rf!(Path.dirname(home)) end)

    assert env["ALLBERT_HOME_DIR"] == home
    assert env["ALLBERT_SETTINGS_ROOT"] == nil
    assert env["ALLBERT_MEMORY_ROOT"] == nil
    assert env["ALLBERT_ARTIFACTS_ROOT"] == nil
    assert env["DATABASE_PATH"] == Path.join([home, "db", "allbert_test.db"])
    assert env["ALLBERT_PLUGINS_ROOT"] == nil
    assert env["ALLBERT_VAULT_BACKEND"] == nil
    assert env["XDG_CONFIG_HOME"] == Path.join([home, "xdg", "config"])
    assert env["XDG_DATA_HOME"] == Path.join([home, "xdg", "data"])
    assert env["XDG_STATE_HOME"] == Path.join([home, "xdg", "state"])
    assert env["XDG_CACHE_HOME"] == Path.join([home, "xdg", "cache"])
    assert env["XDG_RUNTIME_DIR"] == Path.join([home, "xdg", "runtime"])
  end

  test "test-run metrics substrate wires every M8.1 completion point" do
    task_source =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()

    phase_runner_source =
      Path.expand("../../../lib/allbert_assist/dev_gates/phase_runner.ex", __DIR__)
      |> File.read!()

    # (a) serial lane partitions record one run each and carry --slowest 10.
    assert task_source =~ ~s(defp record_serial_partition_metrics)
    assert task_source =~ ~s("--slowest")

    # (b) the phase runner records one run per phase with the gate name.
    assert phase_runner_source =~ ~s(TestMetrics.record)
    assert phase_runner_source =~ ~s(phase_or_step: phase.id)

    # (c) release.v1/v101/v102/v103/v104/v105 step runners record one run per step.
    assert task_source =~ ~s(gate: "release.v1",)
    assert task_source =~ ~s(gate: "release.v101",)
    assert task_source =~ ~s(gate: "release.v102",)
    assert task_source =~ ~s(gate: "release.v103",)
    assert task_source =~ ~s(gate: "release.v104",)
    assert task_source =~ ~s(gate: "release.v105",)
    assert task_source =~ ~s(gate: "release.v121",)
    assert task_source =~ ~s(gate: "release.v13",)

    # metrics subcommand + usage surface (M8.10: run/1 captures the
    # invocation for provenance and dispatches through do_run/1).
    assert task_source =~ ~s{defp do_run(["metrics" | rest]), do: metrics(rest)}
    assert task_source =~ "mix allbert.test metrics [--ingest-campaign DIR]"

    # (d) M8.10 provenance threading: gate call sites carry the captured
    # invocation, and bench-decide is a first-class runner.
    assert task_source =~ ":persistent_term.put({__MODULE__, :invocation}"
    assert task_source =~ ~s{command: gate_command(),}
    assert phase_runner_source =~ ~s{command: Keyword.get(opts, :command),}
    assert task_source =~ ~s{defp do_run(["bench-decide"]), do: bench_decide()}
    assert task_source =~ "mix allbert.test bench-decide"
  end

  test "prepush runs high coverage fast-local with requested partitions" do
    capture_io(fn ->
      assert %{status: "passed"} = AllbertTestTask.run(["prepush", "--partitions", "3"])
    end)

    assert {"high_coverage_fast_local", _cwd,
            [
              "allbert.test",
              "fast-local",
              "--core-lanes",
              "--stocksage-lanes",
              "--web-lanes",
              "--partitions",
              "3"
            ]} = drain_phases() |> List.last()
  end

  test "commit gate is explicitly non-release evidence for clean trees" do
    put_changed_files([])

    output =
      capture_io(fn ->
        assert :ok = AllbertTestTask.run(["commit"])
      end)

    phase_ids = drain_phases() |> Enum.map(fn {id, _cwd, _args} -> id end)
    assert phase_ids == ["hex_audit", "static_compile", "format", "credo"]
    assert output =~ "commit gate is not release evidence"
    assert output =~ "before sharing: mix allbert.test prepush"
    assert output =~ "before release handoff: mix allbert.test release"
  end

  test "commit gate docs-only branch is deterministic" do
    put_changed_files(["docs/plans/archives/v0.49-plan.md", "CHANGELOG.md"])

    output =
      capture_io(fn ->
        assert :ok = AllbertTestTask.run(["commit"])
      end)

    assert drain_phases() == []
    assert output =~ "==> commit gate docs-only"
    assert output =~ "==> docs"
  end

  test "v1.3 fan-out benchmark is an opt-in gate with a required nonblank profile" do
    error =
      assert_raise Mix.Error, fn ->
        AllbertTestTask.run(["bench-v13-fanout", "--profile", " "])
      end

    assert error.message == "--profile must not be blank"
  end

  test "v1.3.1 head qualification rejects non-frozen evidence parameters before Home allocation" do
    gate_glob = Path.join([System.tmp_dir!(), "allbert_test_gates", "qualify-head", "*"])
    before_roots = MapSet.new(Path.wildcard(gate_glob))

    assert_raise Mix.Error, "--model is required", fn ->
      AllbertTestTask.run(["qualify-head", "--profile", "direct_answer_local"])
    end

    assert_raise Mix.Error, "--trials must be 5 for the frozen v1.3.1 qualification bar", fn ->
      AllbertTestTask.run([
        "qualify-head",
        "--model",
        "qwen2.5:7b",
        "--trials",
        "4"
      ])
    end

    assert_raise Mix.Error,
                 "--timeout-ms must be 60000 for the frozen v1.3.1 qualification bar",
                 fn ->
                   AllbertTestTask.run([
                     "qualify-head",
                     "--model",
                     "qwen2.5:7b",
                     "--timeout-ms",
                     "59000"
                   ])
                 end

    assert MapSet.new(Path.wildcard(gate_glob)) == before_roots
  end

  test "v1.3 mixed-Mistral benchmark rejects a non-default Worker before Home allocation" do
    gate_glob = Path.join([System.tmp_dir!(), "allbert_test_gates", "bench-v13-fanout", "*"])
    before_roots = MapSet.new(Path.wildcard(gate_glob))

    error =
      assert_raise Mix.Error, fn ->
        AllbertTestTask.run([
          "bench-v13-fanout",
          "--profile",
          "local",
          "--mixed-mistral"
        ])
      end

    assert error.message == "--mixed-mistral requires --profile direct_answer_local"
    assert MapSet.new(Path.wildcard(gate_glob)) == before_roots
  end

  test "v1.3 fan-out benchmark preflights a missing manager fixture" do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v13-fanout-fixtures-#{System.unique_integer([:positive])}"
      )

    missing = Path.join(root, "fanout.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    error =
      assert_raise Mix.Error, fn ->
        AllbertTestTask.run(["bench-v13-fanout", "--fixture", missing])
      end

    assert error.message == "fan-out fixture does not exist: #{missing}"
  end

  test "v1.3 fan-out benchmark validates fixture schema and digest before allocating a Home" do
    root = temp_path("v13-fanout-preflight")
    invalid_manager = Path.join(root, "invalid-manager.json")
    changed_manager = Path.join(root, "changed-manager.json")
    File.mkdir_p!(root)
    File.write!(invalid_manager, "{}")

    manager = @v13_fanout_fixture |> File.read!() |> Jason.decode!()

    changed_manager_fixture =
      update_in(
        manager,
        ["composition_cases", Access.at(0), "snapshot", "children", Access.at(0), "detail"],
        &(&1 <> " ")
      )

    File.write!(changed_manager, Jason.encode!(changed_manager_fixture))

    on_exit(fn -> File.rm_rf!(root) end)

    gate_glob = Path.join([System.tmp_dir!(), "allbert_test_gates", "bench-v13-fanout", "*"])
    before_roots = MapSet.new(Path.wildcard(gate_glob))

    assert_raise RuntimeError, "invalid v1.3 fan-out fixture", fn ->
      AllbertTestTask.run(["bench-v13-fanout", "--fixture", invalid_manager])
    end

    assert_raise RuntimeError, "invalid v1.3 fan-out fixture digest", fn ->
      AllbertTestTask.run(["bench-v13-fanout", "--fixture", changed_manager])
    end

    assert MapSet.new(Path.wildcard(gate_glob)) == before_roots
  end

  test "commit gate mixed changes still run focused commit phases" do
    put_changed_files(["docs/plans/archives/v0.49-plan.md", "apps/allbert_assist/lib/example.ex"])

    output =
      capture_io(fn ->
        assert :ok = AllbertTestTask.run(["commit"])
      end)

    phase_ids = drain_phases() |> Enum.map(fn {id, _cwd, _args} -> id end)
    assert phase_ids == ["hex_audit", "static_compile", "format", "credo"]
    assert output =~ "commit gate is not release evidence"
  end

  test "usage lists the latest release lanes" do
    error = assert_raise Mix.Error, fn -> AllbertTestTask.run(["unknown"]) end

    assert error.message =~
             "mix allbert.test serial-owner --owner OWNER --lane LANE [--partitions N]"

    assert error.message =~ "mix allbert.test release-assembly --checkpoint CHECKPOINT"
    assert error.message =~ "mix allbert.test release.v050"
    assert error.message =~ "mix allbert.test release.v050b"
    assert error.message =~ "mix allbert.test release.v051"
    assert error.message =~ "mix allbert.test release.v052"
    assert error.message =~ "mix allbert.test release.v053"
    assert error.message =~ "mix allbert.test release.v054"
    assert error.message =~ "mix allbert.test release.v055"
    assert error.message =~ "mix allbert.test release.v0551"
    assert error.message =~ "mix allbert.test release.v056"
    assert error.message =~ "mix allbert.test release.v057"
    assert error.message =~ "mix allbert.test release.v058"
    assert error.message =~ "mix allbert.test release.v059"
    assert error.message =~ "mix allbert.test release.v060"
    assert error.message =~ "mix allbert.test release.v060b"
    assert error.message =~ "mix allbert.test release.v061"
    assert error.message =~ "mix allbert.test release.v061b"
    assert error.message =~ "mix allbert.test release.v062"
    assert error.message =~ "mix allbert.test release.v063"
    assert error.message =~ "mix allbert.test release.v064"
    assert error.message =~ "mix allbert.test release.v065"
    assert error.message =~ "mix allbert.test release.v066"
    assert error.message =~ "mix allbert.test release.v121"
    assert error.message =~ "mix allbert.test release.v13"
    assert error.message =~ "mix allbert.test release.v131"
    assert error.message =~ "mix allbert.test release.v132"

    assert error.message =~
             "mix allbert.test bench-v13-fanout [--profile NAME] [--mixed-mistral] " <>
               "[--fixture PATH] [--output PATH] [--control-output PATH]"

    assert error.message =~
             "mix allbert.test qualify-head --profile NAME --model MODEL --trials 5 " <>
               "--timeout-ms 60000 [--output PATH]"

    assert error.message =~ "mix allbert.test release.structure v121 [--output PATH]"
    assert error.message =~ "mix allbert.test release.structure v13 [--output PATH]"
    assert error.message =~ "mix allbert.test release.structure v131 [--output PATH]"
    assert error.message =~ "mix allbert.test release.structure v132 [--output PATH]"
    assert error.message =~ "mix allbert.test external-smoke -- telegram"
    assert error.message =~ "mix allbert.test external-smoke -- email"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_telegram"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_email"
    assert error.message =~ "mix allbert.test external-smoke -- matrix"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_matrix"
    assert error.message =~ "mix allbert.test external-smoke -- whatsapp"
    assert error.message =~ "mix allbert.test external-smoke -- signal"
    assert error.message =~ "mix allbert.test external-smoke -- discord"
    assert error.message =~ "mix allbert.test external-smoke -- slack"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_discord"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_slack"
  end

  test "release.v059 includes CLI resume identity regression coverage" do
    source =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()

    assert source =~ ~s(id: "cli_resume_identity")
    assert source =~ ~s(args: ["test", "test/mix/tasks/allbert_conversations_test.exs"])
  end

  test "release.v060 embeds dialyzer after credo (walking-skeleton step retired at v0.61 M10.5)" do
    release_v060_steps =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()
      |> section_between("@release_v060_steps [", "  defp release_v060 do")

    assert release_v060_steps =~ ~s(id: "credo_strict")
    assert release_v060_steps =~ ~s(id: "dialyzer")
    assert release_v060_steps =~ ~s(args: ["dialyzer"])

    # v0.61 M10.5 retired the /preview walking skeleton and dropped its lane
    # step from release.v060; this test was never reconciled (v0.61b M0.2).
    refute release_v060_steps =~ ~s(id: "walking_skeleton_smoke")

    assert string_position!(release_v060_steps, ~s(id: "credo_strict")) <
             string_position!(release_v060_steps, ~s(id: "dialyzer"))
  end

  test "release.v064 embeds trusted install, first-run repair, eval, and web repair proofs" do
    release_v064_steps =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()
      |> section_between("@release_v064_steps [", "  defp release_v064 do")

    assert release_v064_steps =~ ~s(id: "v064_trusted_install_restore")
    assert release_v064_steps =~ "test/allbert_assist/install_path_test.exs"
    assert release_v064_steps =~ "test/allbert_assist/database_test.exs"
    assert release_v064_steps =~ "test/allbert_assist/database_backup_test.exs"

    assert release_v064_steps =~ ~s(id: "v064_model_and_first_run_repair")
    assert release_v064_steps =~ "test/allbert_assist/first_model/first_model_test.exs"
    assert release_v064_steps =~ "test/allbert_assist/cli/tui_test.exs"

    assert release_v064_steps =~ ~s(id: "v064_security_sweep")
    assert release_v064_steps =~ "test/security/v064_sweep_eval_test.exs"
    assert release_v064_steps =~ "test/allbert_assist/agents/intent_agent_test.exs"

    assert release_v064_steps =~ ~s(id: "v064_web_model_repair")

    # v1.0.2 M4: the workspace LiveView monolith split into topic files; the
    # v0.64 web-repair step runs the repair-panel test in its new home.
    # M8.11b: full file, never `file:LINE` — a stale line pin excludes every
    # test and false-greens the step.
    assert release_v064_steps =~
             "apps/allbert_assist_web/test/allbert_assist_web/live/workspace/workspace_onboarding_test.exs"
  end

  # v1.0.2 M8.11b: release.v102 PASSED a step whose stale `file:LINE` pin
  # (intent_agent_test.exs:62 after the test moved to :83) excluded every
  # test — ExUnit printed "All tests have been excluded." then
  # "0 tests, 0 failures (33 excluded)" and exited 0. The repair is
  # two-sided: no release step may pin a test line, and a zero-executed-test
  # ExUnit run fails the step even when the command exits 0.
  describe "release step false-green repair (M8.11b)" do
    @zero_test_fixture """
    Running ExUnit with seed: 78230, max_cases: 40
    Excluding tags: [:test]
    Including tags: [location: {"test/allbert_assist/agents/intent_agent_test.exs", 62}]

    All tests have been excluded.

    Finished in 0.5 seconds (0.00s async, 0.5s sync)
    0 tests, 0 failures (33 excluded)
    """

    test "zero executed ExUnit tests fail a release step despite exit 0" do
      stderr =
        capture_io(:stderr, fn ->
          assert AllbertTestTask.release_step_status(
                   "release.v102",
                   "v102_residue_intent_agent",
                   0,
                   @zero_test_fixture
                 ) == "failed"
        end)

      assert stderr =~ "release.v102 v102_residue_intent_agent"
      assert stderr =~ "ExUnit executed zero tests"
    end

    test "executed tests with exit 0 pass; nonzero exit always fails" do
      passing = "Running ExUnit with seed: 1, max_cases: 40\n33 tests, 0 failures\n"
      assert AllbertTestTask.release_step_status("release.v102", "step", 0, passing) == "passed"
      assert AllbertTestTask.release_step_status("release.v102", "step", 2, passing) == "failed"
    end

    test "multi-run steps sum their totals lines before the zero-test check" do
      # e.g. the residue batch-matrix step runs `mix test` twice in one sh -c.
      output = "0 tests, 0 failures (4 excluded)\n5 tests, 0 failures\n"
      assert AllbertTestTask.release_step_status("release.v102", "step", 0, output) == "passed"
    end

    test "steps that never run ExUnit are judged by exit status alone" do
      output = "Checking 412 source files ...\nAnalysis took 3.4 seconds.\n"

      assert AllbertTestTask.release_step_status("release.v1", "credo_strict", 0, output) ==
               "passed"

      assert AllbertTestTask.release_step_status("release.v1", "credo_strict", 1, output) ==
               "failed"
    end

    test "no release step pins a test line (file:LINE selectors are banned)" do
      task_source =
        Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
        |> File.read!()

      refute Regex.match?(~r/_test\.exs:\d/, task_source)
    end

    test "all point-release step runners route status through the zero-test guard" do
      task_source =
        Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
        |> File.read!()

      for gate <- [
            "release.v1",
            "release.v101",
            "release.v102",
            "release.v103",
            "release.v104",
            "release.v105",
            "release.v121",
            "release.v13",
            "release.v14"
          ] do
        assert task_source =~ ~s{release_step_status("#{gate}", step.id, exit_status, output)}
      end
    end

    test "release.v103 is exposed and its focused step targets all exist" do
      task_source =
        Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
        |> File.read!()

      # command exposed and dispatched
      assert task_source =~ ~s{defp do_run(["release.v103"]), do: release_v103()}
      assert task_source =~ ~s(mix allbert.test release.v103)

      # every focused test-file step points at a file that exists on disk, so a
      # zero-executed-test false-green cannot come from a missing/renamed target
      # (the M8.11b guard catches over-excluded pins; this catches missing files)
      app_root = Path.expand("../../..", __DIR__)
      web_root = Path.expand("../../../../allbert_assist_web", __DIR__)

      core_targets = [
        "test/allbert_assist/objectives/objective_test.exs",
        "test/allbert_assist/intent/eval/gate_test.exs",
        "test/allbert_assist/actions/app_actions_test.exs",
        "../../apps/allbert_browser/test/allbert_browser/actions_test.exs",
        "test/allbert_assist/actions/channels/list_channels_context_test.exs"
      ]

      for rel <- core_targets do
        assert File.exists?(Path.join(app_root, rel)),
               "release.v103 focused step target missing: #{rel}"

        assert task_source =~ rel
      end

      web_target = "test/allbert_assist_web/v103/sidebar_ownership_test.exs"

      assert File.exists?(Path.join(web_root, web_target)),
             "release.v103 focused step target missing: #{web_target}"

      assert task_source =~ web_target
    end

    test "release.v104 is exposed and its focused step targets all exist" do
      task_source =
        Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
        |> File.read!()

      assert task_source =~ ~s{defp do_run(["release.v104"]), do: release_v104()}
      assert task_source =~ ~s(mix allbert.test release.v104)

      app_root = Path.expand("../../..", __DIR__)
      web_root = Path.expand("../../../../allbert_assist_web", __DIR__)

      core_targets = [
        "test/allbert_assist/install_path_test.exs",
        "../../apps/allbert_browser/test/allbert_browser/playwright_driver_test.exs",
        "../../apps/allbert_browser/test/allbert_browser/actions_test.exs",
        "test/allbert_assist/actions/channels/list_channels_context_test.exs"
      ]

      web_targets = [
        "test/allbert_assist_web/version_consistency_test.exs",
        "test/allbert_assist_web/v103/sidebar_ownership_test.exs"
      ]

      for rel <- core_targets do
        assert File.exists?(Path.join(app_root, rel)),
               "release.v104 focused step target missing: #{rel}"

        assert task_source =~ rel
      end

      for rel <- web_targets do
        assert File.exists?(Path.join(web_root, rel)),
               "release.v104 focused step target missing: #{rel}"

        assert task_source =~ rel
      end
    end

    test "release.v105 carries v1.0.4 plus every v1.0.5 RC remediation contract" do
      task_source =
        Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
        |> File.read!()

      assert task_source =~ ~s{defp do_run(["release.v105"]), do: release_v105()}
      assert task_source =~ ~s(mix allbert.test release.v105)
      assert task_source =~ ~s(id: "v105_platform_port_visibility")
      assert task_source =~ ~s(id: "v105_settings_cross_process_transaction")
      assert task_source =~ ~s(id: "v105_service_confirmation_lifecycle")
      assert task_source =~ ~s(id: "v105_configured_local_first_run")
      assert task_source =~ ~s(id: "v105_onboarding_tui_completion")

      assert task_source =~
               ~s(apps/allbert_browser/test/allbert_browser/playwright_driver_test.exs)

      assert task_source =~ ~s(test/allbert_assist/settings/store_cross_process_race_test.exs)
      assert task_source =~ ~s(@release_v105_steps @release_v104_steps ++ @v105_focused_steps)
    end

    test "release.v121 is an exact release.v12 prefix with existing focused targets" do
      proof = AllbertTestTask.release_prefix_proof("v121")
      definitions = proof["definitions"]

      assert proof["status"] == "passed"
      assert Enum.map(proof["checks"], & &1["exact_prefix"]) == [true, true]

      v1 = definitions["release.v1"]
      v12 = definitions["release.v12"]
      v121 = definitions["release.v121"]

      assert Enum.take(v12, length(v1)) == v1
      assert Enum.take(v121, length(v12)) == v12
      assert length(v121) > length(v12)

      for step <- Enum.drop(v121, length(v12)),
          step["executable"] == "mix",
          ["test" | targets] <- [step["args"]],
          target <- targets do
        root =
          if step["cwd"] == "core",
            do: Path.expand("../../..", __DIR__),
            else: Path.expand("../../../../..", __DIR__)

        assert File.exists?(Path.join(root, target)),
               "release.v121 focused step target missing: #{target}"
      end
    end

    test "release.v13 is an exact release.v121 prefix with existing focused targets" do
      proof = AllbertTestTask.release_prefix_proof("v13")
      definitions = proof["definitions"]

      assert proof["status"] == "passed"
      assert Enum.map(proof["checks"], & &1["exact_prefix"]) == [true, true, true]

      v121 = definitions["release.v121"]
      v13 = definitions["release.v13"]

      assert Enum.take(v13, length(v121)) == v121
      assert length(v13) > length(v121)

      for step <- Enum.drop(v13, length(v121)),
          step["executable"] == "mix",
          ["test" | targets] <- [step["args"]],
          target <- targets do
        root =
          if step["cwd"] == "core",
            do: Path.expand("../../..", __DIR__),
            else: Path.expand("../../../../..", __DIR__)

        assert File.exists?(Path.join(root, target)),
               "release.v13 focused step target missing: #{target}"
      end
    end

    test "release.v131 freezes the v1.3 digest and its closed eight-step delta" do
      proof = AllbertTestTask.release_v131_topology_proof()
      definitions = proof["definitions"]["release.v131"]

      assert proof["status"] == "passed"
      assert Enum.all?(proof["checks"], fn {_name, passed?} -> passed? end)
      assert proof["release_v13_frozen_sha256"] == proof["release_v13_observed_sha256"]
      assert length(proof["definitions"]["release.v13"]) == 32
      assert length(definitions) == 8

      assert Enum.map(definitions, & &1["id"]) == proof["release_v131_step_ids"]

      test_targets =
        for %{"args" => ["test" | targets]} <- definitions,
            target <- targets,
            do: target

      assert test_targets == proof["release_v131_target_allowlist"]

      refute Enum.any?(definitions, fn step ->
               step["args"] in [
                 ["test"],
                 ["allbert.test", "release.v13"],
                 ["allbert.test", "release"],
                 ["precommit"],
                 ["allbert.test", "qualify-head"]
               ]
             end)
    end

    test "release.v132 freezes both predecessors and its closed eight-step delta" do
      proof = AllbertTestTask.release_v132_topology_proof()
      definitions = proof["definitions"]["release.v132"]

      assert proof["status"] == "passed"
      assert Enum.all?(proof["checks"], fn {_name, passed?} -> passed? end)
      assert proof["release_v13_frozen_sha256"] == proof["release_v13_observed_sha256"]
      assert proof["release_v131_frozen_sha256"] == proof["release_v131_observed_sha256"]
      assert length(proof["definitions"]["release.v13"]) == 32
      assert length(proof["definitions"]["release.v131"]) == 8
      assert length(definitions) == 8
      assert proof["docs_archive_dirs"] == ["docs/archives", "docs/plans/archives"]

      assert Enum.map(definitions, & &1["id"]) == proof["release_v132_step_ids"]

      test_targets =
        for %{"args" => ["test" | targets]} <- definitions,
            target <- targets,
            do: target

      assert test_targets == proof["release_v132_target_allowlist"]

      owner_index = Enum.find_index(proof["preflight_step_ids"], &(&1 == "owner_cwd_test_load"))
      tag_index = Enum.find_index(proof["preflight_step_ids"], &(&1 == "lane_tags"))
      manifest_index = Enum.find_index(proof["preflight_step_ids"], &(&1 == "test_manifest"))
      assert owner_index < tag_index
      assert tag_index < manifest_index

      refute Enum.any?(definitions, fn step ->
               step["args"] in [
                 ["test"],
                 ["allbert.test", "release.v13"],
                 ["allbert.test", "release.v131"],
                 ["allbert.test", "release"],
                 ["allbert.test", "compatibility"],
                 ["precommit"]
               ]
             end)
    end

    test "release.v132 closed targets exist, are manifested, and rejoin aggregate lanes" do
      proof = AllbertTestTask.release_v132_structure_proof()

      assert proof["status"] == "passed"
      assert proof["targets_status"] == "passed"
      assert length(proof["target_checks"]) == 17

      assert Enum.all?(proof["target_checks"], fn target ->
               target["exists"] and target["manifest"] and target["aggregate_covered"] and
                 target["owner"] in ["core", "web"] and is_binary(target["primary_lane"])
             end)
    end
  end

  # Post-v1.0.0 (3c6c7230): released version docs live in docs/plans/archives/,
  # indexed via the plans README; the active scope is the living planning docs.
  # The original archives/v0.66 expectation here went stale in that turnover —
  # surfaced by the v1.0.2 M1 lane reconciliation (this file was double-tagged
  # and its lane barely ran pre-reconciliation).
  test "docs gate scope is the living planning docs with an archives index check" do
    source =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()

    assert source =~ ~s(@docs_active_plan_files)
    assert source =~ ~s("docs/plans/README.md")
    assert source =~ ~s("docs/plans/roadmap.md")
    assert source =~ ~s("docs/plans/allbert-jido-vision.md")
    assert source =~ ~s("docs/plans/future-features.md")
    refute source =~ ~s("docs/plans/v0.66-plan.md")
    assert source =~ ~s(defp docs_check_plan_index)
    assert source =~ ~s(defp docs_check_adr_index_statuses)
    assert source =~ ~s(defp docs_check_command_group_docs)
    assert source =~ ~s(defp docs_check_local_markdown_links)
    assert source =~ ~s(alias AllbertAssist.CLI.Commands, as: CLICommands)
    assert source =~ ~s|CLICommands.groups()|
    assert source =~ ~s(local Markdown links agree)
  end

  test "docs gate validates local Markdown links inside both archive trees" do
    root = temp_path("archive-links")
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    plans_archive = Path.join(root, "docs/plans/archives")
    general_archive = Path.join(root, "docs/archives")
    File.mkdir_p!(plans_archive)
    File.mkdir_p!(general_archive)

    File.write!(Path.join(plans_archive, "target.md"), "# Target\n")
    File.write!(Path.join(plans_archive, "plan.md"), "[target](target.md)\n")
    File.write!(Path.join(general_archive, "review.md"), "[missing](missing.md)\n")

    assert AllbertTestTask.docs_local_markdown_link_errors(root) == [
             "docs/archives/review.md: local Markdown link does not resolve: missing.md"
           ]

    File.write!(Path.join(general_archive, "missing.md"), "# Restored target\n")
    assert AllbertTestTask.docs_local_markdown_link_errors(root) == []
  end

  test "ADR index status labels match the linked ADR Status sections" do
    root = Path.expand("../../../../..", __DIR__)
    index = File.read!(Path.join(root, "docs/adr/README.md"))

    for [basename, indexed_status] <-
          Regex.scan(
            ~r/\]\((\d{4}-[^)]+\.md)\) \((Accepted|Proposed|Rejected|Deprecated|Superseded)\b/,
            index,
            capture: :all_but_first
          ) do
      body = File.read!(Path.join([root, "docs/adr", basename]))

      assert [_, ^indexed_status] =
               Regex.run(
                 ~r/^## Status\s*$\n+(?:\s*\n)*\s*(Accepted|Proposed|Rejected|Deprecated|Superseded)\b/m,
                 body
               )
    end
  end

  test "docs gate flags version-pinned currency phrasings beyond 'current as of v'" do
    source =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()

    # The 'v<x> is the current packaged release line' pin and the version-aware
    # shipped-as-'Planned' check are both enforced, not just 'current as of v'.
    assert source =~ ~s(is the current packaged release line)
    assert source =~ ~s(is still marked 'Planned')
    assert source =~ ~s(defp shipped_version_mm)
  end

  test "release secret scan includes provider-shaped key patterns" do
    source =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()

    assert source =~ ~s("google_api_key")
    assert source =~ ~s("aws_access_key")
    assert source =~ ~s("aws_session_key")
    assert source =~ "AIza"
    assert source =~ "ASIA"
  end

  test "phase runner short-circuits after a failing phase", %{evidence_root: root} do
    runner = fn
      %{id: "first"} -> {"first ok\n", 0}
      %{id: "second"} -> {"second failed token=secret-token\n", 2}
      %{id: "third"} -> {"should not run\n", 0}
    end

    assert {:error, result} =
             PhaseRunner.run_gate(
               "unit",
               [
                 %{id: "first", cwd: File.cwd!(), executable: "mix", args: ["help"], env: []},
                 %{id: "second", cwd: File.cwd!(), executable: "mix", args: ["help"], env: []},
                 %{id: "third", cwd: File.cwd!(), executable: "mix", args: ["help"], env: []}
               ],
               command_runner: runner,
               evidence?: true,
               evidence_root: root,
               emit: fn _message -> :ok end
             )

    assert Enum.map(result.phases, & &1.id) == ["first", "second"]
    assert result.status == "failed"
    [evidence_path] = Path.wildcard(Path.join(root, "unit-*.json"))
    refute File.read!(evidence_path) =~ "secret-token"
  end

  test "phase runner stores full system output while bounding JSON tails", %{
    evidence_root: root
  } do
    output = "full-output-start " <> String.duplicate("middle ", 10) <> "tail"

    assert {:ok, result} =
             PhaseRunner.run_gate(
               "unit",
               [
                 %{
                   id: "printf",
                   cwd: File.cwd!(),
                   executable: "printf",
                   args: [output],
                   env: [],
                   tail_limit: 8,
                   stream?: false
                 }
               ],
               command_runner: &PhaseRunner.run_system_cmd/1,
               evidence?: true,
               evidence_root: root,
               emit: fn _message -> :ok end
             )

    [phase] = result.phases
    assert phase.redacted_output_tail == String.slice(output, -8, 8)
    refute phase.redacted_output_tail =~ "full-output-start"
    assert File.read!(phase.redacted_output_log_path) == output
  end

  test "failed mix test phase persists full log, seed, and failure manifest", %{
    evidence_root: root
  } do
    phase_cwd = temp_path("phase-cwd")
    on_exit(fn -> File.rm_rf!(phase_cwd) end)

    manifest_path = Path.join(phase_cwd, "_build/test/.mix/.mix_test_failures")
    File.mkdir_p!(Path.dirname(manifest_path))
    File.write!(manifest_path, :erlang.term_to_binary([{:failed, "test_name"}]))

    long_prefix = String.duplicate("early failure context ", 20)

    runner = fn %{id: "core_tests"} ->
      {"""
       Running ExUnit with seed: 123456, max_cases: 40
       #{long_prefix}
       1) test exact failure block survives outside the tail
       token=secret-token
       3 tests, 1 failure, 1 skipped
       """, 2}
    end

    assert {:error, result} =
             PhaseRunner.run_gate(
               "unit",
               [
                 %{
                   id: "core_tests",
                   cwd: phase_cwd,
                   executable: "mix",
                   args: ["test"],
                   env: [],
                   tail_limit: 24
                 }
               ],
               command_runner: runner,
               evidence?: true,
               evidence_root: root,
               emit: fn _message -> :ok end
             )

    [phase] = result.phases
    assert phase.test_seeds == [123_456]
    assert phase.summary == %{tests: 3, failures: 1, skipped: 1}
    refute phase.redacted_output_tail =~ "exact failure block"

    assert File.read!(phase.redacted_output_log_path) =~ "exact failure block"
    refute File.read!(phase.redacted_output_log_path) =~ "secret-token"

    manifest =
      Enum.find(phase.failure_manifest_paths, fn entry ->
        entry.source_path == manifest_path
      end)

    assert manifest
    assert File.read!(manifest.artifact_path) == File.read!(manifest_path)

    [evidence_path] = Path.wildcard(Path.join(root, "unit-*.json"))
    evidence = Jason.decode!(File.read!(evidence_path))
    [evidence_phase] = evidence["phases"]
    assert evidence_phase["redacted_output_log_path"] == phase.redacted_output_log_path
    assert evidence_phase["test_seeds"] == [123_456]
    refute File.read!(evidence_path) =~ "secret-token"
  end

  defp drain_phases(acc \\ []) do
    receive do
      {:phase, id, cwd, args} -> drain_phases(acc ++ [{id, cwd, args}])
    after
      0 -> acc
    end
  end

  defp drain_phase_envs(acc \\ []) do
    receive do
      {:phase_env, id, env} -> drain_phase_envs(acc ++ [{id, env}])
    after
      0 -> acc
    end
  end

  defp read_metrics!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp repo_root, do: Path.expand("../../../../..", __DIR__)

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-test-task-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp put_changed_files(files) do
    Application.put_env(:allbert_assist, :gate_changed_files, fn -> {:ok, files} end)
  end

  defp section_between(text, start_marker, end_marker) do
    {start_position, _start_length} = string_match!(text, start_marker)
    from_start = binary_part(text, start_position, byte_size(text) - start_position)
    {end_position, _end_length} = string_match!(from_start, end_marker)
    binary_part(from_start, 0, end_position)
  end

  defp string_position!(text, marker) do
    {position, _length} = string_match!(text, marker)
    position
  end

  defp string_match!(text, marker) do
    case :binary.match(text, marker) do
      :nomatch -> flunk("expected to find #{inspect(marker)}")
      match -> match
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
