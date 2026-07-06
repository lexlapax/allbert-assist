defmodule Mix.Tasks.Allbert.Security do
  @moduledoc """
  Inspect Security Central status.

  ## Usage

      mix allbert.security status
      mix allbert.security review --recent [--limit N]

  The dispatch logic is shared with the packaged `allbert admin trust` command
  (`AllbertAssist.CLI.Areas.Trust`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect Security Central status"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Trust, args)
  end
end
