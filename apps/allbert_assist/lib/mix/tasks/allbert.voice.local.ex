defmodule Mix.Tasks.Allbert.Voice.Local do
  @moduledoc """
  Manage the Allbert-owned local voice runtime.

  ## Usage

      mix allbert.voice.local doctor
      mix allbert.voice.local start
      mix allbert.voice.local token

  The dispatch logic is shared with the packaged `allbert admin voice` command
  (`AllbertAssist.CLI.Areas.Voice`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Doctor and start the Allbert local voice runtime"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Voice, args)
  end
end
