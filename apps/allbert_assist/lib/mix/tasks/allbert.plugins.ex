defmodule Mix.Tasks.Allbert.Plugins do
  @moduledoc """
  Inspect registered Allbert plugins.

  ## Usage

      mix allbert.plugins list
      mix allbert.plugins show PLUGIN_ID
      mix allbert.plugins diagnostics

  The dispatch logic is shared with the packaged `allbert admin plugins` command
  (`AllbertAssist.CLI.Areas.Plugins`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect registered Allbert plugins"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Plugins, args)
  end
end
