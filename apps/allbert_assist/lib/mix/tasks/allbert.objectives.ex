defmodule Mix.Tasks.Allbert.Objectives do
  @moduledoc """
  Inspect durable Allbert objectives.

  ## Usage

      mix allbert.objectives list [--user USER] [--status open] [--active-app stocksage] [--limit 20]
      mix allbert.objectives show OBJECTIVE_ID [--user USER]
      mix allbert.objectives continue OBJECTIVE_ID [--user USER]
      mix allbert.objectives cancel OBJECTIVE_ID --reason REASON [--user USER]

  The dispatch logic is shared with the packaged `allbert admin objectives`
  command (`AllbertAssist.CLI.Areas.Objectives`); this task is a thin Mix-shell
  wrapper that preserves the documented sysexits-style exit codes (64 usage,
  65 not-found, 66 identity, 1 failure).
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect durable Allbert objectives"

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
