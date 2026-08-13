defmodule AllbertAssist.Settings.FragmentOwners.Artifacts do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "artifacts.allowed_mime" => %{
      default: ["*/*"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "artifacts.allowed_types" => %{
      default: ["*"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "artifacts.dedup" => %{
      allowed_values: ["content_sha256"],
      default: "content_sha256",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "artifacts.enabled" => %{default: false, sensitive?: false, type: :boolean, writable?: true},
    "artifacts.gc.delete_orphans" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "artifacts.gc.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "artifacts.gc.mode" => %{
      allowed_values: ["on_demand"],
      default: "on_demand",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "artifacts.ingestion_timeout_ms" => %{
      default: 15_000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "artifacts.max_bytes" => %{
      default: 20_971_520,
      max: 104_857_600,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "artifacts.retention_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "artifacts.root" => %{
      default: "<ALLBERT_HOME>/artifacts",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "artifacts.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "artifacts.trace.redact_bytes" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "artifacts" => %{
      "allowed_mime" => ["*/*"],
      "allowed_types" => ["*"],
      "dedup" => "content_sha256",
      "enabled" => false,
      "gc" => %{"delete_orphans" => true, "enabled" => false, "mode" => "on_demand"},
      "ingestion_timeout_ms" => 15_000,
      "max_bytes" => 20_971_520,
      "retention_enabled" => false,
      "root" => "<ALLBERT_HOME>/artifacts",
      "schema_version" => 1,
      "trace" => %{"redact_bytes" => true}
    }
  }
  @safe_write_keys [
    "artifacts.enabled",
    "artifacts.root",
    "artifacts.retention_enabled",
    "artifacts.max_bytes",
    "artifacts.ingestion_timeout_ms",
    "artifacts.allowed_mime",
    "artifacts.allowed_types",
    "artifacts.gc.enabled",
    "artifacts.gc.delete_orphans",
    "artifacts.trace.redact_bytes"
  ]
  @safe_write_rows [
    {288, "artifacts.enabled"},
    {289, "artifacts.root"},
    {290, "artifacts.retention_enabled"},
    {291, "artifacts.max_bytes"},
    {292, "artifacts.ingestion_timeout_ms"},
    {293, "artifacts.allowed_mime"},
    {294, "artifacts.allowed_types"},
    {295, "artifacts.gc.enabled"},
    {296, "artifacts.gc.delete_orphans"},
    {297, "artifacts.trace.redact_bytes"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:artifacts",
      owner: "artifacts",
      source: :core,
      group: "artifacts",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Artifacts"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
