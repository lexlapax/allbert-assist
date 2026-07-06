defmodule Mix.Tasks.Allbert.PublicProtocol do
  @moduledoc """
  Manage v0.51 public protocol bearer tokens.

  ## Usage

      mix allbert.public_protocol token create --surface mcp_http --client claude
      mix allbert.public_protocol token rotate --surface openai_api --client local
      mix allbert.public_protocol token revoke --surface mcp_http --client claude
      mix allbert.public_protocol token list --surface openai_api

  The dispatch logic is shared with the packaged `allbert admin public_protocol`
  command (`AllbertAssist.CLI.Areas.PublicProtocol`); this task is a thin
  Mix-shell wrapper.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Manage public protocol bearer tokens"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Areas.run(Areas.PublicProtocol, args)
  end
end
