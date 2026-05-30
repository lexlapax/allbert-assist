defmodule AllbertAssist.Actions.Mcp.EvaluateServer do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :tool_discovery,
    exposure: :internal,
    execution_mode: :mcp_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "mcp_evaluate_server",
    description: "Evaluate inert MCP registry metadata for provenance, command risk, and health.",
    category: "mcp",
    tags: ["mcp", "registry", "evaluation", "internal"],
    schema: [
      candidate_id: [type: :string, required: false],
      provider: [type: :string, required: false],
      manifest: [type: :map, required: false],
      probe?: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      evaluation_report: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Tools.Discovery

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:tool_discovery, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, manifest, metadata} <- manifest(params),
         {:ok, report} <- evaluate(params, context, manifest, metadata),
         {:ok, report} <- maybe_persist_report(params, report) do
      {:ok, completed(report, metadata, permission_decision)}
    else
      false -> {:ok, denied(params, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(params, permission_decision, reason)}
    end
  end

  defp manifest(params) do
    case field(params, :manifest) do
      manifest when is_map(manifest) ->
        {:ok, manifest, %{source: :params}}

      _other ->
        manifest_from_candidate(field(params, :candidate_id))
    end
  end

  defp manifest_from_candidate(candidate_id)
       when is_binary(candidate_id) and candidate_id != "" do
    with {:ok, candidate} <- Discovery.get_candidate(candidate_id),
         true <- map_size(candidate.registry_record || %{}) > 0 do
      {:ok, candidate.registry_record,
       %{
         source: :candidate_record,
         candidate_id: candidate_id,
         provider: candidate.provider,
         remote_server_id: candidate.remote_server_id
       }}
    else
      false -> {:error, :candidate_manifest_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp manifest_from_candidate(_candidate_id), do: {:error, :missing_manifest}

  defp evaluate(params, context, manifest, metadata) do
    Discovery.evaluate_server(manifest, %{
      candidate_id: field(params, :candidate_id),
      provider: field(params, :provider) || metadata.provider || provider_from_manifest(manifest),
      remote_server_id: metadata.remote_server_id || server_id(manifest),
      context: context,
      probe?: field(params, :probe?, true)
    })
  end

  defp maybe_persist_report(params, report) do
    case field(params, :candidate_id) do
      candidate_id when is_binary(candidate_id) and candidate_id != "" ->
        with {:ok, record} <- Discovery.upsert_evaluation_report(candidate_id, report) do
          {:ok, Discovery.evaluation_to_map(record)}
        end

      _candidate_id ->
        {:ok, Discovery.evaluation_to_map(report)}
    end
  end

  defp completed(report, metadata, permission_decision) do
    %{
      message: "Evaluated MCP server metadata.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      evaluation_report: report,
      actions: [
        action(:completed, permission_decision, metadata)
      ]
    }
  end

  defp denied(params, permission_decision, reason) do
    %{
      message: "MCP server metadata could not be evaluated: #{inspect(reason)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      evaluation_report: %{},
      error: reason,
      actions: [
        action(:denied, permission_decision, %{
          candidate_id: field(params, :candidate_id),
          error: reason
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_evaluate_server",
      status: status,
      permission: :tool_discovery,
      permission_decision: permission_decision,
      mcp_registry_metadata: metadata
    }
  end

  defp provider_from_manifest(manifest) do
    field(manifest, :provider) ||
      get_in(manifest, ["registry", "provider"]) ||
      get_in(manifest, [:registry, :provider])
  end

  defp server_id(manifest), do: field(manifest, :name) || field(manifest, :id)

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
