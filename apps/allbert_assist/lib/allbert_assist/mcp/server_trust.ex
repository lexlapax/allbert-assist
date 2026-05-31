defmodule AllbertAssist.Mcp.ServerTrust do
  @moduledoc """
  Durable trust baseline for operator-approved discovered MCP servers.
  """

  alias AllbertAssist.Mcp.ServerTrustRecord
  alias AllbertAssist.Repo

  @doc "Insert or refresh the trust baseline for a configured MCP server."
  def upsert(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:trust_status, "trusted")
      |> put_default_baseline_attrs()
      |> json_safe_attrs([:manifest, :evaluation_report, :metadata])

    case Repo.get(ServerTrustRecord, Map.fetch!(attrs, :server_id)) do
      nil ->
        %ServerTrustRecord{}
        |> ServerTrustRecord.changeset(attrs)
        |> Repo.insert()

      %ServerTrustRecord{} = record ->
        record
        |> ServerTrustRecord.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Fetch an approved trust baseline by configured server id."
  def get(server_id) when is_binary(server_id) do
    case Repo.get(ServerTrustRecord, server_id) do
      %ServerTrustRecord{} = record -> {:ok, record}
      nil -> {:error, :not_found}
    end
  end

  def get(_server_id), do: {:error, :not_found}

  @doc "Capture the first live tool-list baseline for a pending trust record."
  def capture_live_baseline(server_id, connected_tool_definition_hash, metadata \\ %{})
      when is_binary(server_id) and is_binary(connected_tool_definition_hash) do
    with {:ok, %ServerTrustRecord{} = record} <- get(server_id) do
      attrs = %{
        connected_tool_definition_hash: connected_tool_definition_hash,
        baseline_status: "live_captured",
        metadata: Map.merge(record.metadata || %{}, json_safe(metadata))
      }

      record
      |> ServerTrustRecord.changeset(attrs)
      |> Repo.update()
    end
  end

  def to_map(%ServerTrustRecord{} = record) do
    %{
      server_id: record.server_id,
      candidate_id: record.candidate_id,
      tool_definition_hash: record.tool_definition_hash,
      manifest_definition_hash: record.manifest_definition_hash,
      connected_tool_definition_hash: record.connected_tool_definition_hash,
      baseline_status: record.baseline_status,
      trust_status: record.trust_status,
      transport: record.transport,
      endpoint_fingerprint: record.endpoint_fingerprint,
      connected_at: datetime_to_iso(record.connected_at),
      connected_by: record.connected_by,
      metadata: record.metadata || %{}
    }
  end

  defp put_default_baseline_attrs(attrs) do
    manifest_hash =
      Map.get(attrs, :manifest_definition_hash) || Map.get(attrs, :tool_definition_hash)

    attrs
    |> Map.put_new(:manifest_definition_hash, manifest_hash)
    |> Map.put_new(:baseline_status, default_baseline_status(attrs))
  end

  defp default_baseline_status(attrs) do
    if Map.get(attrs, :connected_tool_definition_hash) in [nil, ""] do
      "pending_live_verification"
    else
      "live_captured"
    end
  end

  defp json_safe_attrs(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &json_safe/1), else: acc
    end)
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {to_string(key), json_safe(child)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value), do: value

  defp datetime_to_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_to_iso(value), do: value
end
