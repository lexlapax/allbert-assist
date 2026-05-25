defmodule AllbertAssist.Sandbox.CommandSpec do
  @moduledoc """
  Strict explicit-argv command specification for v0.36 sandbox runs.

  This module rejects command strings, shell syntax, package manager and
  dependency-install profiles, migrations, broad eval, and host paths before a
  backend sees the request.
  """

  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.Policy

  @executables ~w[mix]
  @profiles ~w[compile focused_tests credo dialyzer security_evals precommit]a
  @env_allowlist ~w[LANG LC_ALL MIX_ENV]
  @shell_tokens ~w[&& || ; | > >> < &]
  @forbidden_mix_prefixes [
    ["deps.get"],
    ["deps", "get"],
    ["archive.install"],
    ["archive", "install"],
    ["ecto.migrate"],
    ["ecto", "migrate"],
    ["ecto.rollback"],
    ["ecto", "rollback"],
    ["cmd"]
  ]
  @forbidden_args ~w[
    --eval
    -e
    --sname
    --name
    --cookie
    --erl
    --detached
    --app
  ]

  @enforce_keys [:executable, :argv, :cwd, :profile, :timeout_ms, :output_bytes]
  defstruct @enforce_keys ++
              [
                env: %{},
                status: :pending,
                denial_reason: nil,
                diagnostics: []
              ]

  @type t :: %__MODULE__{
          executable: String.t(),
          argv: [String.t()],
          cwd: String.t(),
          profile: atom(),
          timeout_ms: pos_integer(),
          output_bytes: pos_integer(),
          env: %{String.t() => String.t()},
          status: :pending | :allowed | :denied,
          denial_reason: term(),
          diagnostics: [map()]
        }

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, t()}
  def normalize(params, opts \\ [])

  def normalize(params, opts) when is_map(params) do
    policy = Keyword.get(opts, :policy) || Policy.load!(opts)
    bundle = Keyword.get(opts, :bundle)

    spec = %__MODULE__{
      executable: value(params, :executable),
      argv: value(params, :argv) || value(params, :args) || [],
      cwd: value(params, :cwd) || default_cwd(bundle),
      profile: normalize_profile(value(params, :profile)),
      timeout_ms: value(params, :timeout_ms) || policy.timeout_ms,
      output_bytes: value(params, :output_bytes) || policy.output_bytes,
      env: value(params, :env) || %{}
    }

    validate(spec, policy, bundle)
  end

  def normalize(_params, opts) do
    policy = Keyword.get(opts, :policy) || Policy.load!(opts)

    {:error,
     deny(
       %__MODULE__{
         executable: nil,
         argv: [],
         cwd: "",
         profile: :compile,
         timeout_ms: policy.timeout_ms,
         output_bytes: policy.output_bytes,
         env: %{}
       },
       :invalid_params
     )}
  end

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = spec) do
    %{
      executable: spec.executable,
      argv: spec.argv,
      cwd: spec.cwd,
      profile: spec.profile,
      timeout_ms: spec.timeout_ms,
      output_bytes: spec.output_bytes,
      env_keys: spec.env |> Map.keys() |> Enum.sort(),
      status: spec.status,
      denial_reason: spec.denial_reason,
      diagnostics: spec.diagnostics
    }
  end

  @spec allowed?(t()) :: boolean()
  def allowed?(%__MODULE__{status: :allowed}), do: true
  def allowed?(_spec), do: false

  defp validate(spec, policy, bundle) do
    with {:ok, spec} <- validate_shape(spec),
         {:ok, spec} <- validate_limits(spec, policy),
         {:ok, spec} <- validate_cwd(spec, bundle),
         {:ok, spec} <- validate_env(spec),
         {:ok, spec} <- validate_argv(spec),
         {:ok, spec} <- validate_profile(spec) do
      {:ok, %{spec | status: :allowed, env: filter_env(spec.env)}}
    end
  end

  defp validate_shape(spec) do
    cond do
      spec.executable not in @executables -> {:error, deny(spec, :executable_not_allowed)}
      not is_list(spec.argv) -> {:error, deny(spec, :argv_must_be_list)}
      not Enum.all?(spec.argv, &is_binary/1) -> {:error, deny(spec, :argv_must_be_strings)}
      not is_binary(spec.cwd) -> {:error, deny(spec, :cwd_must_be_string)}
      spec.profile not in @profiles -> {:error, deny(spec, :profile_not_allowed)}
      true -> {:ok, spec}
    end
  end

  defp validate_limits(spec, policy) do
    cond do
      spec.timeout_ms > policy.timeout_ms -> {:error, deny(spec, :timeout_exceeds_policy)}
      spec.output_bytes > policy.output_bytes -> {:error, deny(spec, :output_exceeds_policy)}
      true -> {:ok, spec}
    end
  end

  defp validate_cwd(spec, nil), do: {:ok, spec}

  defp validate_cwd(spec, %Bundle{} = bundle) do
    cwd = Path.expand(spec.cwd, bundle.project_path)

    if inside_bundle?(cwd, bundle) do
      {:ok, %{spec | cwd: cwd}}
    else
      {:error, deny(spec, {:cwd_outside_bundle, cwd})}
    end
  end

  defp validate_env(spec) when is_map(spec.env) do
    keys = Map.keys(spec.env)

    cond do
      Enum.any?(keys, &sensitive_key?/1) ->
        {:error, deny(spec, :secret_env_not_allowed)}

      Enum.any?(keys, &(&1 not in @env_allowlist)) ->
        {:error, deny(spec, :env_not_allowed)}

      not Enum.all?(Map.values(spec.env), &is_binary/1) ->
        {:error, deny(spec, :env_values_must_be_strings)}

      true ->
        {:ok, spec}
    end
  end

  defp validate_env(spec), do: {:error, deny(spec, :env_must_be_map)}

  defp validate_argv(spec) do
    cond do
      Enum.any?(spec.argv, &shell_token?/1) ->
        {:error, deny(spec, :shell_syntax_not_allowed)}

      Enum.any?(spec.argv, &String.contains?(&1, ["$(", "`"])) ->
        {:error, deny(spec, :shell_substitution_not_allowed)}

      Enum.any?(spec.argv, &(&1 in @forbidden_args)) ->
        {:error, deny(spec, :forbidden_arg)}

      true ->
        validate_executable_args(spec)
    end
  end

  defp validate_executable_args(%{executable: "mix"} = spec) do
    if forbidden_mix?(spec.argv),
      do: {:error, deny(spec, :mix_command_not_allowed)},
      else: {:ok, spec}
  end

  defp validate_profile(
         %{profile: :compile, executable: "mix", argv: ["compile", "--warnings-as-errors"]} = spec
       ),
       do: {:ok, spec}

  defp validate_profile(
         %{profile: :credo, executable: "mix", argv: ["credo", "--strict"]} = spec
       ),
       do: {:ok, spec}

  defp validate_profile(%{profile: :dialyzer, executable: "mix", argv: ["dialyzer"]} = spec),
    do: {:ok, spec}

  defp validate_profile(%{profile: :precommit, executable: "mix", argv: ["precommit"]} = spec),
    do: {:ok, spec}

  defp validate_profile(%{profile: profile, executable: "mix", argv: ["test" | paths]} = spec)
       when profile in [:focused_tests, :security_evals] do
    if Enum.all?(paths, &safe_relative_path?/1),
      do: {:ok, spec},
      else: {:error, deny(spec, :test_path_not_allowed)}
  end

  defp validate_profile(spec), do: {:error, deny(spec, :argv_profile_mismatch)}

  defp forbidden_mix?(argv) do
    Enum.any?(@forbidden_mix_prefixes, &List.starts_with?(argv, &1))
  end

  defp filter_env(env), do: Map.take(env, @env_allowlist)

  defp shell_token?(arg), do: arg in @shell_tokens or String.contains?(arg, @shell_tokens)

  defp safe_relative_path?(path) do
    is_binary(path) and Path.type(path) != :absolute and
      not String.contains?(path, ["..", "$", "`", "|", ";", "&", ">", "<"])
  end

  defp inside_bundle?(cwd, bundle) do
    roots = [bundle.project_path, bundle.drafts_path, bundle.tests_path]
    Enum.any?(roots, &(cwd == &1 or String.starts_with?(cwd, &1 <> "/")))
  end

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.contains?(["secret", "token", "password", "api_key", "credential"])
  end

  defp default_cwd(%Bundle{} = bundle), do: bundle.project_path
  defp default_cwd(_bundle), do: "."

  defp normalize_profile(nil), do: :invalid
  defp normalize_profile(profile) when is_atom(profile), do: profile

  defp normalize_profile(profile) when is_binary(profile) do
    Enum.find(@profiles, :invalid, &(Atom.to_string(&1) == profile))
  end

  defp normalize_profile(_profile), do: :invalid

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp deny(spec, reason) do
    %{
      spec
      | status: :denied,
        denial_reason: reason,
        diagnostics: [%{reason: reason}]
    }
  end
end
