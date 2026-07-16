defmodule AllbertAssist.CLI.ReqBootTest do
  # async: false — this stops/restarts the :req application, which is process-global.
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.CLI
  alias AllbertAssist.FirstModel.Ollama

  @moduledoc """
  M8.1 regression: the packaged `mix release` `eval` entry LOADS but does not START OTP
  apps, so the pure/first-run path made an HTTP call before `:req` (and its `Req.Finch`
  pool) was started → `unknown registry: Req.Finch`. `run_entry/1` must start `:req`
  itself. The dev VM always has `:req` started, so we reproduce the "not started"
  condition explicitly by stopping it first.
  """

  setup do
    on_exit(fn -> {:ok, _} = Application.ensure_all_started(:req) end)
    :ok
  end

  test "run_entry starts :req so the pure/first-run path has the Req.Finch pool" do
    :ok = Application.stop(:req)
    assert Process.whereis(Req.Finch) == nil, "precondition: :req stopped, pool gone"

    # A pure command (no DB runtime) must still boot the HTTP client.
    {_stream, _out, code} = CLI.run_entry(["version"])

    assert code == 0
    assert Process.whereis(Req.Finch) != nil, "run_entry must start :req / Req.Finch"
  end

  # v1.0.1 M4.1(A): the `tui` dispatcher verb bypasses `run_entry/1` (it evals
  # `CLI.Tui.launch/0` directly), so it needs its own :req boot — the packaged
  # `allbert tui` crashed in the readiness guard's Ollama probe with
  # `GenServer.call(Req.FinchSupervisor, ...)` :noproc (DIT-4(d) blocker).
  test "CLI.Tui launch prelude starts :req before the readiness guard probes Ollama" do
    :ok = Application.stop(:req)
    assert Process.whereis(Req.FinchSupervisor) == nil, "precondition: :req stopped"

    assert :ok = CLI.Tui.ensure_http_started()

    assert Process.whereis(Req.Finch) != nil

    assert Process.whereis(Req.FinchSupervisor) != nil,
           "custom connect_options pools spawn under Req.FinchSupervisor — the crash seam"
  end

  test "the Ollama first-model probe degrades to :error instead of exiting when :req is down" do
    :ok = Application.stop(:req)

    assert Ollama.server_version() == :error
  end
end
