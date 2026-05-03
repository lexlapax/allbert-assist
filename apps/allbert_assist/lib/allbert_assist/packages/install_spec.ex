defmodule AllbertAssist.Packages.InstallSpec do
  @moduledoc """
  Normalized package-install request for v0.10.

  This module owns package-manager-specific shape checks. It intentionally
  rejects package specs that imply URL, git, local path, tarball, global, or
  shell-style execution. Permission is still checked by Security Central at the
  registered action boundary.
  """

  alias AllbertAssist.Execution.Policy
  alias AllbertAssist.Packages.ManagerProfile
  alias AllbertAssist.Packages.Npm
  alias AllbertAssist.Packages.PipPreview

  defstruct manager: nil,
            packages: [],
            target_root: nil,
            resolved_target_root: nil,
            save_mode: :prod,
            timeout_ms: nil,
            max_output_bytes: nil,
            profile: nil,
            source_text: nil,
            dry_run_args: [],
            install_args: [],
            execution_available?: false,
            policy_decision: :pending,
            denial_reason: nil,
            warnings: []

  @type t :: %__MODULE__{}

  @exact_semver ~r/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/
  @npm_name ~r/^[a-z0-9][a-z0-9._~-]*$/
  @npm_scoped ~r/^@[a-z0-9][a-z0-9._~-]*\/[a-z0-9][a-z0-9._~-]*$/
  @pip_spec ~r/^([A-Za-z0-9][A-Za-z0-9_.-]*)==([A-Za-z0-9_.!+-]+)$/
  @shell_fragments ["&&", "||", ";", "|", ">", "<", "`", "$("]
  @supported_managers [:npm, :pip]

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, t()}
  def normalize(params, opts \\ [])

  def normalize(params, opts) when is_map(params) do
    context = Keyword.get(opts, :context, %{})
    manager = manager(params)

    case ManagerProfile.load(manager, context) do
      {:ok, policy} ->
        params
        |> build_spec(policy)
        |> validate(policy)
        |> put_argv()

      {:error, reason} ->
        {:error, deny(%__MODULE__{manager: normalize_manager(manager)}, reason)}
    end
  end

  def normalize(_params, _opts), do: {:error, deny(%__MODULE__{}, :invalid_params)}

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = spec) do
    dry_run_argv = if spec.dry_run_args == [], do: [], else: argv(spec, spec.dry_run_args)
    install_argv = if spec.install_args == [], do: [], else: argv(spec, spec.install_args)

    %{
      manager: manager_name(spec.manager),
      packages: Enum.map(spec.packages, & &1.spec),
      package_details: spec.packages,
      target_root: spec.target_root,
      resolved_target_root: spec.resolved_target_root,
      save_mode: spec.save_mode,
      profile: profile_summary(spec.profile),
      executable: executable(spec),
      dry_run_argv: dry_run_argv,
      execution_argv_preview: install_argv,
      execution_available?: spec.execution_available?,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      env_keys: [],
      policy_decision: spec.policy_decision,
      denial_reason: spec.denial_reason,
      warnings: spec.warnings
    }
  end

  @spec resume_params(t(), map()) :: map()
  def resume_params(%__MODULE__{} = spec, params \\ %{}) do
    %{
      action: "run_package_install",
      manager: manager_name(spec.manager),
      packages: Enum.map(spec.packages, & &1.spec),
      project_root: spec.target_root,
      save_mode: Atom.to_string(spec.save_mode),
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      source_text: param(params, :source_text)
    }
  end

  defp build_spec(params, policy) do
    profile = policy.profile
    target_root = target_root(params)

    %__MODULE__{
      manager: normalize_manager(manager(params)),
      packages: normalize_package_input(params),
      target_root: target_root,
      resolved_target_root: Policy.expand_path(target_root),
      save_mode: save_mode(param(params, :save_mode) || param(params, :save)),
      timeout_ms: min(param(params, :timeout_ms) || profile.timeout_ms, policy.max_timeout_ms),
      max_output_bytes: param(params, :max_output_bytes) || profile.max_output_bytes,
      profile: profile,
      source_text: param(params, :source_text)
    }
  end

  defp validate(spec, policy) do
    with {:ok, spec} <- check_enabled(spec, policy),
         {:ok, spec} <- check_manager(spec, policy),
         {:ok, spec} <- check_profile(spec),
         {:ok, spec} <- check_target_root(spec),
         {:ok, spec} <- check_save_mode(spec),
         {:ok, spec} <- check_global_install(spec),
         {:ok, spec} <- parse_packages(spec) do
      {:ok, %{spec | policy_decision: :allowed}}
    end
  end

  defp check_enabled(spec, %{enabled?: true}), do: {:ok, spec}
  defp check_enabled(spec, _policy), do: {:error, deny(spec, :package_installs_disabled)}

  defp check_manager(%{manager: manager} = spec, policy) do
    manager_name = manager_name(manager)

    cond do
      manager not in @supported_managers ->
        {:error, deny(spec, {:unsupported_package_manager, manager_name})}

      manager_name not in policy.allowed_managers ->
        {:error, deny(spec, {:package_manager_not_allowed, manager_name})}

      true ->
        {:ok, spec}
    end
  end

  defp check_profile(%{profile: %{executable: executable}} = spec)
       when is_binary(executable) and executable != "",
       do: {:ok, spec}

  defp check_profile(spec), do: {:error, deny(spec, :package_manager_executable_missing)}

  defp check_target_root(spec) do
    cond do
      spec.profile.allowed_roots == [] ->
        {:error, deny(spec, :package_install_roots_empty)}

      ManagerProfile.root_allowed?(spec.profile, spec.resolved_target_root) ->
        {:ok, spec}

      true ->
        {:error, deny(spec, {:target_root_outside_allowed_roots, spec.resolved_target_root})}
    end
  end

  defp check_save_mode(%{save_mode: mode} = spec)
       when mode in [:prod, :dev, :optional, :peer, :no_save],
       do: {:ok, spec}

  defp check_save_mode(spec), do: {:error, deny(spec, {:unsupported_save_mode, spec.save_mode})}

  defp check_global_install(spec) do
    if spec.profile.global_installs_allowed? do
      {:error, deny(spec, :global_package_installs_not_supported_in_v0_10)}
    else
      {:ok, spec}
    end
  end

  defp parse_packages(%{packages: []} = spec), do: {:error, deny(spec, :missing_package_specs)}

  defp parse_packages(%{manager: :npm} = spec), do: parse_with(spec, &parse_npm_spec/1)
  defp parse_packages(%{manager: :pip} = spec), do: parse_with(spec, &parse_pip_spec/1)

  defp parse_with(spec, parser) do
    spec.packages
    |> Enum.reduce_while({:ok, []}, fn package, {:ok, acc} ->
      case parser.(package) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, deny(spec, reason)}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, %{spec | packages: Enum.reverse(parsed)}}
      error -> error
    end
  end

  defp put_argv({:ok, %{manager: :npm} = spec}) do
    install_args = Npm.install_args(spec)

    spec =
      %{
        spec
        | dry_run_args: Npm.dry_run_args(spec),
          install_args: install_args,
          execution_available?: true
      }

    case validate_manager_args(install_args ++ spec.dry_run_args) do
      :ok -> {:ok, spec}
      {:error, reason} -> {:error, deny(spec, reason)}
    end
  end

  defp put_argv({:ok, %{manager: :pip} = spec}) do
    spec = %{
      spec
      | dry_run_args: PipPreview.preview_args(spec),
        install_args: [],
        execution_available?: false,
        warnings: [PipPreview.preview_note() | spec.warnings]
    }

    case validate_manager_args(spec.dry_run_args) do
      :ok -> {:ok, spec}
      {:error, reason} -> {:error, deny(spec, reason)}
    end
  end

  defp put_argv({:error, spec}), do: {:error, spec}

  defp parse_npm_spec(package) when is_binary(package) do
    package = String.trim(package)

    cond do
      unsafe_package_spec?(package) ->
        {:error, {:unsafe_package_spec, package}}

      parsed = parse_scoped_npm(package) ->
        parsed

      parsed = parse_unscoped_npm(package) ->
        parsed

      unpinned_npm?(package) ->
        {:error, {:unpinned_package_spec, package}}

      true ->
        {:error, {:unsupported_package_spec, package}}
    end
  end

  defp parse_npm_spec(package), do: {:error, {:invalid_package_spec, package}}

  defp parse_scoped_npm(package) do
    case Regex.run(~r/^(@[a-z0-9][a-z0-9._~-]*\/[a-z0-9][a-z0-9._~-]*)@(.+)$/, package) do
      [_, name, version] -> parsed_npm(name, version)
      _other -> nil
    end
  end

  defp parse_unscoped_npm(package) do
    case Regex.run(~r/^([a-z0-9][a-z0-9._~-]*)@(.+)$/, package) do
      [_, name, version] -> parsed_npm(name, version)
      _other -> nil
    end
  end

  defp parsed_npm(name, version) do
    cond do
      not Regex.match?(@npm_name, name) and not Regex.match?(@npm_scoped, name) ->
        {:error, {:unsupported_package_name, name}}

      not Regex.match?(@exact_semver, version) ->
        {:error, {:unsupported_version_spec, version}}

      true ->
        {:ok, %{manager: :npm, name: name, version: version, spec: "#{name}@#{version}"}}
    end
  end

  defp parse_pip_spec(package) when is_binary(package) do
    package = String.trim(package)

    cond do
      unsafe_package_spec?(package) ->
        {:error, {:unsafe_package_spec, package}}

      match = Regex.run(@pip_spec, package) ->
        [_, name, version] = match
        {:ok, %{manager: :pip, name: name, version: version, spec: "#{name}==#{version}"}}

      String.contains?(package, "==") ->
        {:error, {:unsupported_package_spec, package}}

      true ->
        {:error, {:unpinned_package_spec, package}}
    end
  end

  defp parse_pip_spec(package), do: {:error, {:invalid_package_spec, package}}

  defp unsafe_package_spec?(package) do
    package == "" or
      String.starts_with?(package, "-") or
      String.contains?(package, [" ", "\t", "\n", "\r"]) or
      Enum.any?(@shell_fragments, &String.contains?(package, &1)) or
      String.contains?(package, "://") or
      String.starts_with?(String.downcase(package), ["git+", "file:", "link:", "workspace:"]) or
      String.contains?(String.downcase(package), ["@npm:", ".tgz", ".tar.gz"]) or
      String.starts_with?(package, [".", "/", "~"]) or
      String.contains?(package, ["../", "/..", "\\"])
  end

  defp unpinned_npm?("@" <> _rest = package) do
    Regex.match?(~r/^@[a-z0-9][a-z0-9._~-]*\/[a-z0-9][a-z0-9._~-]*$/, package)
  end

  defp unpinned_npm?(package), do: Regex.match?(@npm_name, package)

  defp validate_manager_args(args) do
    cond do
      Enum.any?(args, &(&1 in ["-g", "--global"])) ->
        {:error, :global_package_installs_not_supported_in_v0_10}

      Enum.any?(args, &String.contains?(&1, @shell_fragments)) ->
        {:error, :package_manager_shell_syntax_not_allowed}

      true ->
        :ok
    end
  end

  defp normalize_package_input(params) do
    packages =
      params
      |> param(:packages)
      |> fallback(param(params, :package_specs))
      |> fallback(param(params, :package))
      |> List.wrap()
      |> Enum.flat_map(&split_package_values/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    maybe_apply_version(packages, normalize_manager(manager(params)), param(params, :version))
  end

  defp split_package_values(value) when is_binary(value), do: [value]

  defp split_package_values(value) when is_list(value),
    do: Enum.flat_map(value, &split_package_values/1)

  defp split_package_values(_value), do: []

  defp maybe_apply_version([package], :npm, version) when is_binary(version) do
    if unpinned_npm?(package), do: [package <> "@" <> String.trim(version)], else: [package]
  end

  defp maybe_apply_version([package], :pip, version) when is_binary(version) do
    if String.contains?(package, "=="),
      do: [package],
      else: [package <> "==" <> String.trim(version)]
  end

  defp maybe_apply_version(packages, _manager, _version), do: packages

  defp manager(params), do: param(params, :manager) || "npm"

  defp normalize_manager(manager) when is_atom(manager), do: manager

  defp normalize_manager(manager) when is_binary(manager) do
    manager
    |> String.trim()
    |> String.downcase()
    |> case do
      "npm" -> :npm
      "pip" -> :pip
      _other -> :unsupported
    end
  end

  defp normalize_manager(_manager), do: :unknown

  defp manager_name(manager) when is_atom(manager), do: Atom.to_string(manager)
  defp manager_name(manager) when is_binary(manager), do: manager
  defp manager_name(_manager), do: "unknown"

  defp target_root(params), do: param(params, :project_root) || param(params, :cwd) || File.cwd!()

  defp save_mode(nil), do: :prod
  defp save_mode(:prod), do: :prod
  defp save_mode(:dev), do: :dev
  defp save_mode(:optional), do: :optional
  defp save_mode(:peer), do: :peer
  defp save_mode(:no_save), do: :no_save
  defp save_mode(value) when value in ["prod", "production", "save-prod"], do: :prod
  defp save_mode(value) when value in ["dev", "development", "save-dev"], do: :dev
  defp save_mode(value) when value in ["optional", "save-optional"], do: :optional
  defp save_mode(value) when value in ["peer", "save-peer"], do: :peer
  defp save_mode(value) when value in ["none", "no-save", "no_save"], do: :no_save
  defp save_mode(value), do: value

  defp argv(%{manager: :npm} = spec, args), do: Npm.argv_preview(spec, args)

  defp argv(%{profile: profile}, args) do
    [profile.executable | args]
  end

  defp executable(%{profile: %{executable: executable}}), do: executable
  defp executable(_spec), do: nil

  defp profile_summary(nil), do: nil

  defp profile_summary(profile) do
    %{
      name: profile.name,
      executable: profile.executable,
      args_prefix: profile.args_prefix,
      plan_args: profile.plan_args,
      install_args: profile.install_args,
      description: profile.description,
      allowed_roots: profile.allowed_roots,
      require_confirmation?: profile.require_confirmation?,
      lifecycle_scripts_allowed?: profile.lifecycle_scripts_allowed?,
      git_dependencies_allowed?: profile.git_dependencies_allowed?,
      global_installs_allowed?: profile.global_installs_allowed?
    }
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp fallback(nil, value), do: value
  defp fallback([], value), do: value
  defp fallback(value, _fallback), do: value

  defp deny(spec, reason), do: %{spec | policy_decision: :denied, denial_reason: reason}
end
