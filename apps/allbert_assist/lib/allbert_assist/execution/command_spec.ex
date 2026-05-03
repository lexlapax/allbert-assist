defmodule AllbertAssist.Execution.CommandSpec do
  @moduledoc """
  Normalized command specification for v0.08 Level 1 local execution.

  This module validates command shape and policy. It intentionally does not
  spawn processes; runner adapters consume this spec in later milestones.
  """

  alias AllbertAssist.Execution.Policy
  alias AllbertAssist.Resources.Ref

  defstruct executable: nil,
            resolved_executable: nil,
            args: [],
            cwd: nil,
            resolved_cwd: nil,
            stdin_mode: :none,
            timeout_ms: nil,
            max_output_bytes: nil,
            env: %{},
            requested_env_keys: [],
            env_summary: [],
            path_operands: [],
            command_class: :unknown,
            command_profile: nil,
            sandbox_level: 1,
            policy_decision: :pending,
            denial_reason: nil

  @type t :: %__MODULE__{}

  @shell_executables ~w[sh bash zsh ksh fish]
  @network_executables ~w[curl wget nc netcat ssh scp sftp ftp telnet]
  @inline_eval_flags ~w[-c -e -E --eval -p]
  @shell_tokens ~w[&& || ; | > >> < &]

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, t()}
  def normalize(params, opts \\ [])

  def normalize(params, opts) when is_map(params) do
    policy = Keyword.get(opts, :policy) || load_policy!(opts)

    %__MODULE__{}
    |> put_basic_params(params, policy)
    |> validate_policy(policy)
  end

  def normalize(_params, opts) do
    policy = Keyword.get(opts, :policy) || load_policy!(opts)

    spec =
      %__MODULE__{
        timeout_ms: policy.default_timeout_ms,
        max_output_bytes: policy.max_output_bytes
      }

    {:error, deny(spec, :invalid_params)}
  end

  @spec allowed?(t()) :: boolean()
  def allowed?(%__MODULE__{policy_decision: :allowed}), do: true
  def allowed?(_spec), do: false

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = spec) do
    summary = %{
      executable: spec.executable,
      args: spec.args,
      cwd: spec.cwd,
      resolved_cwd: spec.resolved_cwd,
      command_class: spec.command_class,
      command_profile: spec.command_profile,
      sandbox_level: spec.sandbox_level,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      env_keys: spec.env_summary,
      path_operands: spec.path_operands,
      policy_decision: spec.policy_decision,
      denial_reason: spec.denial_reason
    }

    Map.put(summary, :resource_refs, Ref.from_shell_command_summary(summary))
  end

  defp load_policy!(opts) do
    context = Keyword.get(opts, :context, %{})

    case Policy.load(context) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, "could not load execution policy: #{inspect(reason)}"
    end
  end

  defp put_basic_params(spec, params, policy) do
    cwd = param(params, :cwd) || File.cwd!()
    args = param(params, :args) || []
    timeout_ms = param(params, :timeout_ms) || policy.default_timeout_ms
    max_output_bytes = param(params, :max_output_bytes) || policy.max_output_bytes
    requested_env = normalize_requested_env(param(params, :env) || %{})
    env = Policy.env_for(policy, requested_env)

    %{
      spec
      | executable: normalize_executable(param(params, :executable) || param(params, :command)),
        args: normalize_args(args),
        cwd: cwd,
        resolved_cwd: Policy.expand_path(cwd),
        stdin_mode: normalize_stdin(param(params, :stdin_mode)),
        timeout_ms: timeout_ms,
        max_output_bytes: max_output_bytes,
        env: env,
        requested_env_keys: requested_env |> Map.keys() |> Enum.sort(),
        env_summary: env |> Map.keys() |> Enum.sort()
    }
  end

  defp validate_policy(%__MODULE__{} = spec, %Policy{} = policy) do
    with {:ok, spec} <- check_policy_enabled(spec, policy),
         {:ok, spec} <- check_command_shape(spec),
         {:ok, spec} <- check_blocked_command_forms(spec, policy),
         {:ok, spec} <- check_cwd(spec, policy),
         {:ok, spec} <- check_env(spec, policy),
         {:ok, spec} <- check_requested_limits(spec, policy) do
      validate_allowed_command(spec, policy)
    end
  end

  defp check_policy_enabled(spec, %Policy{enabled?: true}), do: {:ok, spec}
  defp check_policy_enabled(spec, _policy), do: {:error, deny(spec, :local_execution_disabled)}

  defp check_command_shape(spec) do
    cond do
      invalid_executable?(spec.executable) -> {:error, deny(spec, :invalid_executable)}
      invalid_args?(spec.args) -> {:error, deny(spec, :invalid_args)}
      true -> {:ok, spec}
    end
  end

  defp check_blocked_command_forms(spec, policy) do
    cond do
      shell_token?(spec.args) ->
        {:error, classify_and_deny(spec, :shell_syntax_not_allowed)}

      inline_eval?(spec.executable, spec.args) ->
        {:error, classify_and_deny(spec, :inline_interpreter_eval_not_allowed)}

      blocked_arg?(spec.args, policy.blocked_arg_patterns) ->
        {:error, classify_and_deny(spec, :blocked_arg_pattern)}

      shell_executable?(spec.executable) ->
        {:error, classify_and_deny(spec, :shell_executable_not_allowed)}

      network_executable?(spec.executable) ->
        {:error, classify_and_deny(spec, :network_command_not_allowed)}

      true ->
        {:ok, spec}
    end
  end

  defp check_cwd(spec, policy) do
    if Policy.root_allowed?(policy, spec.resolved_cwd) do
      {:ok, spec}
    else
      {:error, deny(spec, {:cwd_outside_allowed_roots, spec.resolved_cwd})}
    end
  end

  defp check_env(spec, policy) do
    case env_keys_outside_allowlist(spec, policy) do
      [] -> {:ok, spec}
      keys -> {:error, deny(spec, {:env_not_allowed, keys})}
    end
  end

  defp check_requested_limits(spec, policy) do
    cond do
      spec.timeout_ms > policy.max_timeout_ms ->
        {:error, deny(spec, {:timeout_exceeds_policy, spec.timeout_ms, policy.max_timeout_ms})}

      spec.max_output_bytes > policy.max_output_bytes ->
        {:error,
         deny(
           spec,
           {:output_limit_exceeds_policy, spec.max_output_bytes, policy.max_output_bytes}
         )}

      true ->
        {:ok, spec}
    end
  end

  defp validate_allowed_command(spec, policy) do
    case Policy.command_allowed?(policy, spec.executable, spec.args) do
      {:ok, command_policy} ->
        spec
        |> apply_command_policy(command_policy)
        |> validate_limits(policy)
        |> validate_path_operands(policy)

      {:error, reason} ->
        {:error, deny(spec, reason)}
    end
  end

  defp validate_limits(spec, policy) do
    cond do
      spec.timeout_ms > policy.max_timeout_ms ->
        deny(spec, {:timeout_exceeds_policy, spec.timeout_ms, policy.max_timeout_ms})

      spec.max_output_bytes > policy.max_output_bytes ->
        deny(spec, {:output_limit_exceeds_policy, spec.max_output_bytes, policy.max_output_bytes})

      true ->
        spec
    end
  end

  defp apply_command_policy(spec, %{source: :command_profile, name: name} = command_policy) do
    profile = Map.get(command_policy, :profile, %{})

    %{
      spec
      | command_class: class_to_atom(command_policy.command_class),
        command_profile: name,
        timeout_ms: Map.get(profile, "timeout_ms", spec.timeout_ms),
        max_output_bytes: Map.get(profile, "max_output_bytes", spec.max_output_bytes)
    }
  end

  defp apply_command_policy(spec, command_policy) do
    %{spec | command_class: class_to_atom(command_policy.command_class)}
  end

  defp validate_path_operands(%__MODULE__{policy_decision: :denied} = spec, _policy),
    do: {:error, spec}

  defp validate_path_operands(spec, policy) do
    operands = path_operands(spec, policy)
    spec = %{spec | path_operands: operands}

    if policy.require_path_operands_in_allowed_roots? and
         Enum.any?(operands, &(&1.allowed? == false)) do
      denied = Enum.reject(operands, & &1.allowed?)
      {:error, deny(spec, {:path_operands_outside_allowed_roots, denied})}
    else
      {:ok, %{spec | policy_decision: :allowed}}
    end
  end

  defp path_operands(%__MODULE__{executable: executable, args: args, resolved_cwd: cwd}, policy) do
    executable
    |> Path.basename()
    |> path_operand_args(args)
    |> Enum.map(fn arg ->
      resolved = Policy.expand_path(arg, cwd)

      %{
        original: arg,
        resolved: resolved,
        allowed?: Policy.root_allowed?(policy, resolved)
      }
    end)
  end

  defp path_operand_args("pwd", _args), do: []

  defp path_operand_args("ls", args), do: Enum.reject(args, &option?/1)

  defp path_operand_args(command, args) when command in ["cat", "head", "tail", "wc"] do
    Enum.reject(args, &option?/1)
  end

  defp path_operand_args("rg", args) do
    non_options = Enum.reject(args, &option?/1)

    case non_options do
      [_pattern | paths] when paths != [] -> paths
      [single] -> if path_like?(single), do: [single], else: []
      _other -> []
    end
  end

  defp path_operand_args("find", args) do
    args
    |> Enum.take_while(&(&1 not in ["-name", "-type", "-maxdepth", "-mindepth"]))
    |> Enum.reject(&option?/1)
  end

  defp path_operand_args(_command, args), do: Enum.filter(args, &path_like?/1)

  defp option?("-"), do: false
  defp option?("-" <> _rest), do: true
  defp option?(_arg), do: false

  defp path_like?("."), do: true
  defp path_like?(".."), do: true
  defp path_like?("~" <> _rest), do: true
  defp path_like?("/" <> _rest), do: true

  defp path_like?(arg) when is_binary(arg) do
    String.contains?(arg, "/") or String.contains?(arg, ".")
  end

  defp path_like?(_arg), do: false

  defp deny(spec, reason), do: %{spec | policy_decision: :denied, denial_reason: reason}

  defp classify_and_deny(spec, reason) do
    spec
    |> classify_denied(reason)
    |> deny(reason)
  end

  defp classify_denied(spec, :network_command_not_allowed),
    do: %{spec | command_class: :network}

  defp classify_denied(spec, :inline_interpreter_eval_not_allowed),
    do: %{spec | command_class: :interpreter}

  defp classify_denied(spec, :shell_executable_not_allowed),
    do: %{spec | command_class: :interpreter}

  defp classify_denied(spec, _reason), do: spec

  defp invalid_executable?(value), do: not is_binary(value) or String.trim(value) == ""
  defp invalid_args?(args), do: not is_list(args) or not Enum.all?(args, &is_binary/1)

  defp env_keys_outside_allowlist(spec, policy) do
    Enum.reject(spec.requested_env_keys, &(&1 in policy.env_allowlist))
  end

  defp normalize_requested_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_requested_env(_env), do: %{}

  defp normalize_executable(value) when is_binary(value), do: String.trim(value)
  defp normalize_executable(value), do: value

  defp normalize_args(args) when is_list(args), do: args
  defp normalize_args(_args), do: :invalid

  defp normalize_stdin(value) when value in [:none, "none", nil], do: :none
  defp normalize_stdin(value), do: value

  defp shell_token?(args) do
    Enum.any?(args, fn arg ->
      arg in @shell_tokens or String.contains?(arg, "$(") or String.contains?(arg, "`")
    end)
  end

  defp blocked_arg?(args, blocked_patterns) do
    Enum.any?(args, fn arg ->
      Enum.any?(blocked_patterns, &blocked_pattern_match?(&1, arg))
    end)
  end

  defp blocked_pattern_match?("", _arg), do: false

  defp blocked_pattern_match?(pattern, arg)
       when pattern in ["&&", "||", ";", "|", ">", ">>", "<", "&"],
       do: arg == pattern

  defp blocked_pattern_match?(pattern, arg) when pattern in ["$(", "`"],
    do: String.contains?(arg, pattern)

  defp blocked_pattern_match?(pattern, arg) when pattern in ["-i", "-c", "-e"],
    do: arg == pattern

  defp blocked_pattern_match?(pattern, arg), do: arg == pattern or String.contains?(arg, pattern)

  defp shell_executable?(executable), do: Path.basename(executable) in @shell_executables
  defp network_executable?(executable), do: Path.basename(executable) in @network_executables

  defp inline_eval?(executable, args) do
    Path.basename(executable) in ~w[python python3 node ruby perl php lua osascript] and
      Enum.any?(args, &(&1 in @inline_eval_flags))
  end

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp class_to_atom(value) when is_atom(value), do: value
  defp class_to_atom("read_only"), do: :read_only
  defp class_to_atom("developer"), do: :developer
  defp class_to_atom("mutating"), do: :mutating
  defp class_to_atom(_value), do: :unknown
end
