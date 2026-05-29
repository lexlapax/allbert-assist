defmodule AllbertAssist.Mcp.Doctor do
  @moduledoc """
  Redacted ADR 0047-style doctor for configured MCP servers.
  """

  alias AllbertAssist.Mcp.Client
  alias AllbertAssist.Mcp.Diagnostics
  alias AllbertAssist.Mcp.ServerConfig

  @spec diagnose(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def diagnose(server_id, context \\ %{}, opts \\ []) do
    include_discovery? = Keyword.get(opts, :include_discovery, true)

    with {:ok, config} <- ServerConfig.resolve(server_id) do
      {:ok, diagnose_config(config, context, include_discovery?)}
    end
  end

  defp diagnose_config(%ServerConfig{enabled?: false} = config, _context, _include_discovery?) do
    base_summary(config,
      endpoint_ok: false,
      credential_ok: credential_ok(config),
      tools_listable: false,
      resources_listable: false,
      diagnostics: [Diagnostics.new(:server_disabled)]
    )
  end

  defp diagnose_config(%ServerConfig{} = config, context, false) do
    case Client.initialize(config, context) do
      {:ok, init} ->
        base_summary(config,
          endpoint_ok: true,
          credential_ok: credential_ok(config),
          protocol_version: protocol_version(init),
          diagnostics: []
        )

      {:error, reason} ->
        failed_summary(config, reason)
    end
  end

  defp diagnose_config(%ServerConfig{} = config, context, true) do
    init_summary = diagnose_config(config, context, false)

    if init_summary.endpoint_ok do
      discovery_summary(config, context, init_summary)
    else
      init_summary
    end
  end

  defp discovery_summary(config, context, summary) do
    tools = Client.list_tools(config, context)
    resources = Client.list_resources(config, context)

    summary
    |> Map.merge(%{
      tools_listable: match?({:ok, _result}, tools),
      resources_listable: match?({:ok, _result}, resources),
      tool_count: count_result(tools, :tools),
      resource_count: count_result(resources, :resources)
    })
    |> maybe_put_discovery_diagnostic(tools, resources)
  end

  defp failed_summary(config, reason) do
    base_summary(config,
      endpoint_ok: false,
      credential_ok: credential_ok(config),
      diagnostics: [diagnostic(reason)]
    )
  end

  defp base_summary(config, attrs) do
    Map.merge(
      %{
        server_id: config.server_id,
        endpoint_kind: endpoint_kind(config),
        credential_ok: credential_ok(config),
        endpoint_ok: false,
        redacted_host: ServerConfig.redacted_host(config),
        transport_kind: config.transport,
        tools_listable: false,
        resources_listable: false,
        tool_count: :unknown,
        resource_count: :unknown,
        protocol_version: nil,
        diagnostics: []
      },
      Map.new(attrs)
    )
  end

  defp endpoint_kind(%ServerConfig{transport: :stdio}), do: :local_endpoint
  defp endpoint_kind(_config), do: :credentialed_remote

  defp credential_ok(%ServerConfig{transport: :stdio}), do: nil
  defp credential_ok(%ServerConfig{credential_status: :missing}), do: false
  defp credential_ok(_config), do: true

  defp protocol_version(result), do: Map.get(result, "protocolVersion")

  defp count_result({:ok, result}, key) do
    result
    |> Map.get(key, [])
    |> length()
  end

  defp count_result(_result, _key), do: :unknown

  defp maybe_put_discovery_diagnostic(summary, {:ok, _tools}, {:ok, _resources}), do: summary

  defp maybe_put_discovery_diagnostic(summary, _tools, _resources) do
    Map.update!(summary, :diagnostics, &[Diagnostics.new(:discovery_failed) | &1])
  end

  defp diagnostic({_tag, %{} = diagnostic}), do: diagnostic
  defp diagnostic({:endpoint_denied, _reason, %{} = diagnostic}), do: diagnostic
  defp diagnostic({:json_rpc_error, _error}), do: Diagnostics.new(:protocol_error)
  defp diagnostic(_reason), do: Diagnostics.new(:protocol_error)
end
