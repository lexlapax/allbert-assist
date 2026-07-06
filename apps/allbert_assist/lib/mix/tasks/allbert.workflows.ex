defmodule Mix.Tasks.Allbert.Workflows do
  @moduledoc """
  Inspect and expand v0.44 workflow YAML files.

  ## Usage

      mix allbert.workflows list
      mix allbert.workflows inspect WORKFLOW_ID
      mix allbert.workflows expand WORKFLOW_ID --input key=value
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect v0.44 workflow YAML"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Workflows, args)
  end
end
