defmodule Mix.Tasks.Allbert.Mcp do
  @moduledoc """
  Inspect configured MCP servers.

  ## Usage

      mix allbert.mcp doctor SERVER [--no-discovery]
      mix allbert.mcp tools SERVER
      mix allbert.mcp resources SERVER
      mix allbert.mcp read SERVER URI
      mix allbert.mcp call SERVER TOOL JSON
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect configured MCP servers"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["doctor", server_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [no_discovery: :boolean])

    reject_invalid!(invalid)
    reject_rest!(rest)

    completed_action("mcp_doctor_server", %{
      server_id: server_id,
      include_discovery: not Keyword.get(opts, :no_discovery, false)
    })
  end

  defp dispatch(["tools", server_id]) do
    completed_action("mcp_list_tools", %{server_id: server_id})
  end

  defp dispatch(["resources", server_id]) do
    completed_action("mcp_list_resources", %{server_id: server_id})
  end

  defp dispatch(["read", _server_id, _uri]) do
    Mix.raise("MCP resource reads are planned for v0.40 M3.")
  end

  defp dispatch(["call", _server_id, _tool, json]) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        Mix.raise("MCP tool calls are planned for v0.40 M4.")

      {:ok, _decoded} ->
        Mix.raise("MCP tool call arguments must be a JSON object.")

      {:error, reason} ->
        Mix.raise("Invalid MCP tool JSON: #{Exception.message(reason)}")
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.mcp doctor SERVER [--no-discovery]
      mix allbert.mcp tools SERVER
      mix allbert.mcp resources SERVER
      mix allbert.mcp read SERVER URI
      mix allbert.mcp call SERVER TOOL JSON
    """)
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp print_result({:ok, %{doctor: doctor} = response}) do
    Mix.shell().info(response.message)
    Mix.shell().info("transport_kind=#{doctor.transport_kind}")
    Mix.shell().info("endpoint_kind=#{doctor.endpoint_kind}")
    Mix.shell().info("credential_ok=#{inspect(doctor.credential_ok)}")
    Mix.shell().info("endpoint_ok=#{doctor.endpoint_ok}")
    Mix.shell().info("tools_listable=#{doctor.tools_listable}")
    Mix.shell().info("resources_listable=#{doctor.resources_listable}")
    Mix.shell().info("tool_count=#{doctor.tool_count}")
    Mix.shell().info("resource_count=#{doctor.resource_count}")
    Mix.shell().info("redacted_host=#{doctor.redacted_host}")

    Enum.each(doctor.diagnostics, fn diagnostic ->
      Mix.shell().info("diagnostic=#{diagnostic.code}: #{diagnostic.message}")
    end)
  end

  defp print_result({:ok, %{tools: tools}}) do
    Enum.each(tools, fn tool ->
      Mix.shell().info("- #{Map.get(tool, "name")}: #{Map.get(tool, "description")}")
    end)
  end

  defp print_result({:ok, %{resources: resources}}) do
    Enum.each(resources, fn resource ->
      Mix.shell().info("- #{Map.get(resource, "uri")}: #{Map.get(resource, "name")}")
    end)
  end

  defp print_result({:error, reason}) do
    Mix.raise("MCP command failed: #{inspect(reason)}")
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp context, do: %{actor: "local", channel: :cli}

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

  defp reject_rest!([]), do: :ok
  defp reject_rest!(rest), do: Mix.raise("Unexpected argument(s): #{Enum.join(rest, " ")}")
end
