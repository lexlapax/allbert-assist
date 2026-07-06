defmodule AllbertAssist.CLI.Areas.Mcp do
  @moduledoc """
  Release-safe `mcp` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.mcp` and `allbert admin mcp`:
  `dispatch/2` parses the sub-argv, routes to the same registered actions the
  Mix task used, and returns `{rendered_output, exit_code}` — no `Mix.*` calls,
  so it runs inside the packaged release. `Mix.Tasks.Allbert.Mcp` is a thin
  wrapper that prints the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.Discovery.Scan

  @usage """
  Usage:
    allbert admin mcp doctor SERVER [--no-discovery]
    allbert admin mcp tools SERVER
    allbert admin mcp resources SERVER
    allbert admin mcp read SERVER URI
    allbert admin mcp call SERVER TOOL JSON
    allbert admin mcp discover QUERY [--limit N]
    allbert admin mcp connect CANDIDATE_ID_OR_UNIQUE_NAME [--server-id SERVER] [--enable]
    allbert admin mcp connect --candidate-id CANDIDATE_ID [--server-id SERVER] [--enable]
    allbert admin mcp scan enable|pause|resume|run-once [QUERY]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin mcp")

  defp route(["discover" | args], ctx) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [limit: :integer])

    with :ok <- check_invalid(invalid),
         {:ok, query} <-
           nonempty_query(rest, "Usage: allbert admin mcp discover QUERY [--limit N]") do
      completed_action("find_mcp_tools", %{query: query, limit: opts[:limit]}, ctx)
    end
  end

  defp route(["connect" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [server_id: :string, enable: :boolean, candidate_id: :string]
      )

    with :ok <- check_invalid(invalid),
         {:ok, candidate_id} <- connect_candidate_id(opts, rest) do
      params =
        %{candidate_id: candidate_id}
        |> maybe_put(:server_id, opts[:server_id])
        |> maybe_put(:enable_on_connect, if(opts[:enable], do: true))

      action_result("mcp_server_connect", params, ctx)
    end
  end

  defp route(["scan", command | args], _ctx) when command in ["enable", "pause", "resume"] do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string])

    with :ok <- check_invalid(invalid),
         :ok <- check_rest(rest) do
      command
      |> scan_lifecycle(%{user_id: opts[:user] || "local"})
      |> case do
        {:ok, job} -> {:ok, {:scan_job, command, job}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp route(["scan", "run-once" | args], _ctx) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string])

    with :ok <- check_invalid(invalid) do
      query = rest |> Enum.join(" ") |> String.trim()

      case Scan.run_once(query, user_id: opts[:user] || "local") do
        {:ok, result} -> {:ok, {:scan_run, result}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp route(["doctor", server_id | args], ctx) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [no_discovery: :boolean])

    with :ok <- check_invalid(invalid),
         :ok <- check_rest(rest) do
      completed_action(
        "mcp_doctor_server",
        %{server_id: server_id, include_discovery: not Keyword.get(opts, :no_discovery, false)},
        ctx
      )
    end
  end

  defp route(["tools", server_id], ctx) do
    completed_action("mcp_list_tools", %{server_id: server_id}, ctx)
  end

  defp route(["resources", server_id], ctx) do
    completed_action("mcp_list_resources", %{server_id: server_id}, ctx)
  end

  defp route(["read", server_id, uri], ctx) do
    action_result("mcp_read_resource", %{server_id: server_id, uri: uri}, ctx)
  end

  defp route(["call", server_id, tool, json], ctx) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        action_result(
          "mcp_call_tool",
          %{server_id: server_id, tool_name: tool, arguments: decoded},
          ctx
        )

      {:ok, _decoded} ->
        {:error, {:raise, "MCP tool call arguments must be a JSON object."}}

      {:error, reason} ->
        {:error, {:raise, "Invalid MCP tool JSON: #{Exception.message(reason)}"}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, %{doctor: doctor} = response}) do
    Render.ok(
      [
        response.message,
        "transport_kind=#{doctor.transport_kind}",
        "endpoint_kind=#{doctor.endpoint_kind}",
        "credential_ok=#{inspect(doctor.credential_ok)}",
        "endpoint_ok=#{doctor.endpoint_ok}",
        "tools_listable=#{doctor.tools_listable}",
        "resources_listable=#{doctor.resources_listable}",
        "tool_count=#{doctor.tool_count}",
        "resource_count=#{doctor.resource_count}",
        "redacted_host=#{doctor.redacted_host}"
      ] ++
        Enum.map(doctor.diagnostics, fn diagnostic ->
          "diagnostic=#{diagnostic.code}: #{diagnostic.message}"
        end)
    )
  end

  defp render({:ok, %{candidates: candidates} = response}) do
    Render.ok(
      [response.message] ++
        Enum.map(candidates, fn candidate ->
          "- #{Map.get(candidate, :id)} #{Map.get(candidate, :name)} usable_now=#{Map.get(candidate, :usable_now?)} requires=#{Map.get(candidate, :requires)}"
        end) ++
        Enum.map(Map.get(response, :diagnostics, []), fn diagnostic ->
          "diagnostic=#{inspect(diagnostic)}"
        end)
    )
  end

  defp render({:ok, %{tools: tools}}) do
    Render.ok(
      Enum.map(tools, fn tool ->
        "- #{Map.get(tool, "name")}: #{Map.get(tool, "description")}"
      end)
    )
  end

  defp render({:ok, %{resources: resources}}) do
    Render.ok(
      Enum.map(resources, fn resource ->
        "- #{Map.get(resource, "uri")}: #{Map.get(resource, "name")}"
      end)
    )
  end

  defp render({:ok, %{resource: %{contents: contents} = resource}}) do
    Render.ok(
      ["resource_uri=#{Map.get(resource, :resource_uri)}"] ++
        Enum.flat_map(contents, fn content ->
          ["- #{Map.get(content, "uri")}: #{Map.get(content, "mimeType")}"] ++
            if Map.get(content, "text_preview") do
              [Map.get(content, "text_preview")]
            else
              []
            end
        end)
    )
  end

  defp render({:ok, %{status: :needs_confirmation, confirmation_id: confirmation_id} = response}) do
    Render.ok([response.message, "confirmation_id=#{confirmation_id}"])
  end

  defp render({:ok, %{connection: connection} = response}) do
    Render.ok([
      response.message,
      "server_id=#{Map.get(connection, :server_id)}",
      "candidate_id=#{Map.get(connection, :candidate_id)}",
      "enabled=#{inspect(Map.get(connection, :enabled))}"
    ])
  end

  defp render({:ok, {:scan_job, command, job}}) do
    Render.ok("Scan #{command}: #{job.id} status=#{job.status} schedule=#{inspect(job.schedule)}")
  end

  defp render({:ok, {:scan_run, %{job: job, run: run, response: response}}}) do
    header = "Scan run: job=#{job.id} run=#{run.id} status=#{run.status}"

    if response do
      {rendered, _code} = render({:ok, response})
      Render.ok([header, rendered])
    else
      Render.ok(header)
    end
  end

  defp render({:ok, %{tool_call: tool_call}}) do
    Render.ok([
      "tool=#{Map.get(tool_call, :tool_name)}",
      "result_keys=#{Enum.join(Map.get(tool_call, :result_keys, []), ",")}"
    ])
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, {:raise, message}}), do: Render.error(message)
  defp render({:error, reason}), do: Render.error("MCP command failed: #{inspect(reason)}")

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  defp action_result(action_name, params, ctx) do
    case Runner.run(action_name, params, ctx) do
      {:ok, response} -> {:ok, response}
    end
  end

  defp connect_candidate_id(opts, rest) do
    case {opts[:candidate_id], rest} do
      {candidate_id, []} when is_binary(candidate_id) and candidate_id != "" ->
        {:ok, candidate_id}

      {nil, [_head | _tail]} ->
        rest
        |> Enum.join(" ")
        |> String.trim()
        |> resolve_candidate_ref()

      {nil, []} ->
        {:usage,
         "Usage: allbert admin mcp connect CANDIDATE_ID_OR_UNIQUE_NAME [--server-id SERVER] [--enable]"}

      {_candidate_id, [_head | _tail]} ->
        {:error, {:raise, "Use either --candidate-id or a bare candidate id/name, not both."}}
    end
  end

  defp resolve_candidate_ref(ref) do
    case Discovery.get_candidate(ref) do
      {:ok, _candidate} ->
        {:ok, ref}

      {:error, :not_found} ->
        resolve_candidate_name(ref)
    end
  end

  defp resolve_candidate_name(name) do
    {:ok, candidates} = Discovery.list_candidates(source: :remote_mcp, limit: 500)

    candidates
    |> Enum.filter(&(&1.name == name))
    |> case do
      [candidate] ->
        {:ok, candidate.id}

      [] ->
        {:error, {:candidate_not_found, name}}

      matches ->
        {:error, {:ambiguous_candidate_name, name, Enum.map(matches, & &1.id)}}
    end
  end

  defp scan_lifecycle("enable", opts), do: Scan.enable(opts)
  defp scan_lifecycle("pause", opts), do: Scan.pause(opts)
  defp scan_lifecycle("resume", opts), do: Scan.resume(opts)

  defp nonempty_query(rest, usage) do
    query = rest |> Enum.join(" ") |> String.trim()
    if query == "", do: {:usage, usage}, else: {:ok, query}
  end

  defp check_invalid([]), do: :ok
  defp check_invalid(invalid), do: {:error, {:raise, "Invalid option(s): #{inspect(invalid)}"}}

  defp check_rest([]), do: :ok

  defp check_rest(rest),
    do: {:error, {:raise, "Unexpected argument(s): #{Enum.join(rest, " ")}"}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
