defmodule AllbertAssist.Settings.FragmentOwners.Marketplace do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "marketplace.catalog.cache_path" => %{
      default: "<ALLBERT_HOME>/marketplace/cache",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "marketplace.catalog.mirror_on_first_action" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: false
    },
    "marketplace.catalog.source" => %{
      allowed_values: ["shipped"],
      default: "shipped",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "marketplace.enabled" => %{default: true, sensitive?: false, type: :boolean, writable?: true},
    "marketplace.install.default_state" => %{
      allowed_values: ["disabled_untrusted"],
      default: "disabled_untrusted",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "marketplace.install.target_dir_skills" => %{
      default: "<ALLBERT_HOME>/marketplace/skills",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "marketplace.install.target_dir_templates" => %{
      default: "<ALLBERT_HOME>/marketplace/templates",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "marketplace.installed_state_path" => %{
      default: "<ALLBERT_HOME>/marketplace/installed.json",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "marketplace.provenance.hash_algorithm" => %{
      allowed_values: ["sha256"],
      default: "sha256",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "marketplace.provenance.require_hash_match" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: false
    },
    "marketplace.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    }
  }
  @defaults %{
    "marketplace" => %{
      "catalog" => %{
        "cache_path" => "<ALLBERT_HOME>/marketplace/cache",
        "mirror_on_first_action" => true,
        "source" => "shipped"
      },
      "enabled" => true,
      "install" => %{
        "default_state" => "disabled_untrusted",
        "target_dir_skills" => "<ALLBERT_HOME>/marketplace/skills",
        "target_dir_templates" => "<ALLBERT_HOME>/marketplace/templates"
      },
      "installed_state_path" => "<ALLBERT_HOME>/marketplace/installed.json",
      "provenance" => %{"hash_algorithm" => "sha256", "require_hash_match" => true},
      "schema_version" => 1
    }
  }
  @safe_write_keys [
    "marketplace.enabled",
    "marketplace.catalog.cache_path",
    "marketplace.install.target_dir_skills",
    "marketplace.install.target_dir_templates",
    "marketplace.installed_state_path"
  ]
  @safe_write_rows [
    {298, "marketplace.enabled"},
    {299, "marketplace.catalog.cache_path"},
    {300, "marketplace.install.target_dir_skills"},
    {301, "marketplace.install.target_dir_templates"},
    {302, "marketplace.installed_state_path"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:marketplace",
      owner: "marketplace",
      source: :core,
      group: "marketplace",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Marketplace"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
