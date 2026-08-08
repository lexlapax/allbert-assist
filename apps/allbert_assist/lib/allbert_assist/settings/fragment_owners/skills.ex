defmodule AllbertAssist.Settings.FragmentOwners.Skills do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "skills.disabled" => %{default: [], sensitive?: false, type: :string_list, writable?: true},
    "skills.enabled" => %{default: [], sensitive?: false, type: :string_list, writable?: true},
    "skills.imported_cache_policy" => %{
      allowed_values: ["disabled", "enabled_manual_trust"],
      default: "disabled",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "skills.online_import.allowed_sources" => %{
      default: ["skills_sh"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "skills.online_import.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "skills.online_import.max_download_bytes" => %{
      default: 1_048_576,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "skills.online_import.max_listing_results" => %{
      default: 25,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "skills.online_import.require_confirmation" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "skills.online_import.sources.skills_sh.api_url" => %{
      default: "https://skills.sh/api",
      sensitive?: false,
      type: :url_or_nil,
      writable?: true
    },
    "skills.online_import.sources.skills_sh.base_url" => %{
      default: "https://skills.sh",
      sensitive?: false,
      type: :url_or_nil,
      writable?: true
    },
    "skills.online_import.sources.skills_sh.cache_ttl_seconds" => %{
      default: 3600,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "skills.online_import.sources.skills_sh.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "skills.online_import.trust_after_import" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "skills.scan_paths" => %{default: [], sensitive?: false, type: :string_list, writable?: true},
    "skills.trusted_project_roots" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    }
  }
  @defaults %{
    "skills" => %{
      "disabled" => [],
      "enabled" => [],
      "imported_cache_policy" => "disabled",
      "online_import" => %{
        "allowed_sources" => ["skills_sh"],
        "enabled" => false,
        "max_download_bytes" => 1_048_576,
        "max_listing_results" => 25,
        "require_confirmation" => true,
        "sources" => %{
          "skills_sh" => %{
            "api_url" => "https://skills.sh/api",
            "base_url" => "https://skills.sh",
            "cache_ttl_seconds" => 3600,
            "enabled" => false
          }
        },
        "trust_after_import" => false
      },
      "scan_paths" => [],
      "trusted_project_roots" => []
    }
  }
  @safe_write_keys [
    "skills.scan_paths",
    "skills.trusted_project_roots",
    "skills.enabled",
    "skills.disabled",
    "skills.imported_cache_policy",
    "skills.online_import.enabled",
    "skills.online_import.require_confirmation",
    "skills.online_import.allowed_sources",
    "skills.online_import.max_listing_results",
    "skills.online_import.max_download_bytes",
    "skills.online_import.trust_after_import",
    "skills.online_import.sources.skills_sh.enabled",
    "skills.online_import.sources.skills_sh.base_url",
    "skills.online_import.sources.skills_sh.api_url",
    "skills.online_import.sources.skills_sh.cache_ttl_seconds"
  ]
  @safe_write_rows [
    {144, "skills.scan_paths"},
    {145, "skills.trusted_project_roots"},
    {146, "skills.enabled"},
    {147, "skills.disabled"},
    {148, "skills.imported_cache_policy"},
    {373, "skills.online_import.enabled"},
    {374, "skills.online_import.require_confirmation"},
    {375, "skills.online_import.allowed_sources"},
    {376, "skills.online_import.max_listing_results"},
    {377, "skills.online_import.max_download_bytes"},
    {378, "skills.online_import.trust_after_import"},
    {379, "skills.online_import.sources.skills_sh.enabled"},
    {380, "skills.online_import.sources.skills_sh.base_url"},
    {381, "skills.online_import.sources.skills_sh.api_url"},
    {382, "skills.online_import.sources.skills_sh.cache_ttl_seconds"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:skills",
      owner: "skills",
      source: :core,
      group: "skills",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Skills"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
