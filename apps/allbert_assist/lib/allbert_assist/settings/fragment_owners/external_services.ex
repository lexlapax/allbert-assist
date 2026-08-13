defmodule AllbertAssist.Settings.FragmentOwners.ExternalServices do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "external_services.allow_redirects" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "external_services.allowed_hosts" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "external_services.allowed_methods" => %{
      default: ["GET", "HEAD"],
      sensitive?: false,
      type: :http_methods,
      writable?: true
    },
    "external_services.allowed_paths" => %{
      default: ["/"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "external_services.blocked_hosts" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "external_services.default_timeout_ms" => %{
      default: 5000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "external_services.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "external_services.max_redirects" => %{
      default: 0,
      sensitive?: false,
      type: :non_negative_integer,
      writable?: true
    },
    "external_services.max_response_bytes" => %{
      default: 1_048_576,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "external_services.max_timeout_ms" => %{
      default: 30_000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "external_services.profiles" => %{
      default: %{},
      sensitive?: false,
      type: :external_service_profiles,
      writable?: true
    },
    "external_services.redact_request_headers" => %{
      default: ["authorization", "cookie", "x-api-key"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "external_services.redact_response_headers" => %{
      default: ["set-cookie", "authorization"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "external_services.retry_policy" => %{
      allowed_values: ["none", "safe_idempotent"],
      default: "none",
      sensitive?: false,
      type: :enum,
      writable?: true
    }
  }
  @defaults %{
    "external_services" => %{
      "allow_redirects" => false,
      "allowed_hosts" => [],
      "allowed_methods" => ["GET", "HEAD"],
      "allowed_paths" => ["/"],
      "blocked_hosts" => [],
      "default_timeout_ms" => 5000,
      "enabled" => false,
      "max_redirects" => 0,
      "max_response_bytes" => 1_048_576,
      "max_timeout_ms" => 30_000,
      "profiles" => %{},
      "redact_request_headers" => ["authorization", "cookie", "x-api-key"],
      "redact_response_headers" => ["set-cookie", "authorization"],
      "retry_policy" => "none"
    }
  }
  @safe_write_keys [
    "external_services.enabled",
    "external_services.allowed_hosts",
    "external_services.blocked_hosts",
    "external_services.allowed_paths",
    "external_services.allowed_methods",
    "external_services.default_timeout_ms",
    "external_services.max_timeout_ms",
    "external_services.max_response_bytes",
    "external_services.allow_redirects",
    "external_services.max_redirects",
    "external_services.retry_policy",
    "external_services.redact_request_headers",
    "external_services.redact_response_headers",
    "external_services.profiles"
  ]
  @safe_write_rows [
    {324, "external_services.enabled"},
    {325, "external_services.allowed_hosts"},
    {326, "external_services.blocked_hosts"},
    {327, "external_services.allowed_paths"},
    {328, "external_services.allowed_methods"},
    {329, "external_services.default_timeout_ms"},
    {330, "external_services.max_timeout_ms"},
    {331, "external_services.max_response_bytes"},
    {332, "external_services.allow_redirects"},
    {333, "external_services.max_redirects"},
    {334, "external_services.retry_policy"},
    {335, "external_services.redact_request_headers"},
    {336, "external_services.redact_response_headers"},
    {337, "external_services.profiles"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:external_services",
      owner: "external_services",
      source: :core,
      group: "external_services",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "External Services"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
