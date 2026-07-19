defmodule Mix.Tasks.Allbert.TestTaskTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.DevGates.PhaseRunner
  alias Mix.Tasks.Allbert.Test, as: AllbertTestTask

  setup do
    original_runner = Application.get_env(:allbert_assist, :gate_command_runner)
    original_evidence_root = Application.get_env(:allbert_assist, :gate_evidence_root)
    original_changed_files = Application.get_env(:allbert_assist, :gate_changed_files)
    original_metrics_store = Application.get_env(:allbert_assist, :test_metrics_store)
    evidence_root = temp_path("evidence")
    metrics_store = Path.join(temp_path("metrics"), "runs.jsonl")
    parent = self()

    runner = fn phase ->
      send(parent, {:phase, phase.id, phase.cwd, phase.args})
      {"#{phase.id} token=secret-token\n3 tests, 0 failures\n", 0}
    end

    Application.put_env(:allbert_assist, :gate_command_runner, runner)
    Application.put_env(:allbert_assist, :gate_evidence_root, evidence_root)
    # v1.0.2 M8.1: in-process gate runs must not append to the repo-local
    # .test_metrics store; redirect recording to an owned temp store.
    Application.put_env(:allbert_assist, :test_metrics_store, metrics_store)

    on_exit(fn ->
      restore_app_env(:gate_command_runner, original_runner)
      restore_app_env(:gate_evidence_root, original_evidence_root)
      restore_app_env(:gate_changed_files, original_changed_files)
      restore_app_env(:test_metrics_store, original_metrics_store)
      File.rm_rf!(evidence_root)
      File.rm_rf!(Path.dirname(metrics_store))
      Mix.Task.reenable("allbert.test")
      Mix.Task.reenable("precommit")
    end)

    {:ok, evidence_root: evidence_root, metrics_store: metrics_store}
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

    assert phase_ids == [
             "static_compile",
             "deps_unused",
             "format",
             "credo",
             "high_coverage_fast_local",
             "core_external_runtime_serial",
             "core_security_eval_serial",
             "web_tests",
             "stocksage_tests",
             "channel_plugin_tests",
             "dialyzer"
           ]

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
    assert length(phase_logs) == 11
    assert Enum.all?(phase_logs, &File.exists?/1)
    refute Enum.any?(phase_logs, &(File.read!(&1) =~ "secret-token"))

    # v1.0.2 M8.1: the phase runner emits one metrics record per phase.
    records =
      metrics_store
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(records) == 11
    assert Enum.all?(records, &(&1["gate"] == "release"))
    assert Enum.all?(records, &(&1["status"] == "passed"))
    assert Enum.map(records, & &1["phase_or_step"]) |> List.last() == "dialyzer"
    assert Enum.all?(records, &(&1["tests"] == 3 and &1["failures"] == 0))
    assert Enum.all?(records, &is_integer(&1["wall_ms"]))
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

    # (c) release.v1/v101/v102 step runners record one run per step.
    assert task_source =~ ~s(gate: "release.v1",)
    assert task_source =~ ~s(gate: "release.v101",)
    assert task_source =~ ~s(gate: "release.v102",)

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
    assert phase_ids == ["static_compile", "format", "credo"]
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

  test "commit gate mixed changes still run focused commit phases" do
    put_changed_files(["docs/plans/archives/v0.49-plan.md", "apps/allbert_assist/lib/example.ex"])

    output =
      capture_io(fn ->
        assert :ok = AllbertTestTask.run(["commit"])
      end)

    phase_ids = drain_phases() |> Enum.map(fn {id, _cwd, _args} -> id end)
    assert phase_ids == ["static_compile", "format", "credo"]
    assert output =~ "commit gate is not release evidence"
  end

  test "usage lists the latest release lanes" do
    error = assert_raise Mix.Error, fn -> AllbertTestTask.run(["unknown"]) end

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

    test "all three point-release step runners route status through the zero-test guard" do
      task_source =
        Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
        |> File.read!()

      for gate <- ["release.v1", "release.v101", "release.v102"] do
        assert task_source =~ ~s{release_step_status("#{gate}", step.id, exit_status, output)}
      end
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
    assert source =~ ~s(operator/developer/design/plans indexes complete)
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
