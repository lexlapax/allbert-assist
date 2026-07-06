defmodule Mix.Tasks.Allbert.Tools do
  @moduledoc """
  Find Allbert tool candidates.

  ## Usage

      mix allbert.tools find "settings"

  The dispatch logic is shared with the packaged `allbert admin tools` command
  (`AllbertAssist.CLI.Areas.Tools`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Find Allbert tool candidates"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Tools, args)
  end
end
