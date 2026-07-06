defmodule Mix.Tasks.Allbert.SelfImprovement do
  @moduledoc """
  Inspect self-improvement suggestions and inert drafts.

  ## Usage

      mix allbert.self_improvement list
      mix allbert.self_improvement inspect <suggestion_id>
      mix allbert.self_improvement drafts list
      mix allbert.self_improvement drafts inspect <draft_id>
      mix allbert.self_improvement drafts discard <draft_id>

  The dispatch logic is shared with the packaged
  `allbert admin self-improvement` command
  (`AllbertAssist.CLI.Areas.SelfImprovement`); this task is a thin Mix-shell
  wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect self-improvement suggestions and drafts"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.SelfImprovement, args)
  end
end
