defmodule Mix.Tasks.Allbert.Threads do
  @moduledoc """
  Inspect local Allbert conversation threads.

  ## Usage

      mix allbert.threads
      mix allbert.threads --user alice
      mix allbert.threads --user alice --thread THREAD_ID
      mix allbert.threads --operator alice --limit 5
      mix allbert.threads complete THREAD_ID [--user alice]

  The dispatch logic is shared with the packaged `allbert admin threads` command
  (`AllbertAssist.CLI.Areas.Threads`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect local Allbert conversation threads"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Threads, args)
  end
end
