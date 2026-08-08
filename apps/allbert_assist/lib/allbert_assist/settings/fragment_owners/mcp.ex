defmodule AllbertAssist.Settings.FragmentOwners.Mcp do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "mcp.discovery.auto_connect" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: false
    },
    "mcp.discovery.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "mcp.discovery.registry_allowlist" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "mcp.discovery.registry_denylist" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "mcp.discovery.scan.max_results" => %{
      default: 25,
      max: 100,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "mcp.discovery.scan.schedule" => %{
      allowed_values: ["paused", "daily", "weekly"],
      default: "paused",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "mcp.discovery.sources.official.enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "mcp.discovery.sources.pulsemcp.api_key_ref" => %{
      default: nil,
      sensitive?: true,
      type: :mcp_secret_ref_or_nil,
      writable?: true
    },
    "mcp.discovery.sources.pulsemcp.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "mcp.discovery.sources.pulsemcp.tenant_ref" => %{
      default: nil,
      sensitive?: true,
      type: :mcp_secret_ref_or_nil,
      writable?: true
    },
    "mcp.stdio.allowed_launchers" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    }
  }
  @defaults %{
    "mcp" => %{
      "discovery" => %{
        "auto_connect" => false,
        "enabled" => false,
        "registry_allowlist" => [],
        "registry_denylist" => [],
        "scan" => %{"max_results" => 25, "schedule" => "paused"},
        "sources" => %{
          "official" => %{"enabled" => true},
          "pulsemcp" => %{"api_key_ref" => nil, "enabled" => false, "tenant_ref" => nil}
        }
      },
      "servers" => %{},
      "stdio" => %{"allowed_launchers" => []}
    }
  }
  @safe_write_keys [
    "mcp.stdio.allowed_launchers",
    "mcp.discovery.enabled",
    "mcp.discovery.sources.official.enabled",
    "mcp.discovery.sources.pulsemcp.enabled",
    "mcp.discovery.sources.pulsemcp.api_key_ref",
    "mcp.discovery.sources.pulsemcp.tenant_ref",
    "mcp.discovery.scan.schedule",
    "mcp.discovery.scan.max_results",
    "mcp.discovery.registry_allowlist",
    "mcp.discovery.registry_denylist",
    "mcp.servers.*.enabled",
    "mcp.servers.*.transport",
    "mcp.servers.*.command",
    "mcp.servers.*.args",
    "mcp.servers.*.env",
    "mcp.servers.*.base_url",
    "mcp.servers.*.headers",
    "mcp.servers.*.auth_ref",
    "mcp.servers.*.tool_allowlist",
    "mcp.servers.*.tool_denylist",
    "mcp.servers.*.confirmation"
  ]
  @safe_write_rows [
    {115, "mcp.stdio.allowed_launchers"},
    {116, "mcp.discovery.enabled"},
    {117, "mcp.discovery.sources.official.enabled"},
    {118, "mcp.discovery.sources.pulsemcp.enabled"},
    {119, "mcp.discovery.sources.pulsemcp.api_key_ref"},
    {120, "mcp.discovery.sources.pulsemcp.tenant_ref"},
    {121, "mcp.discovery.scan.schedule"},
    {122, "mcp.discovery.scan.max_results"},
    {123, "mcp.discovery.registry_allowlist"},
    {124, "mcp.discovery.registry_denylist"},
    {125, "mcp.servers.*.enabled"},
    {126, "mcp.servers.*.transport"},
    {127, "mcp.servers.*.command"},
    {128, "mcp.servers.*.args"},
    {129, "mcp.servers.*.env"},
    {130, "mcp.servers.*.base_url"},
    {131, "mcp.servers.*.headers"},
    {132, "mcp.servers.*.auth_ref"},
    {133, "mcp.servers.*.tool_allowlist"},
    {134, "mcp.servers.*.tool_denylist"},
    {135, "mcp.servers.*.confirmation"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:mcp",
      owner: "mcp",
      source: :core,
      group: "mcp",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Mcp"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
