defmodule Mix.Tasks.Allbert.Conversations do
  @moduledoc """
  Inspect and resume canonical Allbert conversations.

  ## Usage

      mix allbert.conversations show THREAD_ID [--user USER] [--limit 50] [--include-e2ee-origin]
      mix allbert.conversations resume THREAD_ID --channel CHANNEL --user USER --receiver RECEIVER --external-user EXTERNAL --provider-thread-key KEY
      mix allbert.conversations resume THREAD_ID --channel cli --user USER

  The dispatch logic is shared with the packaged `allbert admin threads` command
  (`AllbertAssist.CLI.Areas.Threads`, which owns the union of the `threads` and
  `conversations` subcommands); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and resume canonical Allbert conversations"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Threads, args)
  end
end
