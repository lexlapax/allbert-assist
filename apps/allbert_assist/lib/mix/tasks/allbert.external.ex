defmodule Mix.Tasks.Allbert.External do
  @moduledoc """
  Create confirmed external service requests.

      mix allbert.external request --url https://example.com/status
      mix allbert.external request --profile test_echo --path /status

  The dispatch logic is shared with the packaged `allbert admin external`
  command (`AllbertAssist.CLI.Areas.External`); this task is a thin Mix-shell
  wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Create confirmed external service requests"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.External, args)
  end
end
