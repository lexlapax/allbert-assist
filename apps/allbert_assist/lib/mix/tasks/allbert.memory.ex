defmodule Mix.Tasks.Allbert.Memory do
  @moduledoc """
  Inspect and review Allbert markdown memory.

  ## Usage

      mix allbert.memory list [--category notes] [--namespace identity] [--status unreviewed] [--limit 20]
      mix allbert.memory show PATH
      mix allbert.memory review PATH --status kept|flagged|prune_nominated [--note "..."]
      mix allbert.memory update PATH [--summary "..."] [--body "..."] [--note "..."]
      mix allbert.memory delete PATH
      mix allbert.memory prune [--dry-run] [--write]
      mix allbert.memory search QUERY [--category notes] [--limit 10]
      mix allbert.memory retrieve --query "..."
      mix allbert.memory compile-index
      mix allbert.memory summarize --category notes
      mix allbert.memory promote-turn --thread-id THREAD --message-id MESSAGE [--category notes]

  The dispatch logic is shared with the packaged `allbert admin memory` command
  (`AllbertAssist.CLI.Areas.Memory`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect Allbert markdown memory"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Memory, args)
  end
end
