defmodule Mix.Tasks.Allbert.Tui do
  @moduledoc """
  Run the local Allbert terminal TUI channel.

  ## Usage

      mix allbert.tui
  """

  use Mix.Task

  alias AllbertAssist.Channels.TUI.Adapter

  @shortdoc "Run the local Allbert terminal TUI"

  @impl true
  def run(args) do
    case args do
      [] ->
        Mix.Task.run("app.start")
        Adapter.run_forever()
        :ok

      _args ->
        Mix.raise("Usage: mix allbert.tui")
    end
  end
end
