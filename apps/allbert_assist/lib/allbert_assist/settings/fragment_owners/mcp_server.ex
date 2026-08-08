defmodule AllbertAssist.Settings.FragmentOwners.McpServer do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "mcp_server.clients" => %{
      default: %{},
      sensitive?: true,
      surface: "mcp_http",
      type: :public_protocol_clients,
      writable?: true
    },
    "mcp_server.enabled" => %{default: false, sensitive?: false, type: :boolean, writable?: true},
    "mcp_server.memory_namespaces_enabled" => %{
      default: [],
      sensitive?: false,
      type: :public_memory_namespace_list,
      writable?: true
    },
    "mcp_server.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "mcp_server.stdio.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "mcp_server.streamable_http.bind_host" => %{
      default: "127.0.0.1",
      sensitive?: false,
      type: :loopback_bind_host,
      writable?: true
    },
    "mcp_server.streamable_http.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "mcp_server.streamable_http.port" => %{
      default: nil,
      sensitive?: false,
      type: :port_or_nil,
      writable?: true
    },
    "mcp_server.tools_enabled" => %{
      default: [],
      sensitive?: false,
      type: :public_tool_list,
      writable?: true
    }
  }
  @defaults %{
    "mcp_server" => %{
      "clients" => %{},
      "enabled" => false,
      "memory_namespaces_enabled" => [],
      "schema_version" => 1,
      "stdio" => %{"enabled" => false},
      "streamable_http" => %{"bind_host" => "127.0.0.1", "enabled" => false, "port" => nil},
      "tools_enabled" => []
    }
  }
  @safe_write_keys [
    "mcp_server.schema_version",
    "mcp_server.enabled",
    "mcp_server.stdio.enabled",
    "mcp_server.streamable_http.enabled",
    "mcp_server.streamable_http.bind_host",
    "mcp_server.streamable_http.port",
    "mcp_server.tools_enabled",
    "mcp_server.memory_namespaces_enabled",
    "mcp_server.clients",
    "mcp_server.clients.*.enabled",
    "mcp_server.clients.*.token_ref",
    "mcp_server.clients.*.rate_limit.limit",
    "mcp_server.clients.*.rate_limit.period_ms",
    "mcp_server.clients.*.rate_limit.burst"
  ]
  @safe_write_rows [
    {190, "mcp_server.schema_version"},
    {191, "mcp_server.enabled"},
    {192, "mcp_server.stdio.enabled"},
    {193, "mcp_server.streamable_http.enabled"},
    {194, "mcp_server.streamable_http.bind_host"},
    {195, "mcp_server.streamable_http.port"},
    {196, "mcp_server.tools_enabled"},
    {197, "mcp_server.memory_namespaces_enabled"},
    {198, "mcp_server.clients"},
    {199, "mcp_server.clients.*.enabled"},
    {200, "mcp_server.clients.*.token_ref"},
    {201, "mcp_server.clients.*.rate_limit.limit"},
    {202, "mcp_server.clients.*.rate_limit.period_ms"},
    {203, "mcp_server.clients.*.rate_limit.burst"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:mcp_server",
      owner: "mcp_server",
      source: :core,
      group: "mcp_server",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Mcp Server"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
