defmodule Mix.Tasks.Allbert.Model do
  @moduledoc """
  Inspect and select Allbert model profiles.

  ## Usage

      mix allbert.model list
      mix allbert.model use PROFILE [--enable-assist]
      mix allbert.model doctor PROFILE

  The dispatch logic is shared with the packaged `allbert admin model` command
  (`AllbertAssist.CLI.Areas.Model`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect, select, and doctor model profiles"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Model, args)
  end
end
