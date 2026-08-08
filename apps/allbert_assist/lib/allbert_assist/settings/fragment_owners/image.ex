defmodule AllbertAssist.Settings.FragmentOwners.Image do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "image.enabled" => %{default: false, sensitive?: false, type: :boolean, writable?: true},
    "image.generation.max_bytes" => %{
      default: 20_971_520,
      max: 104_857_600,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "image.generation.max_pixels" => %{
      default: 33_177_600,
      max: 536_870_912,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "image.generation.retention_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "image.generation.retention_root" => %{
      default: "<ALLBERT_HOME>/generated_images",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "image.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "image.trace.redact_images" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "image" => %{
      "enabled" => false,
      "generation" => %{
        "max_bytes" => 20_971_520,
        "max_pixels" => 33_177_600,
        "retention_enabled" => false,
        "retention_root" => "<ALLBERT_HOME>/generated_images"
      },
      "schema_version" => 1,
      "trace" => %{"redact_images" => true}
    }
  }
  @safe_write_keys [
    "image.enabled",
    "image.generation.max_bytes",
    "image.generation.max_pixels",
    "image.generation.retention_enabled",
    "image.generation.retention_root",
    "image.trace.redact_images"
  ]
  @safe_write_rows [
    {282, "image.enabled"},
    {283, "image.generation.max_bytes"},
    {284, "image.generation.max_pixels"},
    {285, "image.generation.retention_enabled"},
    {286, "image.generation.retention_root"},
    {287, "image.trace.redact_images"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:image",
      owner: "image",
      source: :core,
      group: "image",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Image"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
