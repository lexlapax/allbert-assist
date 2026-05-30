defmodule AllbertAssist.Mcp.Diagnostics do
  @moduledoc """
  Fixed, redacted diagnostic catalog for MCP doctor and discovery actions.
  """

  @catalog %{
    server_disabled: "MCP server is disabled.",
    server_not_configured: "MCP server is not configured.",
    invalid_server_config: "MCP server configuration is invalid.",
    credential_missing: "MCP credential is not configured.",
    credential_unavailable: "MCP credential could not be read.",
    endpoint_denied: "MCP endpoint is denied by external request policy.",
    endpoint_unreachable: "MCP endpoint did not respond.",
    endpoint_http_error: "MCP endpoint returned an HTTP error.",
    protocol_error: "MCP endpoint returned an invalid JSON-RPC response.",
    discovery_failed: "MCP discovery could not complete.",
    tool_definition_changed: "MCP tool definitions differ from the approved discovery baseline.",
    stdio_launcher_missing: "Configured MCP stdio launcher was not found.",
    stdio_start_failed: "Configured MCP stdio process could not start."
  }

  @spec new(atom()) :: %{code: atom(), message: String.t()}
  def new(code) when is_atom(code) do
    code = if Map.has_key?(@catalog, code), do: code, else: :protocol_error
    %{code: code, message: Map.fetch!(@catalog, code)}
  end

  def new(_code), do: new(:protocol_error)
end
