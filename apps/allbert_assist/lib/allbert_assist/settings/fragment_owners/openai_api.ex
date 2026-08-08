defmodule AllbertAssist.Settings.FragmentOwners.OpenaiApi do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "openai_api.clients" => %{
      default: %{},
      sensitive?: true,
      surface: "openai_api",
      type: :public_protocol_clients,
      writable?: true
    },
    "openai_api.enabled" => %{default: false, sensitive?: false, type: :boolean, writable?: true},
    "openai_api.memory_namespaces_enabled" => %{
      default: [],
      sensitive?: false,
      type: :public_memory_namespace_list,
      writable?: true
    },
    "openai_api.models_enabled" => %{
      default: [],
      sensitive?: false,
      type: :profile_ref_list,
      writable?: true
    },
    "openai_api.path_prefix" => %{
      default: "/v1",
      sensitive?: false,
      type: :public_api_path_prefix,
      writable?: true
    },
    "openai_api.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "openai_api.tools_enabled" => %{
      default: [],
      sensitive?: false,
      type: :public_tool_list,
      writable?: true
    }
  }
  @defaults %{
    "openai_api" => %{
      "clients" => %{},
      "enabled" => false,
      "memory_namespaces_enabled" => [],
      "models_enabled" => [],
      "path_prefix" => "/v1",
      "schema_version" => 1,
      "tools_enabled" => []
    }
  }
  @safe_write_keys [
    "openai_api.schema_version",
    "openai_api.enabled",
    "openai_api.path_prefix",
    "openai_api.models_enabled",
    "openai_api.tools_enabled",
    "openai_api.memory_namespaces_enabled",
    "openai_api.clients",
    "openai_api.clients.*.enabled",
    "openai_api.clients.*.token_ref",
    "openai_api.clients.*.rate_limit.limit",
    "openai_api.clients.*.rate_limit.period_ms",
    "openai_api.clients.*.rate_limit.burst"
  ]
  @safe_write_rows [
    {204, "openai_api.schema_version"},
    {205, "openai_api.enabled"},
    {206, "openai_api.path_prefix"},
    {207, "openai_api.models_enabled"},
    {208, "openai_api.tools_enabled"},
    {209, "openai_api.memory_namespaces_enabled"},
    {210, "openai_api.clients"},
    {211, "openai_api.clients.*.enabled"},
    {212, "openai_api.clients.*.token_ref"},
    {213, "openai_api.clients.*.rate_limit.limit"},
    {214, "openai_api.clients.*.rate_limit.period_ms"},
    {215, "openai_api.clients.*.rate_limit.burst"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:openai_api",
      owner: "openai_api",
      source: :core,
      group: "openai_api",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Openai Api"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
