defmodule AllbertAssist.Sandbox.Backends.ContainerArgs do
  @moduledoc false

  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.Policy

  @workspace "/workspace"
  @project "/workspace/project"
  @drafts "/workspace/drafts"
  @tests "/workspace/tests"
  @sandbox_home "/workspace/allbert_home"
  @sandbox_database "/workspace/allbert_home/db/allbert_test.sqlite3"
  @sandbox_deps "/workspace/allbert_home/deps"
  @reports "/workspace/reports"
  @runner "/opt/allbert/bin/allbert-sandbox-run"

  @spec docker(Bundle.t(), CommandSpec.t(), Policy.t(), keyword()) :: [String.t()]
  def docker(bundle, spec, policy, opts \\ []) do
    runtime_args =
      case Keyword.get(opts, :runtime) do
        nil -> []
        runtime -> ["--runtime", runtime]
      end

    [
      "run",
      "--rm",
      "--name",
      container_name(bundle),
      "--pull",
      "never",
      "--network",
      "none",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--user",
      "65532:65532",
      "--pids-limit",
      "256",
      "--memory",
      "#{policy.memory_mb}m",
      "--cpus",
      to_string(policy.cpu_limit),
      "--tmpfs",
      "/tmp:rw,nosuid,nodev,size=256m,mode=1777",
      "--tmpfs",
      "/run:rw,nosuid,nodev,size=32m,mode=1777"
    ] ++
      runtime_args ++
      common_mount_env_args(bundle, spec) ++ [policy.image, @runner, spec.executable | spec.argv]
  end

  @spec podman(Bundle.t(), CommandSpec.t(), Policy.t()) :: [String.t()]
  def podman(bundle, spec, policy) do
    [
      "run",
      "--rm",
      "--name",
      container_name(bundle),
      "--pull=never",
      "--network",
      "none",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--userns=keep-id",
      "--pids-limit",
      "256",
      "--memory",
      "#{policy.memory_mb}m",
      "--cpus",
      to_string(policy.cpu_limit),
      "--tmpfs",
      "/tmp:rw,nosuid,nodev,size=256m,mode=1777",
      "--tmpfs",
      "/run:rw,nosuid,nodev,size=32m,mode=1777"
    ] ++
      common_mount_env_args(bundle, spec) ++ [policy.image, @runner, spec.executable | spec.argv]
  end

  defp common_mount_env_args(bundle, spec) do
    mount_args(bundle) ++ env_args(spec) ++ ["--workdir", container_cwd(bundle, spec.cwd)]
  end

  defp mount_args(bundle) do
    [
      "--mount",
      mount(bundle.project_path, @project, readonly?: true),
      "--mount",
      mount(bundle.drafts_path, @drafts, readonly?: true),
      "--mount",
      mount(bundle.tests_path, @tests, readonly?: true),
      "--mount",
      mount(bundle.sandbox_home, @sandbox_home),
      "--mount",
      mount(bundle.reports_path, @reports)
    ]
  end

  defp env_args(spec) do
    spec.env
    |> Map.new()
    |> Map.merge(protected_env())
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp protected_env do
    %{
      "ALLBERT_HOME" => @sandbox_home,
      "DATABASE_PATH" => @sandbox_database,
      "HOME" => @sandbox_home,
      "MIX_HOME" => Path.join(@sandbox_home, "mix"),
      "HEX_HOME" => Path.join(@sandbox_home, "hex"),
      "MIX_BUILD_PATH" => Path.join(@sandbox_home, "_build"),
      "MIX_DEPS_PATH" => @sandbox_deps,
      "REBAR_CACHE_DIR" => Path.join(@sandbox_home, "rebar")
    }
  end

  defp mount(source, target, opts \\ []) do
    readonly = if Keyword.get(opts, :readonly?, false), do: ",readonly", else: ""
    "type=bind,source=#{source},target=#{target}#{readonly}"
  end

  defp container_name(bundle) do
    suffix = System.unique_integer([:positive])
    "allbert-sandbox-#{bundle.id}-#{suffix}"
  end

  defp container_cwd(bundle, cwd) do
    cond do
      cwd == bundle.project_path or String.starts_with?(cwd, bundle.project_path <> "/") ->
        String.replace_prefix(cwd, bundle.project_path, @project)

      cwd == bundle.drafts_path or String.starts_with?(cwd, bundle.drafts_path <> "/") ->
        String.replace_prefix(cwd, bundle.drafts_path, @drafts)

      cwd == bundle.tests_path or String.starts_with?(cwd, bundle.tests_path <> "/") ->
        String.replace_prefix(cwd, bundle.tests_path, @tests)

      true ->
        @workspace
    end
  end
end
