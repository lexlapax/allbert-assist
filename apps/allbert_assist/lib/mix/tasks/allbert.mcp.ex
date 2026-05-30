defmodule Mix.Tasks.Allbert.Mcp do
  @moduledoc """
  Inspect configured MCP servers.

  ## Usage

      mix allbert.mcp discover QUERY [--limit N]
      mix allbert.mcp connect CANDIDATE_ID [--server-id SERVER] [--enable]
      mix allbert.mcp scan enable|pause|resume|run-once [QUERY]
      mix allbert.mcp doctor SERVER [--no-discovery]
      mix allbert.mcp tools SERVER
      mix allbert.mcp resources SERVER
      mix allbert.mcp read SERVER URI
      mix allbert.mcp call SERVER TOOL JSON
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Tools.Discovery.Scan

  @shortdoc "Inspect configured MCP servers"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["discover" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [limit: :integer])

    reject_invalid!(invalid)

    query = rest |> Enum.join(" ") |> String.trim()

    if query == "" do
      Mix.raise("Usage: mix allbert.mcp discover QUERY [--limit N]")
    end

    completed_action("find_mcp_tools", %{query: query, limit: opts[:limit]})
  end

  defp dispatch(["connect", candidate_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [server_id: :string, enable: :boolean])

    reject_invalid!(invalid)
    reject_rest!(rest)

    params =
      %{candidate_id: candidate_id}
      |> maybe_put(:server_id, opts[:server_id])
      |> maybe_put(:enable_on_connect, if(opts[:enable], do: true))

    action_result("mcp_server_connect", params)
  end

  defp dispatch(["scan", command | args]) when command in ["enable", "pause", "resume"] do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string])

    reject_invalid!(invalid)
    reject_rest!(rest)

    command
    |> scan_lifecycle(%{user_id: opts[:user] || "local"})
    |> case do
      {:ok, job} -> {:ok, {:scan_job, command, job}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(["scan", "run-once" | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string])

    reject_invalid!(invalid)

    query = rest |> Enum.join(" ") |> String.trim()

    case Scan.run_once(query, user_id: opts[:user] || "local") do
      {:ok, result} -> {:ok, {:scan_run, result}}
      {:error, reason} -> {:error, reason}
    end
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

  defp dispatch(["read", server_id, uri]) do
    action_result("mcp_read_resource", %{server_id: server_id, uri: uri})
  end

  defp dispatch(["call", server_id, tool, json]) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        action_result("mcp_call_tool", %{
          server_id: server_id,
          tool_name: tool,
          arguments: decoded
        })

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
      mix allbert.mcp discover QUERY [--limit N]
      mix allbert.mcp connect CANDIDATE_ID [--server-id SERVER] [--enable]
      mix allbert.mcp scan enable|pause|resume|run-once [QUERY]
    """)
  end

  defp scan_lifecycle("enable", opts), do: Scan.enable(opts)
  defp scan_lifecycle("pause", opts), do: Scan.pause(opts)
  defp scan_lifecycle("resume", opts), do: Scan.resume(opts)

  defp completed_action(action_name, params) do
    case action_result(action_name, params) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp action_result(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, response} -> {:ok, response}
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

  defp print_result({:ok, %{candidates: candidates} = response}) do
    Mix.shell().info(response.message)

    Enum.each(candidates, fn candidate ->
      Mix.shell().info(
        "- #{Map.get(candidate, :id)} #{Map.get(candidate, :name)} usable_now=#{Map.get(candidate, :usable_now?)} requires=#{Map.get(candidate, :requires)}"
      )
    end)

    Enum.each(Map.get(response, :diagnostics, []), fn diagnostic ->
      Mix.shell().info("diagnostic=#{inspect(diagnostic)}")
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

  defp print_result({:ok, %{resource: %{contents: contents} = resource}}) do
    Mix.shell().info("resource_uri=#{Map.get(resource, :resource_uri)}")

    Enum.each(contents, fn content ->
      Mix.shell().info("- #{Map.get(content, "uri")}: #{Map.get(content, "mimeType")}")

      if Map.get(content, "text_preview") do
        Mix.shell().info(Map.get(content, "text_preview"))
      end
    end)
  end

  defp print_result(
         {:ok, %{status: :needs_confirmation, confirmation_id: confirmation_id} = response}
       ) do
    Mix.shell().info(response.message)
    Mix.shell().info("confirmation_id=#{confirmation_id}")
  end

  defp print_result({:ok, %{connection: connection} = response}) do
    Mix.shell().info(response.message)
    Mix.shell().info("server_id=#{Map.get(connection, :server_id)}")
    Mix.shell().info("candidate_id=#{Map.get(connection, :candidate_id)}")
    Mix.shell().info("enabled=#{inspect(Map.get(connection, :enabled))}")
  end

  defp print_result({:ok, {:scan_job, command, job}}) do
    Mix.shell().info(
      "Scan #{command}: #{job.id} status=#{job.status} schedule=#{inspect(job.schedule)}"
    )
  end

  defp print_result({:ok, {:scan_run, %{job: job, run: run, response: response}}}) do
    Mix.shell().info("Scan run: job=#{job.id} run=#{run.id} status=#{run.status}")

    if response do
      print_result({:ok, response})
    end
  end

  defp print_result({:ok, %{tool_call: tool_call}}) do
    Mix.shell().info("tool=#{Map.get(tool_call, :tool_name)}")
    Mix.shell().info("result_keys=#{Enum.join(Map.get(tool_call, :result_keys, []), ",")}")
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
