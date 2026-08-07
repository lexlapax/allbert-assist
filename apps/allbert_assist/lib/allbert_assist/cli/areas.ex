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

  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Surfaces.ContextBuilder

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
    case EffectGuard.admit_ready() do
      {:ok, epoch} ->
        context =
          ContextBuilder.cli_context(
            surface: "mix #{inspect(area_module)}",
            allbert_pack_epoch: epoch
          )

        run(area_module, argv, context)

      {:error, :product_not_ready} ->
        Mix.raise("Allbert product is not ready; retry the command.")
    end
  end

  @doc false
  @spec run(module(), [String.t()], map() | nil) :: :ok
  def run(area_module, argv, context) do
    case area_module.dispatch(argv, context) do
      {output, 0} ->
        if output != "", do: Mix.shell().info(output)
        :ok

      {output, _code} ->
        Mix.raise(output)
    end
  end
end
