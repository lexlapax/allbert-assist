defmodule Mix.Tasks.Allbert.Dynamic do
  @moduledoc """
  Inspect v0.37 dynamic draft and integration metadata.

  ## Usage

      mix allbert.dynamic drafts list
      mix allbert.dynamic drafts show SLUG
      mix allbert.dynamic drafts request SLUG SUMMARY...
      mix allbert.dynamic drafts discard SLUG
      mix allbert.dynamic drafts integrate SLUG
      mix allbert.dynamic integrations show SLUG [REVISION]
      mix allbert.dynamic integrations rollback SLUG [REVISION]
      mix allbert.dynamic integrations disable

  The dispatch logic is shared with the packaged `allbert admin plugins` command
  (`AllbertAssist.CLI.Areas.Plugins`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect v0.37 dynamic capability metadata"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Plugins, args)
  end
end
