defmodule Mix.Tasks.Allbert.Sessions do
  @moduledoc """
  Inspect and control volatile local session scratchpad entries.

  ## Usage

      mix allbert.sessions list [--user USER]
      mix allbert.sessions show --user USER --session SESSION_ID
      mix allbert.sessions set-active-app --user USER --session SESSION_ID APP
      mix allbert.sessions clear-active-app --user USER --session SESSION_ID
      mix allbert.sessions clear --user USER --session SESSION_ID
      mix allbert.sessions sweep

  The dispatch logic is shared with the packaged `allbert admin sessions` command
  (`AllbertAssist.CLI.Areas.Sessions`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and control volatile session scratchpad entries"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Sessions, args)
  end
end
