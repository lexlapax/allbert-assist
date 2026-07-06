defmodule Mix.Tasks.Allbert.Jobs do
  @moduledoc """
  Manage local scheduled jobs.

  ## Usage

      mix allbert.jobs list [--user USER] [--status active|paused|blocked]
      mix allbert.jobs show JOB_ID
      mix allbert.jobs runs JOB_ID [--limit N]
      mix allbert.jobs pause JOB_ID
      mix allbert.jobs resume JOB_ID
      mix allbert.jobs run JOB_ID
      mix allbert.jobs templates
      mix allbert.jobs create runtime-prompt NAME --prompt TEXT [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]
      mix allbert.jobs create template TEMPLATE_NAME [--name NAME] [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]

  The dispatch logic is shared with the packaged `allbert admin jobs` command
  (`AllbertAssist.CLI.Areas.Jobs`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Manage local scheduled jobs"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Jobs, args)
  end
end
