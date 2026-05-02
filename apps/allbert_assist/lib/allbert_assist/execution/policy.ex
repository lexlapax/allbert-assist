defmodule AllbertAssist.Execution.Policy do
  @moduledoc """
  Settings-backed Level 1 local execution policy.

  This module does not execute anything. It normalizes Settings Central values
  into the policy shape consumed by command-spec validation and later runner
  adapters.
  """

  alias AllbertAssist.Settings

  defstruct enabled?: false,
            allowed_roots: [],
            allowed_commands: [],
            command_profiles: %{},
            blocked_arg_patterns: [],
            require_path_operands_in_allowed_roots?: true,
            default_timeout_ms: 5000,
            max_timeout_ms: 30_000,
            max_output_bytes: 65_536,
            env_allowlist: [],
            require_confirmation?: true

  @type t :: %__MODULE__{}

  @settings_prefix "execution.local."

  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(context \\ %{}) do
    with {:ok, enabled?} <- get_setting("enabled", context),
         {:ok, allowed_roots} <- get_setting("allowed_roots", context),
         {:ok, allowed_commands} <- get_setting("allowed_commands", context),
         {:ok, command_profiles} <- get_setting("command_profiles", context),
         {:ok, blocked_arg_patterns} <- get_setting("blocked_arg_patterns", context),
         {:ok, require_path_operands?} <-
           get_setting("require_path_operands_in_allowed_roots", context),
         {:ok, default_timeout_ms} <- get_setting("default_timeout_ms", context),
         {:ok, max_timeout_ms} <- get_setting("max_timeout_ms", context),
         {:ok, max_output_bytes} <- get_setting("max_output_bytes", context),
         {:ok, env_allowlist} <- get_setting("env_allowlist", context),
         {:ok, require_confirmation?} <- get_setting("require_confirmation", context) do
      {:ok,
       %__MODULE__{
         enabled?: enabled?,
         allowed_roots: normalize_roots(allowed_roots),
         allowed_commands: Enum.map(allowed_commands, &String.trim/1),
         command_profiles: command_profiles,
         blocked_arg_patterns: blocked_arg_patterns,
         require_path_operands_in_allowed_roots?: require_path_operands?,
         default_timeout_ms: default_timeout_ms,
         max_timeout_ms: max_timeout_ms,
         max_output_bytes: max_output_bytes,
         env_allowlist: Enum.map(env_allowlist, &String.trim/1),
         require_confirmation?: require_confirmation?
       }}
    end
  end

  @spec command_allowed?(t(), String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def command_allowed?(%__MODULE__{} = policy, executable, args) do
    basename = Path.basename(executable)

    cond do
      basename in policy.allowed_commands ->
        {:ok, %{source: :default_allowlist, name: basename, command_class: :read_only}}

      profile = matching_profile(policy.command_profiles, basename, args) ->
        {:ok, profile}

      true ->
        {:error, {:command_not_allowed, basename}}
    end
  end

  @spec env_for(t(), map()) :: map()
  def env_for(%__MODULE__{} = policy, requested_env \\ %{}) do
    requested_env = normalize_env(requested_env)

    policy.env_allowlist
    |> Enum.reduce(%{}, fn key, acc ->
      value = Map.get(requested_env, key) || System.get_env(key)
      if is_binary(value), do: Map.put(acc, key, value), else: acc
    end)
  end

  @spec root_allowed?(t(), String.t()) :: boolean()
  def root_allowed?(%__MODULE__{allowed_roots: allowed_roots}, path) when is_binary(path) do
    expanded = expand_path(path)
    Enum.any?(allowed_roots, &same_or_child_path?(expanded, &1))
  end

  def root_allowed?(_policy, _path), do: false

  @spec expand_path(String.t(), String.t() | nil) :: String.t()
  def expand_path(path, cwd \\ nil) when is_binary(path) do
    path
    |> expand_home()
    |> then(fn path ->
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, cwd || File.cwd!())
      end
    end)
  end

  defp get_setting(name, context) do
    Settings.get(@settings_prefix <> name, context)
  end

  defp normalize_roots(roots) do
    roots
    |> Enum.map(&expand_path/1)
    |> Enum.uniq()
  end

  defp matching_profile(profiles, basename, args) do
    Enum.find_value(profiles, fn {name, profile} ->
      command = Path.basename(Map.get(profile, "command", ""))

      if command == basename and args_prefix_matches?(profile, args) do
        %{
          source: :command_profile,
          name: name,
          command_class: command_class(profile),
          profile: profile
        }
      end
    end)
  end

  defp args_prefix_matches?(profile, args) do
    prefix = Map.get(profile, "args_prefix", [])
    Enum.take(args, length(prefix)) == prefix
  end

  defp normalize_env(env) when is_map(env),
    do: Map.new(env, fn {key, value} -> {to_string(key), value} end)

  defp normalize_env(_env), do: %{}

  defp command_class(profile) do
    case Map.get(profile, "command_class", "developer") do
      "read_only" -> :read_only
      "developer" -> :developer
      "mutating" -> :mutating
      _other -> :unknown
    end
  end

  defp expand_home("~"), do: System.user_home!()
  defp expand_home("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_home(path), do: path

  defp same_or_child_path?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
