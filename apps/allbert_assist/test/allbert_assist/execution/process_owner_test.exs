defmodule AllbertAssist.Execution.ProcessOwnerTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Execution.ProcessOwner

  test "preserves argv, cwd, env, merged output, and exit status" do
    root = "/"

    assert {:ok, result} =
             ProcessOwner.run("/bin/sh", ["-c", "printf '%s:%s' \"$PWD\" \"$M4_VALUE\""],
               cd: root,
               env: [{"M4_VALUE", "present"}],
               timeout_ms: 2_000,
               max_output_bytes: 4_096
             )

    assert result.exit_status == 0
    assert result.output == "/:present"
    assert result.containment == :process_group
    refute result.timed_out?
  end

  test "missing executable fails closed without an untracked fallback" do
    assert {:error, _reason} =
             ProcessOwner.run("/allbert/not-present", [],
               cd: "/",
               env: [],
               timeout_ms: 100,
               max_output_bytes: 100
             )
  end

  test "packaged execution capability matrix selects erlexec without a new native helper" do
    assert Code.ensure_loaded?(:exec)
    assert function_exported?(:exec, :run_link, 2)
    assert function_exported?(:exec, :stop_and_wait, 2)
    assert function_exported?(:exec, :kill, 2)
    refute :code.which(:exec) == :non_existing

    # MuonTrap remains the supervised long-lived-daemon substrate; it does not
    # expose the scoped process-group handle required for arbitrary commands.
    assert Code.ensure_loaded?(MuonTrap.Daemon)
  end
end
