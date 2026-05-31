defmodule AllbertAssist.Mcp.Doctor do
  @moduledoc """
  Redacted ADR 0047-style doctor for configured MCP servers.
  """

  alias AllbertAssist.Mcp.Client
  alias AllbertAssist.Mcp.Diagnostics
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Mcp.ServerTrust
  alias AllbertAssist.Tools.Discovery

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
    |> put_trust_diagnostics(config, tools)
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

  defp put_trust_diagnostics(summary, config, {:ok, result}) do
    case server_trust_get(config.server_id) do
      {:ok, trust_record} ->
        tools = Map.get(result, :tools, [])
        current_hash = Discovery.tool_list_hash(tools)

        put_live_trust_diagnostics(summary, config, trust_record, current_hash)

      {:error, :not_found} ->
        summary

      {:error, _reason} ->
        summary
    end
  end

  defp put_trust_diagnostics(summary, _config, _tools), do: summary

  defp put_live_trust_diagnostics(summary, config, trust_record, current_hash) do
    baseline_hash = trust_record.connected_tool_definition_hash

    cond do
      trust_record.baseline_status == "pending_live_verification" or is_nil(baseline_hash) ->
        capture_pending_live_baseline(summary, config, trust_record, current_hash)

      current_hash == baseline_hash ->
        Map.merge(summary, %{
          trust_baseline_ok: true,
          trust_baseline_hash: baseline_hash,
          manifest_definition_hash: trust_record.manifest_definition_hash,
          current_tool_definition_hash: current_hash,
          baseline_status: trust_record.baseline_status
        })

      true ->
        summary
        |> Map.merge(%{
          trust_baseline_ok: false,
          trust_baseline_hash: baseline_hash,
          manifest_definition_hash: trust_record.manifest_definition_hash,
          current_tool_definition_hash: current_hash,
          baseline_status: trust_record.baseline_status
        })
        |> Map.update!(:diagnostics, &[Diagnostics.new(:tool_definition_changed) | &1])
    end
  end

  defp capture_pending_live_baseline(summary, config, trust_record, current_hash) do
    case ServerTrust.capture_live_baseline(config.server_id, current_hash, %{
           baseline_captured_from: "first_doctor",
           prior_baseline_status: trust_record.baseline_status
         }) do
      {:ok, record} ->
        summary
        |> Map.merge(%{
          trust_baseline_ok: true,
          trust_baseline_hash: record.connected_tool_definition_hash,
          manifest_definition_hash: record.manifest_definition_hash,
          current_tool_definition_hash: current_hash,
          baseline_status: record.baseline_status
        })
        |> Map.update!(
          :diagnostics,
          &[
            Diagnostics.new(:baseline_captured_from_first_doctor) | &1
          ]
        )

      {:error, _reason} ->
        Map.merge(summary, %{
          trust_baseline_ok: nil,
          trust_baseline_hash: nil,
          manifest_definition_hash: trust_record.manifest_definition_hash,
          current_tool_definition_hash: current_hash,
          baseline_status: trust_record.baseline_status
        })
    end
  end

  defp server_trust_get(server_id) do
    ServerTrust.get(server_id)
  rescue
    _error in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
      {:error, :trust_store_unavailable}
  end

  defp diagnostic({_tag, %{} = diagnostic}), do: diagnostic
  defp diagnostic({:endpoint_denied, _reason, %{} = diagnostic}), do: diagnostic
  defp diagnostic({:json_rpc_error, _error}), do: Diagnostics.new(:protocol_error)
  defp diagnostic(_reason), do: Diagnostics.new(:protocol_error)
end
