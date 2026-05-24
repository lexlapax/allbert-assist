defmodule AllbertAssist.Sandbox.Backends.Docker do
  @moduledoc """
  Hardened Docker backend candidate for the v0.36 sandbox.
  """

  @behaviour AllbertAssist.Sandbox.Backend

  alias AllbertAssist.Sandbox.Backends.Command

  @impl true
  def id, do: :docker

  @impl true
  def platforms, do: [:macos, :linux]

  @impl true
  def available?(policy), do: doctor(policy).status == :available

  @impl true
  def doctor(policy) do
    with {:ok, docker} <- find_executable("docker"),
         :ok <-
           command_ok(docker, ["version", "--format", "{{.Server.Version}}"], :docker_unavailable),
         :ok <-
           command_ok(docker, ["image", "inspect", policy.image], {:image_missing, policy.image}) do
      available(%{executable: docker, image: policy.image, network: policy.network})
    else
      {:error, reason} -> unavailable(reason)
    end
  end

  @impl true
  def run(_bundle, _command_spec), do: {:error, :not_implemented_until_m3}

  @impl true
  def cleanup(_bundle), do: :ok

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:missing_executable, name}}
      path -> {:ok, path}
    end
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
