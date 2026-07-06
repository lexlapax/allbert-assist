defmodule Mix.Tasks.Allbert.Plan do
  @moduledoc """
  Inspect and cancel v0.44 Plan/Build runs.

  ## Usage

      mix allbert.plan list [--format ids] [--status running] [--user USER]
      mix allbert.plan show OBJECTIVE_ID [--user USER]
      mix allbert.plan cancel OBJECTIVE_ID --reason REASON [--user USER]
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and cancel Plan/Build runs"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Plan, args)
  end
end
