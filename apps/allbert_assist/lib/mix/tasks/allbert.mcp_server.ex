defmodule Mix.Tasks.Allbert.McpServer do
  @moduledoc """
  Inspect or run the v0.51 public MCP server.

      mix allbert.mcp_server status
      mix allbert.mcp_server tools list
      mix allbert.mcp_server resources list
      mix allbert.mcp_server stdio
  """

  use Mix.Task

  alias AllbertAssist.PublicProtocol.Mcp.ProtocolVersions
  alias AllbertAssist.PublicProtocol.Mcp.Runtime
  alias AllbertAssist.PublicProtocol.Mcp.Server
  alias AllbertAssist.Settings

  @shortdoc "Inspect or run the public MCP server"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["status"] -> status()
      ["tools", "list"] -> list_tools()
      ["resources", "list"] -> list_resources()
      ["stdio"] -> stdio()
      _other -> usage()
    end
  end

  defp status do
    Mix.shell().info("mcp_server.enabled=#{setting_enabled?("mcp_server.enabled")}")
    Mix.shell().info("mcp_stdio.enabled=#{setting_enabled?("mcp_server.stdio.enabled")}")
    Mix.shell().info("mcp_protocol_versions=#{Enum.join(ProtocolVersions.supported(), ",")}")
    Mix.shell().info("mcp_http_transport=allbert_owned_ingress_only")

    Mix.shell().info("tools=#{count(:tools)}")
    Mix.shell().info("resources=#{count(:resources)}")
  end

  defp list_tools do
    case Runtime.enabled_tools() do
      {:ok, tools} ->
        Enum.each(tools, fn tool ->
          Mix.shell().info("#{tool.name}\t#{tool.module.description()}")
        end)

      {:error, reason} ->
        Mix.raise("Could not list MCP tools: #{inspect(reason)}")
    end
  end

  defp list_resources do
    case Runtime.enabled_resources() do
      {:ok, resources} ->
        Enum.each(resources, fn resource ->
          Mix.shell().info("#{resource.uri}\t#{resource.name}\t#{resource.description}")
        end)

      {:error, reason} ->
        Mix.raise("Could not list MCP resources: #{inspect(reason)}")
    end
  end

  defp stdio do
    ensure_hermes_registry!()

    case Hermes.Server.Supervisor.start_link(Server, transport: :stdio) do
      {:ok, _pid} ->
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("Could not start MCP stdio server: #{inspect(reason)}")
    end
  end

  defp count(:tools) do
    case Runtime.enabled_tools() do
      {:ok, tools} -> length(tools)
      {:error, _reason} -> 0
    end
  end

  defp count(:resources) do
    case Runtime.enabled_resources() do
      {:ok, resources} -> length(resources)
      {:error, _reason} -> 0
    end
  end

  defp setting_enabled?(key) do
    case Settings.get(key) do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp ensure_hermes_registry! do
    case Process.whereis(Hermes.Server.Registry) do
      nil ->
        {:ok, _pid} = Supervisor.start_link([Hermes.Server.Registry], strategy: :one_for_one)
        :ok

      _pid ->
        :ok
    end
  end

  @spec usage() :: no_return()
  defp usage do
    Mix.raise("""
    Usage:
      mix allbert.mcp_server status
      mix allbert.mcp_server tools list
      mix allbert.mcp_server resources list
      mix allbert.mcp_server stdio
    """)
  end
end
