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
             "core_tests",
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

  test "commit gate is explicitly non-release evidence" do
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

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
