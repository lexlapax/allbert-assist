defmodule Mix.Tasks.Allbert.AcpServer do
  @moduledoc """
  Inspect or run the v0.51 public ACP stdio server.

      mix allbert.acp_server status
      mix allbert.acp_server stdio
  """

  use Mix.Task

  alias AllbertAssist.PublicProtocol.Acp.Mapping
  alias AllbertAssist.PublicProtocol.Acp.Server
  alias AllbertAssist.Settings

  @shortdoc "Inspect or run the public ACP stdio server"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["status"] -> status()
      ["stdio"] -> Server.serve_stdio()
      _other -> usage()
    end
  end

  defp status do
    Mix.shell().info("acp_server.enabled=#{setting_enabled?("acp_server.enabled")}")
    Mix.shell().info("acp_stdio.enabled=#{setting_enabled?("acp_server.stdio.enabled")}")
    Mix.shell().info("acp_protocol_version=#{Mapping.protocol_version()}")
    Mix.shell().info("acp_transport=stdio_jsonrpc_ndjson")
    Mix.shell().info("acp_prompt_capabilities=text_only")
  end

  defp setting_enabled?(key) do
    case Settings.get(key) do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp usage do
    Mix.raise("""
    Usage:
      mix allbert.acp_server status
      mix allbert.acp_server stdio
    """)
  end
end
