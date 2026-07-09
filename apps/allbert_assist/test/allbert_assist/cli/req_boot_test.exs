defmodule AllbertAssist.CLI.ReqBootTest do
  # async: false — this stops/restarts the :req application, which is process-global.
  use ExUnit.Case, async: false

  alias AllbertAssist.CLI

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
end
