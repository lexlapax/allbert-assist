defmodule AllbertAssist.Execution.SkillScriptSpec do
  @moduledoc """
  Normalized resource-gated script specification for v0.09 skill execution.

  The spec resolver is deliberately inert: it verifies skill trust, capability
  metadata, resource inventory, digest, cwd, argv, env, and limits, but it does
  not create confirmations and does not spawn processes.
  """

  import Bitwise, only: [band: 2]

  alias AllbertAssist.Execution.Policy
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills
  alias AllbertAssist.Skills.Resource

  defstruct skill_name: nil,
            requested_skill_name: nil,
            skill_source_scope: nil,
            skill_trust_status: nil,
            skill_enabled?: false,
            skill_root: nil,
            skill_resources: [],
            capability_contract: %{},
            script_path: nil,
            resolved_script_path: nil,
            resource: nil,
            expected_sha256: nil,
            actual_sha256: nil,
            byte_size: 0,
            args: [],
            cwd: nil,
            resolved_cwd: nil,
            cwd_source: :operator,
            run_id: nil,
            timeout_ms: nil,
            max_output_bytes: nil,
            requested_env_keys: [],
            env: %{},
            env_summary: [],
            metadata_env: %{},
            path_operands: [],
            launch_mode: :direct_executable,
            resolved_executable: nil,
            command_class: :developer,
            sandbox_level: 1,
            policy_decision: :pending,
            denial_reason: nil

  @type t :: %__MODULE__{}

  @metadata_env_keys ~w[
    ALLBERT_SKILL_NAME
    ALLBERT_SKILL_SCRIPT_PATH
    ALLBERT_SKILL_SCRIPT_SHA256
    ALLBERT_RUN_ID
  ]

  @sensitive_value ~r/(sk-[A-Za-z0-9_-]+|api[_-]?key\s*[:=]\s*\S+|token\s*[:=]\s*\S+|password\s*[:=]\s*\S+|secret\s*[:=]\s*\S+)/i

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, t()}
  def normalize(params, opts \\ [])

  def normalize(params, opts) when is_map(params) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, local_policy} <- load_local_policy(context),
         {:ok, enabled?} <- Settings.get("execution.skill_scripts.enabled", context) do
      spec =
        %__MODULE__{
          requested_skill_name: param(params, :skill_name),
          timeout_ms: param(params, :timeout_ms) || local_policy.default_timeout_ms,
          max_output_bytes: param(params, :max_output_bytes) || local_policy.max_output_bytes,
          run_id: run_id(params, opts)
        }

      spec
      |> check_script_policy_enabled(enabled?)
      |> bind(&put_skill(&1, params, context))
      |> bind(&put_script_resource(&1, params))
      |> bind(&check_digest(&1, params))
      |> bind(&check_direct_executable/1)
      |> bind(&put_args(&1, params))
      |> bind(&put_cwd(&1, params, local_policy))
      |> bind(&put_env(&1, params, local_policy))
      |> bind(&check_requested_limits(&1, local_policy))
      |> bind(&validate_path_operands(&1, local_policy))
      |> finalize()
    end
  end

  def normalize(_params, opts) do
    context = Keyword.get(opts, :context, %{})

    timeout_ms =
      case load_local_policy(context) do
        {:ok, policy} -> policy.default_timeout_ms
        {:error, _reason} -> nil
      end

    {:error,
     deny(%__MODULE__{timeout_ms: timeout_ms, run_id: run_id(%{}, opts)}, :invalid_params)}
  end

  @spec allowed?(t()) :: boolean()
  def allowed?(%__MODULE__{policy_decision: :allowed}), do: true
  def allowed?(_spec), do: false

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = spec) do
    summary = %{
      skill_name: spec.skill_name,
      skill_source_scope: spec.skill_source_scope,
      skill_trust_status: spec.skill_trust_status,
      skill_enabled?: spec.skill_enabled?,
      script_path: spec.script_path,
      script_sha256: spec.actual_sha256 || spec.expected_sha256,
      byte_size: spec.byte_size,
      args: redact_args(spec.args),
      cwd: spec.cwd,
      resolved_cwd: spec.resolved_cwd,
      cwd_source: spec.cwd_source,
      run_id: spec.run_id,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      env_keys: spec.env_summary,
      metadata_env_keys: @metadata_env_keys,
      path_operands: spec.path_operands,
      launch_mode: spec.launch_mode,
      resolved_executable: spec.resolved_executable,
      command_class: spec.command_class,
      sandbox_level: spec.sandbox_level,
      policy_decision: spec.policy_decision,
      denial_reason: spec.denial_reason
    }

    Map.put(summary, :resource_refs, Ref.from_skill_script_summary(summary))
  end

  defp load_local_policy(context) do
    Policy.load(context)
  end

  defp check_script_policy_enabled(spec, true), do: {:ok, spec}

  defp check_script_policy_enabled(spec, _enabled?),
    do: {:error, deny(spec, :skill_scripts_disabled)}

  defp put_skill(spec, params, context) do
    skill_name = param(params, :skill_name)

    if present_string?(skill_name) do
      case Skills.get(skill_name, registry_context(context)) do
        {:ok, skill} ->
          validate_skill_contract(%{spec | requested_skill_name: skill_name}, skill)

        {:error, _reason} ->
          {:error, deny(spec, :skill_not_found_or_untrusted)}
      end
    else
      {:error, deny(spec, :missing_skill_name)}
    end
  end

  defp validate_skill_contract(spec, skill) do
    validation = skill.contract_validation || %{}
    actions = Map.get(validation, :actions, [])
    permissions = Map.get(validation, :permissions, [])

    cond do
      skill.trust_status != :trusted ->
        {:error, deny(spec, :skill_not_trusted)}

      Map.get(skill, :enabled?, true) != true ->
        {:error, deny(spec, :skill_disabled)}

      Map.get(validation, :status) != :valid ->
        {:error, deny(spec, :invalid_capability_contract)}

      Map.get(validation, :execution_eligible?) != true ->
        {:error, deny(spec, :skill_not_execution_eligible)}

      not Enum.any?(actions, &(&1.name == "run_skill_script")) ->
        {:error, deny(spec, :capability_contract_missing_action)}

      :skill_script_execute not in permissions ->
        {:error, deny(spec, :capability_contract_missing_permission)}

      true ->
        {:ok,
         %{
           spec
           | skill_name: skill.name,
             skill_source_scope: skill.source_scope,
             skill_trust_status: skill.trust_status,
             skill_enabled?: Map.get(skill, :enabled?, true),
             skill_root: skill.source_path,
             skill_resources: skill_resources(skill),
             capability_contract: contract_summary(skill)
         }}
    end
  end

  defp skill_resources(%{spec: %{resources: resources}}) when is_list(resources), do: resources
  defp skill_resources(_skill), do: []

  defp put_script_resource(spec, params) do
    with {:ok, script_path} <- normalize_script_path(param(params, :script_path), spec),
         {:ok, resource} <- find_script_resource(spec, script_path),
         {:ok, resolved_path} <- resolve_script_path(spec, script_path) do
      {:ok,
       %{
         spec
         | script_path: script_path,
           resolved_script_path: resolved_path,
           resolved_executable: resolved_path,
           resource: resource,
           expected_sha256: resource.sha256,
           byte_size: resource.byte_size
       }}
    end
  end

  defp normalize_script_path(path, spec) when is_binary(path) do
    path = String.trim(path)
    segments = Path.split(path)

    cond do
      path == "" ->
        {:error, deny(spec, :missing_script_path)}

      String.contains?(path, <<0>>) ->
        {:error, deny(spec, :invalid_script_path)}

      Path.type(path) == :absolute ->
        {:error, deny(spec, :absolute_script_path)}

      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, deny(spec, :path_traversal)}

      Enum.any?(segments, &String.starts_with?(&1, ".")) ->
        {:error, deny(spec, :hidden_script_path)}

      true ->
        {:ok, Enum.join(segments, "/")}
    end
  end

  defp normalize_script_path(_path, spec), do: {:error, deny(spec, :invalid_script_path)}

  defp find_script_resource(spec, script_path) do
    case Enum.find(spec.skill_resources, &(&1.path == script_path)) do
      %Resource{kind: :script} = resource ->
        {:ok, resource}

      %Resource{} ->
        {:error, deny(spec, :non_script_resource)}

      nil ->
        {:error, deny(spec, :script_resource_not_found)}
    end
  end

  defp resolve_script_path(spec, script_path) do
    resolved = Path.expand(script_path, spec.skill_root)

    if same_or_child_path?(resolved, spec.skill_root) do
      {:ok, resolved}
    else
      {:error, deny(spec, :path_traversal)}
    end
  end

  defp check_digest(spec, params) do
    expected_from_request = param(params, :expected_sha256)

    with {:ok, contents} <- read_script(spec),
         actual_sha256 <- sha256(contents) do
      cond do
        expected_from_request && expected_from_request != spec.expected_sha256 ->
          {:error, deny(%{spec | actual_sha256: actual_sha256}, :digest_mismatch)}

        actual_sha256 != spec.expected_sha256 ->
          {:error, deny(%{spec | actual_sha256: actual_sha256}, :digest_mismatch)}

        true ->
          {:ok, %{spec | actual_sha256: actual_sha256}}
      end
    end
  end

  defp read_script(spec) do
    case File.read(spec.resolved_script_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, deny(spec, {:script_read_failed, reason})}
    end
  end

  defp check_direct_executable(spec) do
    case File.stat(spec.resolved_script_path) do
      {:ok, %{type: :regular} = stat} ->
        if executable_mode?(stat.mode) do
          {:ok, spec}
        else
          {:error, deny(spec, :script_not_executable)}
        end

      {:ok, %{type: type}} ->
        {:error, deny(spec, {:script_not_regular_file, type})}

      {:error, reason} ->
        {:error, deny(spec, {:script_stat_failed, reason})}
    end
  end

  defp put_args(spec, params) do
    args = param(params, :args) || []

    cond do
      not is_list(args) ->
        {:error, deny(spec, :invalid_args)}

      not Enum.all?(args, &valid_arg?/1) ->
        {:error, deny(spec, :invalid_args)}

      true ->
        {:ok, %{spec | args: args}}
    end
  end

  defp put_cwd(spec, params, policy) do
    case param(params, :cwd) do
      nil ->
        run_cwd = Path.join([Paths.execution_root(), "skill-scripts", "runs", spec.run_id, "cwd"])
        {:ok, %{spec | cwd: run_cwd, resolved_cwd: Path.expand(run_cwd), cwd_source: :internal}}

      cwd when is_binary(cwd) ->
        resolved = Policy.expand_path(cwd)

        if Policy.root_allowed?(policy, resolved) do
          {:ok, %{spec | cwd: cwd, resolved_cwd: resolved, cwd_source: :operator}}
        else
          {:error,
           deny(
             %{spec | cwd: cwd, resolved_cwd: resolved},
             {:cwd_outside_allowed_roots, resolved}
           )}
        end

      cwd ->
        {:error, deny(%{spec | cwd: cwd}, :invalid_cwd)}
    end
  end

  defp put_env(spec, params, policy) do
    requested_env = param(params, :env) || %{}

    cond do
      not is_map(requested_env) ->
        {:error, deny(spec, :invalid_env)}

      not Enum.all?(requested_env, fn {key, value} -> valid_env_pair?(key, value) end) ->
        {:error, deny(spec, :invalid_env)}

      true ->
        requested_env = Map.new(requested_env, fn {key, value} -> {to_string(key), value} end)

        case env_keys_outside_allowlist(requested_env, policy) do
          [] ->
            metadata_env = metadata_env(spec)
            allowed_env = Policy.env_for(policy, requested_env)
            env = Map.merge(allowed_env, metadata_env)

            {:ok,
             %{
               spec
               | requested_env_keys: requested_env |> Map.keys() |> Enum.sort(),
                 metadata_env: metadata_env,
                 env: env,
                 env_summary: env |> Map.keys() |> Enum.sort()
             }}

          keys ->
            {:error, deny(spec, {:env_not_allowed, keys})}
        end
    end
  end

  defp check_requested_limits(spec, policy) do
    cond do
      not is_integer(spec.timeout_ms) or spec.timeout_ms < 1 ->
        {:error, deny(spec, :invalid_timeout_ms)}

      not is_integer(spec.max_output_bytes) or spec.max_output_bytes < 1 ->
        {:error, deny(spec, :invalid_max_output_bytes)}

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

  defp validate_path_operands(spec, policy) do
    operands =
      spec.args
      |> Enum.filter(&path_like?/1)
      |> Enum.map(fn arg ->
        resolved = Policy.expand_path(arg, spec.resolved_cwd)

        %{
          original: arg,
          resolved: resolved,
          allowed?: Policy.root_allowed?(policy, resolved)
        }
      end)

    spec = %{spec | path_operands: operands}

    if policy.require_path_operands_in_allowed_roots? and
         Enum.any?(operands, &(&1.allowed? == false)) do
      denied = Enum.reject(operands, & &1.allowed?)
      {:error, deny(spec, {:path_operands_outside_allowed_roots, denied})}
    else
      {:ok, spec}
    end
  end

  defp finalize({:ok, spec}), do: {:ok, %{spec | policy_decision: :allowed}}
  defp finalize({:error, spec}), do: {:error, spec}

  defp bind({:ok, spec}, fun), do: fun.(spec)
  defp bind({:error, spec}, _fun), do: {:error, spec}

  defp registry_context(%{registry_context: registry_context}) when is_map(registry_context) do
    registry_context
  end

  defp registry_context(context), do: context

  defp contract_summary(skill) do
    validation = skill.contract_validation || %{}

    %{
      validation_status: Map.get(validation, :status),
      execution_eligible?: Map.get(validation, :execution_eligible?),
      actions: validation |> Map.get(:actions, []) |> Enum.map(& &1.name),
      permissions: Map.get(validation, :permissions, []),
      confirmation: Map.get(validation, :confirmation)
    }
  end

  defp metadata_env(spec) do
    %{
      "ALLBERT_SKILL_NAME" => spec.skill_name,
      "ALLBERT_SKILL_SCRIPT_PATH" => spec.script_path,
      "ALLBERT_SKILL_SCRIPT_SHA256" => spec.actual_sha256 || spec.expected_sha256,
      "ALLBERT_RUN_ID" => spec.run_id
    }
  end

  defp env_keys_outside_allowlist(env, policy) do
    env
    |> Map.keys()
    |> Enum.reject(&(&1 in policy.env_allowlist))
    |> Enum.sort()
  end

  defp valid_env_pair?(key, value) when (is_binary(key) or is_atom(key)) and is_binary(value),
    do: not String.contains?(to_string(key), <<0>>)

  defp valid_env_pair?(_key, _value), do: false

  defp valid_arg?(arg), do: is_binary(arg) and not String.contains?(arg, <<0>>)

  defp path_like?("."), do: true
  defp path_like?(".."), do: true
  defp path_like?("~" <> _rest), do: true
  defp path_like?("/" <> _rest), do: true

  defp path_like?(arg) when is_binary(arg) do
    String.contains?(arg, "/") or String.contains?(arg, ".")
  end

  defp path_like?(_arg), do: false

  defp executable_mode?(mode), do: band(mode, 0o111) != 0

  defp same_or_child_path?(path, root) do
    root = Path.expand(root)
    path = Path.expand(path)

    path == root or String.starts_with?(path, root <> "/")
  end

  defp run_id(params, opts) do
    param(params, :run_id) ||
      Keyword.get(opts, :run_id) ||
      "run-" <> (System.unique_integer([:positive]) |> Integer.to_string(36))
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp redact_args(args) when is_list(args), do: Enum.map(args, &redact_text/1)
  defp redact_args(_args), do: []

  defp redact_text(value) do
    value
    |> to_string()
    |> String.replace(@sensitive_value, "[REDACTED]")
  end

  defp deny(spec, reason), do: %{spec | policy_decision: :denied, denial_reason: reason}

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
