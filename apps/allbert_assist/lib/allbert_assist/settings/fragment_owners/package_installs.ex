defmodule AllbertAssist.Settings.FragmentOwners.PackageInstalls do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "package_installs.allowed_managers" => %{
      default: ["npm"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "package_installs.allowed_roots" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "package_installs.default_timeout_ms" => %{
      default: 30_000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "package_installs.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "package_installs.git_dependencies_allowed" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "package_installs.global_installs_allowed" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "package_installs.lifecycle_scripts_allowed" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "package_installs.manager_profiles" => %{
      default: %{},
      sensitive?: false,
      type: :package_manager_profiles,
      writable?: true
    },
    "package_installs.max_output_bytes" => %{
      default: 262_144,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "package_installs.max_timeout_ms" => %{
      default: 120_000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "package_installs.require_confirmation" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "package_installs" => %{
      "allowed_managers" => ["npm"],
      "allowed_roots" => [],
      "default_timeout_ms" => 30_000,
      "enabled" => false,
      "git_dependencies_allowed" => false,
      "global_installs_allowed" => false,
      "lifecycle_scripts_allowed" => false,
      "manager_profiles" => %{},
      "max_output_bytes" => 262_144,
      "max_timeout_ms" => 120_000,
      "require_confirmation" => true
    }
  }
  @safe_write_keys [
    "package_installs.enabled",
    "package_installs.require_confirmation",
    "package_installs.allowed_roots",
    "package_installs.allowed_managers",
    "package_installs.default_timeout_ms",
    "package_installs.max_timeout_ms",
    "package_installs.max_output_bytes",
    "package_installs.lifecycle_scripts_allowed",
    "package_installs.git_dependencies_allowed",
    "package_installs.global_installs_allowed",
    "package_installs.manager_profiles"
  ]
  @safe_write_rows [
    {338, "package_installs.enabled"},
    {339, "package_installs.require_confirmation"},
    {340, "package_installs.allowed_roots"},
    {341, "package_installs.allowed_managers"},
    {342, "package_installs.default_timeout_ms"},
    {343, "package_installs.max_timeout_ms"},
    {344, "package_installs.max_output_bytes"},
    {345, "package_installs.lifecycle_scripts_allowed"},
    {346, "package_installs.git_dependencies_allowed"},
    {347, "package_installs.global_installs_allowed"},
    {348, "package_installs.manager_profiles"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:package_installs",
      owner: "package_installs",
      source: :core,
      group: "package_installs",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Package Installs"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
