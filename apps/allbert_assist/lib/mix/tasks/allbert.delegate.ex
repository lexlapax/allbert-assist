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

  @shortdoc "Dispatch a registered objective delegate agent"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> Areas.Objectives.dispatch(nil)
    |> finish()
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
