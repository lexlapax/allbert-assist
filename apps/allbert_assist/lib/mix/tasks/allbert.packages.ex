defmodule Mix.Tasks.Allbert.Packages do
  @moduledoc """
  Plan and request confirmed package-manager installs.

  ## Usage

      mix allbert.packages plan npm --cwd /path/to/project --package left-pad@1.3.0
      mix allbert.packages run npm --cwd /path/to/project --package left-pad@1.3.0

  `plan` never runs a package manager. `run` creates a durable confirmation and
  only the approved npm path can execute in v0.10.

  The dispatch logic is shared with the packaged `allbert admin packages`
  command (`AllbertAssist.CLI.Areas.Packages`); this task is a thin Mix-shell
  wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Plan or request confirmed package installs"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Packages, args)
  end
end
