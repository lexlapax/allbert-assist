defmodule Mix.Tasks.Allbert.Confirmations do
  @moduledoc """
  Inspect and resolve durable Allbert confirmation requests.

  ## Usage

      mix allbert.confirmations list
      mix allbert.confirmations list --resolved
      mix allbert.confirmations show CONFIRMATION_ID
      mix allbert.confirmations approve CONFIRMATION_ID [--reason REASON...] [--remember SCOPE] [--resource-index N|--remember-all] [--grant-expires-at ISO8601]
      mix allbert.confirmations deny CONFIRMATION_ID [--reason REASON...]
      mix allbert.confirmations expire

  The dispatch logic is shared with the packaged `allbert admin confirmations`
  command (`AllbertAssist.CLI.Areas.Confirmations`); this task is a thin
  Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and resolve Allbert confirmation requests"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Confirmations, args)
  end
end
