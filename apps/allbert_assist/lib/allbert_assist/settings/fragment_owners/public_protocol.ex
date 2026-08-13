defmodule AllbertAssist.Settings.FragmentOwners.PublicProtocol do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "public_protocol.max_body_bytes" => %{
      default: 1_048_576,
      max: 10_485_760,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "public_protocol.result_readback_sweep_interval_ms" => %{
      default: 60_000,
      max: 86_400_000,
      min: 1000,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "public_protocol.result_readback_ttl_ms" => %{
      default: 3_600_000,
      max: 86_400_000,
      min: 60_000,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "public_protocol.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "public_protocol" => %{
      "max_body_bytes" => 1_048_576,
      "result_readback_sweep_interval_ms" => 60_000,
      "result_readback_ttl_ms" => 3_600_000,
      "schema_version" => 1
    }
  }
  @safe_write_keys [
    "public_protocol.schema_version",
    "public_protocol.result_readback_ttl_ms",
    "public_protocol.result_readback_sweep_interval_ms",
    "public_protocol.max_body_bytes"
  ]
  @safe_write_rows [
    {216, "public_protocol.schema_version"},
    {217, "public_protocol.result_readback_ttl_ms"},
    {218, "public_protocol.result_readback_sweep_interval_ms"},
    {219, "public_protocol.max_body_bytes"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:public_protocol",
      owner: "public_protocol",
      source: :core,
      group: "public_protocol",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Public Protocol"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
