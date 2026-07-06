defmodule Mix.Tasks.Allbert.Apps do
  @moduledoc """
  Inspect and validate registered Allbert workspace apps.

  ## Usage

      mix allbert.apps list
      mix allbert.apps show APP_ID
      mix allbert.apps validate MODULE

  The dispatch logic is shared with the packaged `allbert admin apps` command
  (`AllbertAssist.CLI.Areas.Apps`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and validate registered Allbert workspace apps"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Apps, args)
  end
end
