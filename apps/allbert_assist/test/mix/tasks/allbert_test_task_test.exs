defmodule Mix.Tasks.Allbert.TestTaskTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.DevGates.PhaseRunner
  alias Mix.Tasks.Allbert.Test, as: AllbertTestTask

  setup do
    original_runner = Application.get_env(:allbert_assist, :gate_command_runner)
    original_evidence_root = Application.get_env(:allbert_assist, :gate_evidence_root)
    original_changed_files = Application.get_env(:allbert_assist, :gate_changed_files)
    evidence_root = temp_path("evidence")
    parent = self()

    runner = fn phase ->
      send(parent, {:phase, phase.id, phase.cwd, phase.args})
      {"#{phase.id} token=secret-token\n3 tests, 0 failures\n", 0}
    end

    Application.put_env(:allbert_assist, :gate_command_runner, runner)
    Application.put_env(:allbert_assist, :gate_evidence_root, evidence_root)

    on_exit(fn ->
      restore_app_env(:gate_command_runner, original_runner)
      restore_app_env(:gate_evidence_root, original_evidence_root)
      restore_app_env(:gate_changed_files, original_changed_files)
      File.rm_rf!(evidence_root)
      Mix.Task.reenable("allbert.test")
      Mix.Task.reenable("precommit")
    end)

    {:ok, evidence_root: evidence_root}
  end

  test "release runs explicit phases and does not delegate to precommit", %{evidence_root: root} do
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
    put_changed_files(["docs/plans/v0.49-plan.md", "CHANGELOG.md"])

    output =
      capture_io(fn ->
        assert :ok = AllbertTestTask.run(["commit"])
      end)

    assert drain_phases() == []
    assert output =~ "==> commit gate docs-only"
    assert output =~ "==> docs"
  end

  test "commit gate mixed changes still run focused commit phases" do
    put_changed_files(["docs/plans/v0.49-plan.md", "apps/allbert_assist/lib/example.ex"])

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
    assert error.message =~ "mix allbert.test external-smoke -- telegram"
    assert error.message =~ "mix allbert.test external-smoke -- email"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_telegram"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_email"
    assert error.message =~ "mix allbert.test external-smoke -- matrix"
    assert error.message =~ "mix allbert.test external-smoke -- discord"
    assert error.message =~ "mix allbert.test external-smoke -- slack"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_discord"
    assert error.message =~ "mix allbert.test external-smoke -- inbound_slack"
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

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
