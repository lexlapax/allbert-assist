defmodule AllbertAssist.Execution.CancellationProof do
  @moduledoc """
  Bounded packaged proof for ADR 0085 process-group cancellation.

  This plain module is a diagnostic service, not an authority boundary. It
  accepts only a closed proof mode and launches fixed `/bin/sh` fixtures through
  `ProcessOwner`; callers cannot supply executable text, process ids, cwd, or
  environment. The registered action owns operator authorization.
  """

  alias AllbertAssist.Execution.OutputBuffer
  alias AllbertAssist.Execution.ProcessOwner

  @modes ~w(cancel timeout session-escape)
  @fixture_seconds 30
  @timeout_ms 250
  @kill_grace_ms 100
  @max_output_bytes 4_096

  @spec modes() :: [String.t()]
  def modes, do: @modes

  @spec run(String.t()) :: {:ok, map()} | {:error, term()}
  def run(mode) when mode in @modes do
    case mode do
      "cancel" -> cancel_proof()
      "timeout" -> timeout_proof()
      "session-escape" -> session_escape_proof()
    end
  end

  def run(mode), do: {:error, {:unsupported_mode, mode}}

  defp cancel_proof do
    target_id = execution_id("cancel-target")
    sibling_id = execution_id("cancel-sibling")
    target = proof_task(fn -> run_tree(target_id, 30_000) end)
    sibling = proof_task(fn -> run_tree(sibling_id, 30_000) end)

    try do
      target_pids = await_tree_pids(target_id)
      sibling_pids = await_tree_pids(sibling_id)
      sibling_root = Map.fetch!(sibling_pids, "root")

      {:ok, :os_kill} = ProcessOwner.cancel(target_id)
      {:ok, _target_result} = Task.await(target, 5_000)
      target_tree_dead? = eventually(fn -> all_dead?(target_pids) end)
      sibling_survived? = alive?(sibling_root)

      {:ok, :os_kill} = ProcessOwner.cancel(sibling_id)
      {:ok, _sibling_result} = Task.await(sibling, 5_000)

      cleanup_complete? =
        eventually(fn -> all_dead?(Map.merge(target_pids, sibling_pids)) end)

      proof = %{
        status: pass_if(target_tree_dead? and sibling_survived? and cleanup_complete?),
        mode: "cancel",
        containment: :process_group,
        target_tree_dead?: target_tree_dead?,
        sibling_survived?: sibling_survived?,
        cleanup_complete?: cleanup_complete?
      }

      {:ok, proof}
    after
      cleanup_execution(target_id)
      cleanup_execution(sibling_id)
      shutdown_task(target)
      shutdown_task(sibling)
    end
  end

  defp timeout_proof do
    execution_id = execution_id("timeout")

    try do
      with {:ok, result} <- run_tree(execution_id, @timeout_ms) do
        pids = parse_pids(result.output)
        target_tree_dead? = eventually(fn -> all_dead?(pids) end)
        cleanup_complete? = target_tree_dead? and map_size(pids) == 4

        {:ok,
         %{
           status: pass_if(result.timed_out? and cleanup_complete?),
           mode: "timeout",
           containment: result.containment,
           timed_out?: result.timed_out?,
           target_tree_dead?: target_tree_dead?,
           cleanup_complete?: cleanup_complete?
         }}
      end
    after
      cleanup_execution(execution_id)
    end
  end

  defp session_escape_proof do
    case System.find_executable("setsid") do
      nil ->
        {:ok,
         %{
           status: :unsupported,
           mode: "session-escape",
           containment: :process_group,
           boundary: :setsid_unavailable,
           cleanup_complete?: true
         }}

      setsid ->
        run_session_escape(setsid)
    end
  end

  defp run_session_escape(setsid) do
    execution_id = execution_id("session-escape")
    task = proof_task(fn -> run_escape_tree(execution_id, setsid) end)

    try do
      all_pids = await_escape_pids(execution_id)
      escape_pids = Map.take(all_pids, ["escape_shell", "escape_child"])

      try do
        {:ok, :os_kill} = ProcessOwner.cancel(execution_id)
        {:ok, _result} = Task.await(task, 5_000)
        escape_observed? = Enum.any?(escape_pids, fn {_label, pid} -> alive?(pid) end)
        cleanup_pids(escape_pids)
        cleanup_complete? = eventually(fn -> all_dead?(all_pids) end)

        {:ok,
         %{
           status: pass_if(escape_observed? and cleanup_complete?),
           mode: "session-escape",
           containment: :process_group,
           boundary: if(escape_observed?, do: :escape_observed, else: :escape_not_observed),
           cleanup_complete?: cleanup_complete?
         }}
      after
        cleanup_pids(escape_pids)
      end
    after
      cleanup_execution(execution_id)
      shutdown_task(task)
    end
  end

  defp run_tree(execution_id, timeout_ms) do
    script =
      "trap '' TERM; sleep #{@fixture_seconds} & child=$!; " <>
        "sh -c 'trap \"\" TERM; sleep #{@fixture_seconds} & echo grand:$!; wait' & nested=$!; " <>
        "echo root:$$ child:$child nested:$nested; wait"

    run_fixture(execution_id, script, timeout_ms)
  end

  defp run_escape_tree(execution_id, setsid) do
    escaped =
      "trap '' TERM; sleep #{@fixture_seconds} & " <>
        "echo escape_shell:$$ escape_child:$!; wait"

    script =
      "trap '' TERM; #{shell_quote(setsid)} /bin/sh -c #{shell_quote(escaped)} & " <>
        "echo root:$$ launcher:$!; wait"

    run_fixture(execution_id, script, 30_000)
  end

  defp run_fixture(execution_id, script, timeout_ms) do
    ProcessOwner.run("/bin/sh", ["-c", script],
      execution_id: execution_id,
      cd: System.tmp_dir!(),
      env: [],
      timeout_ms: timeout_ms,
      kill_grace_ms: @kill_grace_ms,
      max_output_bytes: @max_output_bytes
    )
  end

  defp await_tree_pids(execution_id), do: await_pids(execution_id, 4)
  defp await_escape_pids(execution_id), do: await_pids(execution_id, 4)

  defp await_pids(execution_id, expected) do
    eventually(fn ->
      case Registry.lookup(AllbertAssist.Execution.ProcessRegistry, {:execution, execution_id}) do
        [{pid, _}] ->
          read_expected_pids(pid, expected)

        [] ->
          false
      end
    end)
  end

  defp read_expected_pids(pid, expected) do
    output = pid |> :sys.get_state() |> Map.fetch!(:buffer) |> OutputBuffer.output()
    pids = parse_pids(output)
    if map_size(pids) == expected, do: pids, else: false
  end

  defp parse_pids(output) do
    Regex.scan(~r/(root|child|nested|grand|launcher|escape_shell|escape_child):(\d+)/, output,
      capture: :all_but_first
    )
    |> Map.new(fn [label, pid] -> {label, String.to_integer(pid)} end)
  end

  defp alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp cleanup_execution(execution_id) do
    _ = ProcessOwner.cancel(execution_id)
    :ok
  end

  defp cleanup_pids(pids) do
    Enum.each(pids, fn {_label, pid} ->
      if alive?(pid), do: System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)])
    end)

    :ok
  end

  defp all_dead?(pids), do: Enum.all?(pids, fn {_label, pid} -> not alive?(pid) end)

  defp shutdown_task(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp proof_task(fun), do: Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor, fun)

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.() || false

  defp eventually(fun, attempts) do
    case fun.() do
      value when value in [false, nil] ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp execution_id(label), do: "release-proof-#{label}-#{Ecto.UUID.generate()}"
  defp pass_if(true), do: :passed
  defp pass_if(false), do: :failed

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
