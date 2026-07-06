defmodule Mix.Tasks.Allbert.Workspace do
  @moduledoc """
  Inspect and maintain the Allbert workspace substrate.

  ## Usage

      mix allbert.workspace rotate-signing-secret
      mix allbert.workspace inspect [--user USER] [--thread THREAD]
      mix allbert.workspace canvas list [--user USER] [--thread THREAD] [--include-deleted]
      mix allbert.workspace canvas show TILE_ID [--user USER]
      mix allbert.workspace canvas pin TILE_ID [--user USER]
      mix allbert.workspace canvas unpin TILE_ID [--user USER]
      mix allbert.workspace canvas restore TILE_ID [--user USER]
      mix allbert.workspace canvas purge --before YYYY-MM-DD [--user USER]
      mix allbert.workspace ephemeral list [--user USER] [--thread THREAD] [--include-dismissed]
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and maintain the Allbert workspace substrate"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Workspace, args)
  end
end
