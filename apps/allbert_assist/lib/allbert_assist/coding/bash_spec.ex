defmodule AllbertAssist.Coding.BashSpec do
  @moduledoc """
  Normalizes Pi-mode `bash` action params into Level 1 local runner specs.

  Argv-style commands reuse `Execution.CommandSpec`. Raw shell strings are
  accepted only when the local-coding operator tier resolves and the raw-shell
  setting is enabled.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.PathPolicy
  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.Policy
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate

  @subagent_command_pattern ~r/(^|\s)(codex|claude|gemini|opencode|cursor|antigravity)(\s|$)/
  @subagent_executables ~w[codex claude gemini opencode cursor antigravity]

  @type t :: %{
          required(:mode) => :argv | :raw_shell,
          required(:command_spec) => CommandSpec.t(),
          required(:summary) => map(),
          required(:resume_params) => map()
        }

  @doc "Normalize bash params into an executable command spec."
  @spec normalize(map(), map()) :: {:ok, t()} | {:error, map()}
  def normalize(params, context) when is_map(params) and is_map(context) do
    params = normalize_plain_command_to_argv(params)

    if raw_shell_request?(params) do
      normalize_raw_shell(params, context)
    else
      normalize_argv(params, context)
    end
  end

  def normalize(_params, _context), do: {:error, error(:invalid_params)}

  defp normalize_argv(params, context) do
    with {:ok, cwd} <- resolve_cwd(params, context),
         {:ok, policy} <- coding_execution_policy(context),
         command_params <- command_params(params, cwd, policy),
         :ok <- ensure_no_subagent_argv(command_params),
         {:ok, spec} <- CommandSpec.normalize(command_params, policy: policy) do
      {:ok, build(:argv, spec, params)}
    else
      {:error, %CommandSpec{} = spec} -> {:error, denied_spec_error(:argv, spec)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp normalize_raw_shell(params, context) do
    command = text_param(params, :command)

    with :ok <- ensure_raw_shell_command(command),
         :ok <- ensure_raw_shell_allowed(context),
         :ok <- ensure_no_subagent(command),
         {:ok, cwd} <- resolve_cwd(params, context),
         {:ok, policy} <- coding_execution_policy(context),
         :ok <- ensure_execution_enabled(policy),
         :ok <- ensure_env_allowed(params, policy),
         :ok <- ensure_requested_limits(params, policy),
         spec <- raw_shell_spec(command, params, cwd, policy) do
      {:ok, build(:raw_shell, spec, params)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp raw_shell_request?(params) do
    is_binary(field(params, :command)) and
      field(params, :executable) in [nil, ""]
  end

  defp normalize_plain_command_to_argv(params) do
    command = text_param(params, :command)

    cond do
      command == "" ->
        params

      field(params, :executable) not in [nil, ""] ->
        params

      raw_shell_syntax?(command) ->
        params

      true ->
        case split_plain_command(command) do
          [executable | args] ->
            params
            |> drop_param(:command)
            |> put_param(:executable, executable)
            |> put_param(:args, args)

          [] ->
            params
        end
    end
  end

  defp split_plain_command(command) do
    OptionParser.split(command)
  rescue
    _exception -> []
  end

  defp raw_shell_syntax?(command) when is_binary(command) do
    command
    |> String.to_charlist()
    |> raw_shell_syntax?(:none)
  end

  defp raw_shell_syntax?([], _quote), do: false

  defp raw_shell_syntax?([?\\, _escaped | rest], quote) when quote in [:none, :double],
    do: raw_shell_syntax?(rest, quote)

  defp raw_shell_syntax?([?' | rest], :none), do: raw_shell_syntax?(rest, :single)
  defp raw_shell_syntax?([?' | rest], :single), do: raw_shell_syntax?(rest, :none)
  defp raw_shell_syntax?([?" | rest], :none), do: raw_shell_syntax?(rest, :double)
  defp raw_shell_syntax?([?" | rest], :double), do: raw_shell_syntax?(rest, :none)
  defp raw_shell_syntax?([char | _rest], :none) when char in ~c";|<>&\n\r`", do: true
  defp raw_shell_syntax?([?$, ?( | _rest], quote) when quote != :single, do: true
  defp raw_shell_syntax?([?` | _rest], :double), do: true
  defp raw_shell_syntax?([_char | rest], quote), do: raw_shell_syntax?(rest, quote)

  defp resolve_cwd(params, context) do
    cwd = field(params, :cwd) || "."

    with {:ok, dir} <- PathPolicy.resolve_dir(cwd, context) do
      {:ok, dir}
    end
  end

  defp coding_execution_policy(context) do
    with {:ok, policy} <- Policy.load(context),
         {:ok, jail} <- PathPolicy.jail(context) do
      {:ok,
       %{
         policy
         | allowed_roots: [jail],
           default_timeout_ms: bounded_timeout(policy),
           max_timeout_ms: bounded_timeout(policy),
           max_output_bytes: bounded_output(policy)
       }}
    end
  rescue
    exception -> {:error, {:execution_policy_load_failed, exception.__struct__}}
  end

  defp bounded_timeout(%Policy{} = policy),
    do: min(policy.max_timeout_ms, Config.bash_timeout_ms())

  defp bounded_output(%Policy{} = policy),
    do: min(policy.max_output_bytes, Config.bash_max_output_bytes())

  defp command_params(params, cwd, %Policy{} = policy) do
    %{
      executable: field(params, :executable) || field(params, :command),
      args: list_param(params, :args),
      cwd: cwd.path,
      timeout_ms: int_param(params, :timeout_ms, policy.default_timeout_ms),
      max_output_bytes: int_param(params, :max_output_bytes, policy.max_output_bytes),
      env: map_param(params, :env)
    }
  end

  defp raw_shell_spec(command, params, cwd, %Policy{} = policy) do
    %CommandSpec{
      executable: "/bin/sh",
      resolved_executable: "/bin/sh",
      args: ["-lc", command],
      cwd: cwd.path,
      resolved_cwd: cwd.path,
      timeout_ms: int_param(params, :timeout_ms, policy.default_timeout_ms),
      max_output_bytes: int_param(params, :max_output_bytes, policy.max_output_bytes),
      env: Policy.env_for(policy, map_param(params, :env)),
      requested_env_keys: map_param(params, :env) |> Map.keys() |> Enum.sort(),
      env_summary: policy |> Policy.env_for(map_param(params, :env)) |> Map.keys() |> Enum.sort(),
      command_class: :developer,
      command_profile: :raw_shell,
      sandbox_level: 1,
      policy_decision: :allowed
    }
  end

  defp build(mode, %CommandSpec{} = spec, params) do
    summary =
      spec
      |> CommandSpec.summary()
      |> Map.put(:mode, mode)
      |> redact_summary()

    %{
      mode: mode,
      command_spec: spec,
      summary: summary,
      resume_params: resume_params(mode, spec, params)
    }
  end

  defp resume_params(:raw_shell, %CommandSpec{} = spec, params) do
    %{
      action: "bash",
      mode: :raw_shell,
      command: Enum.at(spec.args, 1),
      cwd: spec.cwd,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      env: map_param(params, :env),
      source_text: field(params, :source_text)
    }
  end

  defp resume_params(:argv, %CommandSpec{} = spec, params) do
    %{
      action: "bash",
      mode: :argv,
      executable: spec.executable,
      args: spec.args,
      cwd: spec.cwd,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      env: map_param(params, :env),
      source_text: field(params, :source_text)
    }
  end

  defp ensure_raw_shell_command(""), do: {:error, :invalid_command}
  defp ensure_raw_shell_command(_command), do: :ok

  defp ensure_raw_shell_allowed(context) do
    cond do
      not Config.bash_allow_raw_shell?() ->
        {:error, :raw_shell_disabled}

      PermissionGate.coding_tier(context) != :local_coding_operator ->
        {:error, :raw_shell_requires_local_coding_tier}

      true ->
        :ok
    end
  end

  defp ensure_execution_enabled(%Policy{enabled?: true}), do: :ok
  defp ensure_execution_enabled(_policy), do: {:error, :local_execution_disabled}

  defp ensure_env_allowed(params, %Policy{} = policy) do
    requested_env_keys = params |> map_param(:env) |> Map.keys() |> Enum.sort()
    denied = Enum.reject(requested_env_keys, &(&1 in policy.env_allowlist))

    case denied do
      [] -> :ok
      keys -> {:error, {:env_not_allowed, keys}}
    end
  end

  defp ensure_requested_limits(params, %Policy{} = policy) do
    timeout_ms = int_param(params, :timeout_ms, policy.default_timeout_ms)
    max_output_bytes = int_param(params, :max_output_bytes, policy.max_output_bytes)

    cond do
      timeout_ms > policy.max_timeout_ms ->
        {:error, {:timeout_exceeds_policy, timeout_ms, policy.max_timeout_ms}}

      max_output_bytes > policy.max_output_bytes ->
        {:error, {:output_limit_exceeds_policy, max_output_bytes, policy.max_output_bytes}}

      true ->
        :ok
    end
  end

  defp ensure_no_subagent(command) do
    if Regex.match?(@subagent_command_pattern, command) do
      {:error, :bash_spawned_subagent_not_allowed}
    else
      :ok
    end
  end

  defp ensure_no_subagent_argv(%{executable: executable}) do
    basename =
      executable
      |> to_string()
      |> Path.basename()

    if basename in @subagent_executables do
      {:error, :bash_spawned_subagent_not_allowed}
    else
      :ok
    end
  end

  defp denied_spec_error(mode, %CommandSpec{} = spec) do
    %{
      reason: spec.denial_reason || :policy_denied,
      mode: mode,
      command: CommandSpec.summary(spec) |> redact_summary()
    }
  end

  defp error(reason), do: %{reason: reason}

  defp redact_summary(summary) do
    summary
    |> Redactor.redact()
    |> Map.update(:args, [], &redact_args/1)
    |> Map.delete(:resource_refs)
  end

  defp redact_args([]), do: []
  defp redact_args(args) when is_list(args), do: ["[REDACTED_ARGS]"]
  defp redact_args(_args), do: []

  defp text_param(params, key) do
    case field(params, key) do
      value when is_binary(value) -> String.trim(value)
      nil -> ""
      value -> value |> to_string() |> String.trim()
    end
  end

  defp int_param(params, key, default) do
    case field(params, key) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp list_param(params, key) do
    case field(params, key) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      nil -> []
      value -> [to_string(value)]
    end
  end

  defp map_param(params, key) do
    case field(params, key) do
      value when is_map(value) -> Map.new(value, fn {key, value} -> {to_string(key), value} end)
      _other -> %{}
    end
  end

  defp put_param(params, key, value) when is_map(params), do: Map.put(params, key, value)

  defp drop_param(params, key) when is_map(params) do
    params
    |> Map.delete(key)
    |> Map.delete(Atom.to_string(key))
  end

  defp field(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
