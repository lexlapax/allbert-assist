defmodule AllbertAssist.Settings.FragmentOwners.Vision do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "vision.enabled" => %{default: false, sensitive?: false, type: :boolean, writable?: true},
    "vision.media.max_bytes" => %{
      default: 20_971_520,
      max: 104_857_600,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "vision.media.max_pixels" => %{
      default: 33_177_600,
      max: 536_870_912,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "vision.media.retention_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "vision.media.retention_root" => %{
      default: "<ALLBERT_HOME>/images",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "vision.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "vision.trace.redact_images" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "vision" => %{
      "enabled" => false,
      "media" => %{
        "max_bytes" => 20_971_520,
        "max_pixels" => 33_177_600,
        "retention_enabled" => false,
        "retention_root" => "<ALLBERT_HOME>/images"
      },
      "schema_version" => 1,
      "trace" => %{"redact_images" => true}
    }
  }
  @safe_write_keys [
    "vision.enabled",
    "vision.media.max_bytes",
    "vision.media.max_pixels",
    "vision.media.retention_enabled",
    "vision.media.retention_root",
    "vision.trace.redact_images"
  ]
  @safe_write_rows [
    {276, "vision.enabled"},
    {277, "vision.media.max_bytes"},
    {278, "vision.media.max_pixels"},
    {279, "vision.media.retention_enabled"},
    {280, "vision.media.retention_root"},
    {281, "vision.trace.redact_images"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:vision",
      owner: "vision",
      source: :core,
      group: "vision",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Vision"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
