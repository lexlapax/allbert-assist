defmodule AllbertAssist.Mcp.Audit do
  @moduledoc """
  Markdown audit records for MCP client interactions.
  """

  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Paths

  @type event :: :requested | :denied | :succeeded | :failed

  @spec audit_root() :: String.t()
  def audit_root, do: Paths.mcp_audit_root()

  @spec append(event(), ServerConfig.t() | map(), map(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def append(event, spec, permission_decision, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)

    File.mkdir_p!(Path.dirname(path))

    case File.write(path, render(event, spec, permission_decision, attrs, now), [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:mcp_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:mcp_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  @spec audit_path(DateTime.t()) :: String.t()
  def audit_path(now \\ DateTime.utc_now()) do
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  defp render(event, %ServerConfig{} = config, permission_decision, attrs, now) do
    render(event, ServerConfig.summary(config), permission_decision, attrs, now)
  end

  defp render(event, summary, permission_decision, attrs, now) when is_map(summary) do
    """

    ## #{DateTime.to_iso8601(now)} #{event}

    - event: #{event}
    - permission: #{Map.get(permission_decision, :permission, :read_only)}
    - decision: #{Map.get(permission_decision, :decision, "unknown")}
    - server_id: #{Map.get(summary, :server_id)}
    - transport: #{Map.get(summary, :transport)}
    - redacted_host: #{Map.get(summary, :redacted_host)}
    - action: #{Map.get(attrs, :action, "unknown")}
    - result_status: #{Map.get(attrs, :status, "unknown")}
    - tool_count: #{Map.get(attrs, :tool_count, "unknown")}
    - resource_count: #{Map.get(attrs, :resource_count, "unknown")}
    - diagnostic_codes: #{inspect(diagnostic_codes(attrs))}
    - audit_version: 1
    """
  end

  defp diagnostic_codes(attrs) do
    attrs
    |> Map.get(:diagnostics, [])
    |> Enum.map(&Map.get(&1, :code))
    |> Enum.reject(&is_nil/1)
  end
end
