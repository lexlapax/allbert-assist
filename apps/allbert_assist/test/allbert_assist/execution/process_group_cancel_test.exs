defmodule AllbertAssist.Execution.ProcessGroupCancelTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial
  @moduletag :external_runtime_serial

  alias AllbertAssist.Execution.ProcessOwner
  alias AllbertAssist.Settings

  test "normal spawns pin the Settings Central grace while explicit overrides win" do
    assert {:ok, _} = Settings.put("execution.cancel.grace_ms", 321, %{audit?: false})

    inherited = Task.async(fn -> run_sleep("settings-grace", []) end)
    inherited_owner = await_owner("settings-grace")
    assert :sys.get_state(inherited_owner).kill_grace_ms == 321
    assert {:ok, :os_kill} = ProcessOwner.cancel("settings-grace")
    assert {:ok, _} = Task.await(inherited, 5_000)

    overridden = Task.async(fn -> run_sleep("explicit-grace", kill_grace_ms: 77) end)
    overridden_owner = await_owner("explicit-grace")
    assert :sys.get_state(overridden_owner).kill_grace_ms == 77
    assert {:ok, :os_kill} = ProcessOwner.cancel("explicit-grace")
    assert {:ok, _} = Task.await(overridden, 5_000)
  end

  test "timeout kills an ordinary child and grandchild in the captured group" do
    assert {:ok, result} = run_tree("timeout-tree", 200)
    assert result.timed_out?

    pids = parse_pids(result.output)
    assert length(pids) == 4
    eventually(fn -> Enum.all?(pids, &(not alive?(&1))) end)
  end

  test "explicit cancel kills only the addressed execution group" do
    first = Task.async(fn -> run_tree("cancelled-tree", 30_000) end)
    second = Task.async(fn -> run_tree("sibling-tree", 30_000) end)

    first_owner = await_owner("cancelled-tree")
    second_owner = await_owner("sibling-tree")
    first_pid = :sys.get_state(first_owner).os_pid
    second_pid = :sys.get_state(second_owner).os_pid

    assert {:ok, :os_kill} = ProcessOwner.cancel("cancelled-tree")
    assert {:ok, _result} = Task.await(first, 5_000)
    eventually(fn -> not alive?(first_pid) end)
    assert alive?(second_pid)

    assert {:ok, :os_kill} = ProcessOwner.cancel("sibling-tree")
    assert {:ok, _result} = Task.await(second, 5_000)
  end

  test "owner loss invokes linked process-group cleanup" do
    caller = self()

    {runner, monitor} =
      spawn_monitor(fn ->
        send(caller, {:owner_loss_result, run_tree("owner-loss-tree", 30_000)})
      end)

    owner = await_owner("owner-loss-tree")
    os_pid = :sys.get_state(owner).os_pid

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^runner, _reason}, 5_000
    refute_receive {:owner_loss_result, _result}
    eventually(fn -> not alive?(os_pid) end)
  end

  defp run_tree(id, timeout_ms) do
    script =
      "trap '' TERM; sleep 30 & child=$!; sh -c 'trap \"\" TERM; sleep 30 & echo grand:$!; wait' & nested=$!; echo root:$$ child:$child nested:$nested; wait"

    ProcessOwner.run("/bin/sh", ["-c", script],
      execution_id: id,
      cd: System.tmp_dir!(),
      env: [],
      timeout_ms: timeout_ms,
      kill_grace_ms: 100,
      max_output_bytes: 4_096
    )
  end

  defp run_sleep(id, extra_opts) do
    ProcessOwner.run(
      "/bin/sh",
      ["-c", "trap '' TERM; sleep 30"],
      [
        execution_id: id,
        cd: System.tmp_dir!(),
        env: [],
        timeout_ms: 30_000,
        max_output_bytes: 4_096
      ] ++ extra_opts
    )
  end

  defp await_owner(id) do
    eventually(fn ->
      case Registry.lookup(AllbertAssist.Execution.ProcessRegistry, {:execution, id}) do
        [{pid, _}] -> pid
        [] -> false
      end
    end)
  end

  defp parse_pids(output) do
    Regex.scan(~r/(?:root|child|nested|grand):(\d+)/, output, capture: :all_but_first)
    |> Enum.map(fn [pid] -> String.to_integer(pid) end)
  end

  defp alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: flunk("condition did not become true: #{inspect(fun.())}")

  defp eventually(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      nil ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
