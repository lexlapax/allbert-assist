defmodule AllbertAssist.Settings.FragmentOwners.AcpServer do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "acp_server.enabled" => %{default: false, sensitive?: false, type: :boolean, writable?: true},
    "acp_server.memory_namespaces_enabled" => %{
      default: [],
      sensitive?: false,
      type: :public_memory_namespace_list,
      writable?: true
    },
    "acp_server.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "acp_server.session.additional_directories_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "acp_server.session.load_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "acp_server.session.resume_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "acp_server.stdio.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "acp_server.tools_enabled" => %{
      default: [],
      sensitive?: false,
      type: :public_tool_list,
      writable?: true
    }
  }
  @defaults %{
    "acp_server" => %{
      "enabled" => false,
      "memory_namespaces_enabled" => [],
      "schema_version" => 1,
      "session" => %{
        "additional_directories_enabled" => false,
        "load_enabled" => false,
        "resume_enabled" => false
      },
      "stdio" => %{"enabled" => false},
      "tools_enabled" => []
    }
  }
  @safe_write_keys [
    "acp_server.schema_version",
    "acp_server.enabled",
    "acp_server.stdio.enabled",
    "acp_server.tools_enabled",
    "acp_server.memory_namespaces_enabled",
    "acp_server.session.load_enabled",
    "acp_server.session.resume_enabled",
    "acp_server.session.additional_directories_enabled"
  ]
  @safe_write_rows [
    {229, "acp_server.schema_version"},
    {230, "acp_server.enabled"},
    {231, "acp_server.stdio.enabled"},
    {232, "acp_server.tools_enabled"},
    {233, "acp_server.memory_namespaces_enabled"},
    {234, "acp_server.session.load_enabled"},
    {235, "acp_server.session.resume_enabled"},
    {236, "acp_server.session.additional_directories_enabled"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:acp_server",
      owner: "acp_server",
      source: :core,
      group: "acp_server",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Acp Server"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
