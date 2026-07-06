defmodule Mix.Tasks.Allbert.Exec do
  @moduledoc """
  Request confirmed local shell execution through the Allbert action boundary.

  ## Usage

      mix allbert.exec ls -la
      mix allbert.exec --cwd /path/to/workspace -- ls -la
      mix allbert.exec --cwd /path --timeout 1000 --max-output-bytes 4096 -- rg allbert .

  This task never runs shell strings. It sends one executable plus argv list to
  `run_shell_command`, which applies v0.08 Level 1 local execution policy and
  creates a durable confirmation before any command can execute.

  The dispatch logic is shared with the packaged `allbert admin exec` command
  (`AllbertAssist.CLI.Areas.Exec`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Request confirmed local shell execution"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Exec, args)
  end
end
