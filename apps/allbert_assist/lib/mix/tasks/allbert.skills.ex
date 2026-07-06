defmodule Mix.Tasks.Allbert.Skills do
  @moduledoc """
  Validate and scaffold local Allbert Agent Skills.

  ## Usage

      mix allbert.skills validate PATH
      mix allbert.skills list
      mix allbert.skills create NAME ACTION PERMISSION DESCRIPTION... [--root ROOT] [--overwrite]
      mix allbert.skills run SKILL SCRIPT [--cwd PATH] [--timeout MS] [--max-output-bytes BYTES] -- [ARGS...]
      mix allbert.skills search-online QUERY...
      mix allbert.skills show-online SOURCE/ID
      mix allbert.skills audit-online SOURCE/ID
      mix allbert.skills import-online SOURCE/ID
      mix allbert.skills import-url URL
      mix allbert.skills import-local PATH

  The dispatch logic is shared with the packaged `allbert admin skills` command
  (`AllbertAssist.CLI.Areas.Skills`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Validate and scaffold local Allbert Agent Skills"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Skills, args)
  end
end
