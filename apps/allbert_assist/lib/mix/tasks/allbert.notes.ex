defmodule Mix.Tasks.Allbert.Notes do
  @moduledoc """
  Connect and inspect the local notes/files root.

  ## Usage

      mix allbert.notes set-root PATH   # connect a notes folder (PATH must exist)
      mix allbert.notes show            # print the current notes root

  The dispatch logic is shared with the packaged `allbert admin notes` command
  (`AllbertAssist.CLI.Areas.Notes`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Connect and inspect the local notes/files root"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Notes, args)
  end
end
