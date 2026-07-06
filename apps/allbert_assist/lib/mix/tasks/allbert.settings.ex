defmodule Mix.Tasks.Allbert.Settings do
  @moduledoc """
  Inspect and update Allbert Settings Central.

  ## Usage

      mix allbert.settings list
      mix allbert.settings get operator.timezone
      mix allbert.settings explain operator.timezone
      mix allbert.settings set operator.communication_style concise
      mix allbert.settings providers list
      mix allbert.settings doctor
      mix allbert.settings model-doctor
      printf 'sk-test\\n' | mix allbert.settings providers set-key openai

  The dispatch logic is shared with the packaged `allbert admin settings`
  command (`AllbertAssist.CLI.Areas.Settings`); this task is a thin Mix-shell
  wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and update Allbert Settings Central"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Settings, args)
  end
end
