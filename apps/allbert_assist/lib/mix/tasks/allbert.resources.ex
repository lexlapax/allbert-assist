defmodule Mix.Tasks.Allbert.Resources do
  @moduledoc """
  Inspect and revoke remembered Allbert resource grants.

  ## Usage

      mix allbert.resources grants list
      mix allbert.resources grants show GRANT_ID
      mix allbert.resources grants revoke GRANT_ID [--reason REASON...]

  The dispatch logic is shared with the packaged `allbert admin resources`
  command (`AllbertAssist.CLI.Areas.Resources`); this task is a thin Mix-shell
  wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and revoke remembered resource grants"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Resources, args)
  end
end
