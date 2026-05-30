defmodule AllbertAssist.Actions.Mcp.FetchServerManifest do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :tool_discovery,
    exposure: :internal,
    execution_mode: :mcp_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "mcp_fetch_server_manifest",
    description:
      "Fetch descriptive server manifest metadata for an inert MCP registry candidate.",
    category: "mcp",
    tags: ["mcp", "registry", "manifest", "internal"],
    schema: [
      candidate_id: [type: :string, required: false],
      provider: [type: :string, required: false],
      manifest_url: [type: :string, required: false],
      manifest: [type: :map, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      manifest: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Mcp.Registry.Official
  alias AllbertAssist.Mcp.Registry.PulseMcp
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Tools.Discovery

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:tool_discovery, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, manifest, metadata} <- manifest(params, context) do
      {:ok, completed(manifest, metadata, permission_decision)}
    else
      false -> {:ok, denied(params, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(params, permission_decision, reason)}
    end
  end

  defp manifest(params, context) do
    case field(params, :manifest) do
      manifest when is_map(manifest) -> {:ok, manifest, %{source: :params}}
      _other -> manifest_from_candidate_or_url(params, context)
    end
  end

  defp manifest_from_candidate_or_url(params, context) do
    case field(params, :candidate_id) do
      candidate_id when is_binary(candidate_id) and candidate_id != "" ->
        manifest_from_candidate(candidate_id, params, context)

      _candidate_id ->
        fetch_manifest(field(params, :provider), field(params, :manifest_url), params, context)
    end
  end

  defp manifest_from_candidate(candidate_id, params, context) do
    with {:ok, candidate} <- Discovery.get_candidate(candidate_id) do
      cond do
        map_size(candidate.registry_record || %{}) > 0 ->
          {:ok, candidate.registry_record,
           %{source: :candidate_record, candidate_id: candidate_id}}

        is_binary(candidate.manifest_url) ->
          fetch_manifest(candidate.provider, candidate.manifest_url, params, context)

        true ->
          {:error, :candidate_manifest_missing}
      end
    end
  end

  defp fetch_manifest(provider, manifest_url, params, context) when is_binary(manifest_url) do
    provider
    |> provider_module()
    |> case do
      {:ok, module} ->
        with {:ok, manifest} <-
               module.fetch_manifest(manifest_url, provider_opts(params, context)) do
          {:ok, manifest, %{source: module.provider_id(), manifest_url: manifest_url}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_manifest(_provider, _manifest_url, _params, _context),
    do: {:error, :missing_manifest_ref}

  defp provider_module("official"), do: {:ok, Official}
  defp provider_module(:official), do: {:ok, Official}
  defp provider_module("pulsemcp"), do: {:ok, PulseMcp}
  defp provider_module(:pulsemcp), do: {:ok, PulseMcp}
  defp provider_module(nil), do: {:error, :missing_provider}
  defp provider_module(provider), do: {:error, {:unknown_provider, provider}}

  defp completed(manifest, metadata, permission_decision) do
    %{
      message: "Fetched MCP server manifest metadata.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      manifest: manifest,
      actions: [
        action(:completed, permission_decision, metadata)
      ]
    }
  end

  defp denied(params, permission_decision, reason) do
    %{
      message: "MCP server manifest could not be fetched: #{inspect(reason)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      manifest: %{},
      error: reason,
      actions: [
        action(:denied, permission_decision, %{
          candidate_id: field(params, :candidate_id),
          manifest_url: field(params, :manifest_url),
          error: reason
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_fetch_server_manifest",
      status: status,
      permission: :tool_discovery,
      permission_decision: permission_decision,
      mcp_registry_metadata: metadata
    }
  end

  defp provider_opts(params, context) do
    case field(params, :provider_opts, %{}) do
      value when is_map(value) -> Map.put(value, :context, context)
      _value -> %{context: context}
    end
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
