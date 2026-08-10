defmodule Mix.Tasks.Allbert.Delegate do
  @moduledoc """
  Dispatch one registered objective delegate agent from the CLI.

      mix allbert.delegate AGENT_ID '{"ticker":"AAPL"}' [--user USER]
      mix allbert.delegate AGENT_ID --params '{"ticker":"AAPL"}' [--command execute]

  The dispatch logic is shared with the packaged `allbert admin objectives`
  command (`AllbertAssist.CLI.Areas.Objectives`, which folds in the delegate
  subcommand); this task is a thin Mix-shell wrapper that preserves the
  documented sysexits-style exit codes (64 usage, 65 not-found, 66 identity,
  1 failure).
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Dispatch a registered objective delegate agent"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    # Dispatching with a nil context falls back to Areas.Objectives'
    # default_context/0, which carries no readiness epoch — so every delegate
    # dispatch failed closed with :product_not_ready and this task could never
    # succeed. Areas.run/2 is the usual Mix wrapper and admits an epoch, but it
    # turns any non-zero code into a Mix.Error; this task documents sysexits
    # codes (64 usage, 65 not-found, 66 identity, 1 failure) and must keep them,
    # so it admits its own epoch and builds the same context.
    case EffectGuard.admit_ready() do
      {:ok, epoch} ->
        context =
          ContextBuilder.cli_context(
            surface: "mix allbert.delegate",
            allbert_pack_epoch: epoch
          )

        args
        |> Areas.Objectives.dispatch(context)
        |> finish()

      {:error, _reason} ->
        Mix.shell().error("Allbert product is not ready; retry the command.")
        halt(1)
    end
  end

  defp finish({output, 0}) do
    if output != "", do: Mix.shell().info(output)
    :ok
  end

  defp finish({output, code}) do
    if output != "", do: Mix.shell().error(output)
    halt(code)
  end

  defp halt(code) do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:halt_fun, &System.halt/1)
    |> then(& &1.(code))
  end
end
