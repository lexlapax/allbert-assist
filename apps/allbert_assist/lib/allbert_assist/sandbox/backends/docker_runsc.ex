defmodule AllbertAssist.Sandbox.Backends.DockerRunsc do
  @moduledoc """
  Docker plus gVisor `runsc` backend candidate for the v0.36 sandbox.
  """

  @behaviour AllbertAssist.Sandbox.Backend

  alias AllbertAssist.Sandbox.Backends.Command
  alias AllbertAssist.Sandbox.Backends.ContainerArgs
  alias AllbertAssist.Sandbox.Backends.ContainerRunner
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.Policy

  @impl true
  def id, do: :docker_runsc

  @impl true
  def platforms, do: [:macos, :linux]

  @impl true
  def available?(policy), do: doctor(policy).status == :available

  @impl true
  def doctor(policy) do
    with {:ok, docker} <- find_executable("docker"),
         :ok <-
           command_ok(docker, ["version", "--format", "{{.Server.Version}}"], :docker_unavailable),
         {:ok, runtimes} <- docker_runtimes(docker),
         :ok <- runsc_present(runtimes),
         :ok <-
           command_ok(docker, ["image", "inspect", policy.image], {:image_missing, policy.image}) do
      available(%{
        executable: docker,
        runtime: "runsc",
        image: policy.image,
        runtimes: runtimes,
        network: policy.network
      })
    else
      {:error, reason} -> unavailable(reason)
    end
  end

  @impl true
  def run(bundle, command_spec) do
    policy = Policy.load!()
    argv = argv(bundle, command_spec, policy)
    docker = System.find_executable("docker") || "docker"

    ContainerRunner.run(id(), docker, argv, bundle, command_spec)
  end

  @spec argv(Bundle.t(), CommandSpec.t(), Policy.t()) :: [String.t(), ...]
  def argv(bundle, command_spec, policy) do
    ContainerArgs.docker(bundle, command_spec, policy, runtime: "runsc")
  end

  @impl true
  def cleanup(_bundle), do: :ok

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:missing_executable, name}}
      path -> {:ok, path}
    end
  end

  defp docker_runtimes(docker) do
    case Command.run(docker, ["info", "--format", "{{json .Runtimes}}"]) do
      {:ok, %{exit_status: 0, output: output}} -> {:ok, output}
      {:ok, result} -> {:error, {:docker_info_failed, Map.take(result, [:exit_status, :output])}}
      {:error, reason} -> {:error, {:docker_info_failed, reason}}
    end
  end

  defp runsc_present(runtimes) do
    if String.contains?(runtimes, "runsc"), do: :ok, else: {:error, :runsc_runtime_missing}
  end

  defp command_ok(executable, args, reason) do
    case Command.run(executable, args) do
      {:ok, %{exit_status: 0}} -> :ok
      {:ok, result} -> {:error, {reason, Map.take(result, [:exit_status, :output])}}
      {:error, error} -> {:error, {reason, error}}
    end
  end

  defp available(metadata) do
    %{id: id(), status: :available, reason: :doctor_green, metadata: metadata, diagnostics: []}
  end

  defp unavailable(reason) do
    %{id: id(), status: :unavailable, reason: reason, metadata: %{}, diagnostics: []}
  end
end
