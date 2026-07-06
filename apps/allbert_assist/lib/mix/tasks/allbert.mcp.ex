defmodule Mix.Tasks.Allbert.Mcp do
  @moduledoc """
  Inspect configured MCP servers.

  ## Usage

      mix allbert.mcp discover QUERY [--limit N]
      mix allbert.mcp connect CANDIDATE_ID_OR_UNIQUE_NAME [--server-id SERVER] [--enable]
      mix allbert.mcp connect --candidate-id CANDIDATE_ID [--server-id SERVER] [--enable]
      mix allbert.mcp scan enable|pause|resume|run-once [QUERY]
      mix allbert.mcp doctor SERVER [--no-discovery]
      mix allbert.mcp tools SERVER
      mix allbert.mcp resources SERVER
      mix allbert.mcp read SERVER URI
      mix allbert.mcp call SERVER TOOL JSON

  The dispatch logic is shared with the packaged `allbert admin mcp` command
  (`AllbertAssist.CLI.Areas.Mcp`); this task is a thin Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect configured MCP servers"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.Mcp, args)
  end
end
