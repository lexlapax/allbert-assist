defmodule AllbertAssist.CLI.Areas do
  @moduledoc """
  Namespace + Mix-wrapper glue for the release-safe operator area dispatchers
  (v0.62 M8.7). Each `AllbertAssist.CLI.Areas.<Area>` exposes
  `dispatch(argv, context) :: {output, exit_code}` and is the single source of
  truth for both `mix allbert.<area>` and `allbert admin <area>`.

  `run/2` is the thin Mix-task adapter: it runs the shared dispatcher and prints
  through `Mix.shell/0`, raising (non-zero exit) on failure so `mix` behaves as
  before. The packaged CLI calls `dispatch/2` directly (see
  `AllbertAssist.CLI`).
  """

  @doc """
  Run an area dispatcher from a Mix task: print output on success, raise on
  failure.

  A non-zero exit code raises `Mix.Error` (via `Mix.raise/1`) so the Mix task
  reproduces the original `Mix.raise` behaviour — the failure output becomes the
  raised message and `mix` exits non-zero. The packaged CLI does not use this
  wrapper; it calls `dispatch/2` directly and halts on the returned code.
  """
  @spec run(module(), [String.t()]) :: :ok
  def run(area_module, argv) do
    case area_module.dispatch(argv, nil) do
      {output, 0} ->
        if output != "", do: Mix.shell().info(output)
        :ok

      {output, _code} ->
        Mix.raise(output)
    end
  end
end
