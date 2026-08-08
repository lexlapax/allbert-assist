defmodule AllbertAssist.Settings.FragmentOwners.Plugins do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "plugins.disabled" => %{default: [], sensitive?: false, type: :string_list, writable?: true},
    "plugins.enabled" => %{default: [], sensitive?: false, type: :string_list, writable?: true},
    "plugins.load_policy" => %{
      allowed_values: ["shipped_and_skill_only", "shipped_only"],
      default: "shipped_and_skill_only",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "plugins.registration_enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "plugins.scan_paths" => %{
      default: ["./plugins", "<ALLBERT_HOME>/plugins"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "plugins.trusted_project_roots" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    }
  }
  @defaults %{
    "plugins" => %{
      "disabled" => [],
      "enabled" => [],
      "load_policy" => "shipped_and_skill_only",
      "registration_enabled" => true,
      "scan_paths" => ["./plugins", "<ALLBERT_HOME>/plugins"],
      "trusted_project_roots" => []
    }
  }
  @safe_write_keys [
    "plugins.enabled",
    "plugins.disabled",
    "plugins.scan_paths",
    "plugins.trusted_project_roots",
    "plugins.load_policy",
    "plugins.registration_enabled"
  ]
  @safe_write_rows [
    {383, "plugins.enabled"},
    {384, "plugins.disabled"},
    {385, "plugins.scan_paths"},
    {386, "plugins.trusted_project_roots"},
    {387, "plugins.load_policy"},
    {388, "plugins.registration_enabled"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:plugins",
      owner: "plugins",
      source: :core,
      group: "plugins",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Plugins"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
