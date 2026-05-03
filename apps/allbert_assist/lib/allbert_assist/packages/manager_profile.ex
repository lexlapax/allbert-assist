defmodule AllbertAssist.Packages.ManagerProfile do
  @moduledoc """
  Settings-backed package-manager profile for v0.10 package execution.

  Profiles describe the executable and bounded runtime limits. They do not
  grant permission; `run_package_install` still goes through Security Central
  and durable confirmation before a package manager can run.
  """

  alias AllbertAssist.Execution.Policy
  alias AllbertAssist.Settings

  defstruct name: nil,
            executable: nil,
            args_prefix: [],
            plan_args: [],
            install_args: [],
            description: nil,
            allowed_roots: [],
            timeout_ms: nil,
            max_output_bytes: nil,
            require_confirmation?: true,
            lifecycle_scripts_allowed?: false,
            git_dependencies_allowed?: false,
            global_installs_allowed?: false

  @type t :: %__MODULE__{}

  @settings [
    "package_installs.enabled",
    "package_installs.allowed_roots",
    "package_installs.allowed_managers",
    "package_installs.default_timeout_ms",
    "package_installs.max_timeout_ms",
    "package_installs.max_output_bytes",
    "package_installs.lifecycle_scripts_allowed",
    "package_installs.git_dependencies_allowed",
    "package_installs.global_installs_allowed",
    "package_installs.require_confirmation",
    "package_installs.manager_profiles"
  ]

  @spec load(String.t() | atom(), map()) :: {:ok, map()} | {:error, term()}
  def load(manager, context \\ %{}) do
    with {:ok, settings} <- settings(context) do
      manager_name = manager |> to_string() |> String.trim() |> String.downcase()

      profile_attrs =
        settings
        |> Map.get("package_installs.manager_profiles", %{})
        |> Map.get(manager_name, %{})

      profile = build_profile(manager_name, profile_attrs, settings)

      {:ok,
       %{
         enabled?: settings["package_installs.enabled"],
         allowed_managers: normalize_names(settings["package_installs.allowed_managers"]),
         max_timeout_ms: settings["package_installs.max_timeout_ms"],
         profile: profile
       }}
    end
  end

  @spec root_allowed?(t(), String.t()) :: boolean()
  def root_allowed?(%__MODULE__{allowed_roots: roots}, path) when is_binary(path) do
    expanded = Policy.expand_path(path)
    Enum.any?(roots, &same_or_child_path?(expanded, &1))
  end

  def root_allowed?(_profile, _path), do: false

  defp settings(context) do
    Enum.reduce_while(@settings, {:ok, %{}}, fn key, {:ok, acc} ->
      case Settings.get(key, context) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, {:setting_unavailable, key, reason}}}
      end
    end)
  end

  defp build_profile(manager_name, attrs, settings) do
    %__MODULE__{
      name: manager_name,
      executable: Map.get(attrs, "executable") || default_executable(manager_name),
      args_prefix: Map.get(attrs, "args_prefix", []),
      plan_args: Map.get(attrs, "plan_args", []),
      install_args: Map.get(attrs, "install_args", []),
      description: Map.get(attrs, "description"),
      allowed_roots: allowed_roots(settings, attrs),
      timeout_ms:
        min(
          Map.get(attrs, "timeout_ms") || settings["package_installs.default_timeout_ms"],
          settings["package_installs.max_timeout_ms"]
        ),
      max_output_bytes:
        Map.get(attrs, "max_output_bytes") ||
          settings["package_installs.max_output_bytes"],
      require_confirmation?:
        Map.get(attrs, "require_confirmation", settings["package_installs.require_confirmation"]),
      lifecycle_scripts_allowed?:
        Map.get(
          attrs,
          "lifecycle_scripts_allowed",
          settings["package_installs.lifecycle_scripts_allowed"]
        ),
      git_dependencies_allowed?:
        Map.get(
          attrs,
          "git_dependencies_allowed",
          settings["package_installs.git_dependencies_allowed"]
        ),
      global_installs_allowed?:
        Map.get(
          attrs,
          "global_installs_allowed",
          settings["package_installs.global_installs_allowed"]
        )
    }
  end

  defp allowed_roots(settings, attrs) do
    (settings["package_installs.allowed_roots"] ++ Map.get(attrs, "allowed_roots", []))
    |> Enum.map(&Policy.expand_path/1)
    |> Enum.uniq()
  end

  defp normalize_names(names) when is_list(names) do
    names
    |> Enum.map(&(to_string(&1) |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_names(_names), do: []

  defp default_executable("npm"), do: "npm"
  defp default_executable("pip"), do: "pip"
  defp default_executable(_manager), do: nil

  defp same_or_child_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
