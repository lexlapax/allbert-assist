defmodule AllbertAssist.Settings.FragmentOwners.Sandbox do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "sandbox.elixir.backend" => %{
      allowed_values: ["auto", "apple_container", "docker", "podman_rootless", "docker_runsc"],
      default: "auto",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "sandbox.elixir.cpu_limit" => %{
      default: 1.0,
      max: 8.0,
      min: 0.25,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "sandbox.elixir.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "sandbox.elixir.image" => %{
      default: "allbert-elixir-otp:local",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "sandbox.elixir.memory_mb" => %{
      default: 1024,
      max: 8192,
      min: 128,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "sandbox.elixir.network" => %{
      allowed_values: ["none"],
      default: "none",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "sandbox.elixir.output_bytes" => %{
      default: 65_536,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "sandbox.elixir.timeout_ms" => %{
      default: 120_000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    }
  }
  @defaults %{
    "sandbox" => %{
      "elixir" => %{
        "backend" => "auto",
        "cpu_limit" => 1.0,
        "enabled" => false,
        "image" => "allbert-elixir-otp:local",
        "memory_mb" => 1024,
        "network" => "none",
        "output_bytes" => 65_536,
        "timeout_ms" => 120_000
      }
    }
  }
  @safe_write_keys [
    "sandbox.elixir.enabled",
    "sandbox.elixir.backend",
    "sandbox.elixir.image",
    "sandbox.elixir.network",
    "sandbox.elixir.cpu_limit",
    "sandbox.elixir.memory_mb",
    "sandbox.elixir.timeout_ms",
    "sandbox.elixir.output_bytes"
  ]
  @safe_write_rows [
    {349, "sandbox.elixir.enabled"},
    {350, "sandbox.elixir.backend"},
    {351, "sandbox.elixir.image"},
    {352, "sandbox.elixir.network"},
    {353, "sandbox.elixir.cpu_limit"},
    {354, "sandbox.elixir.memory_mb"},
    {355, "sandbox.elixir.timeout_ms"},
    {356, "sandbox.elixir.output_bytes"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:sandbox",
      owner: "sandbox",
      source: :core,
      group: "sandbox",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Sandbox"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
