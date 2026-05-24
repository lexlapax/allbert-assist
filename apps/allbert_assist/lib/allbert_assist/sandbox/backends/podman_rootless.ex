defmodule AllbertAssist.Sandbox.Backends.PodmanRootless do
  @moduledoc """
  Rootless Podman backend candidate for the v0.36 sandbox.
  """

  @behaviour AllbertAssist.Sandbox.Backend

  alias AllbertAssist.Sandbox.Backends.Command

  @impl true
  def id, do: :podman_rootless

  @impl true
  def platforms, do: [:linux]

  @impl true
  def available?(policy), do: doctor(policy).status == :available

  @impl true
  def doctor(policy) do
    with {:ok, podman} <- find_executable("podman"),
         {:ok, rootless?} <- rootless?(podman),
         :ok <- require_rootless(rootless?),
         :ok <-
           command_ok(podman, ["image", "exists", policy.image], {:image_missing, policy.image}) do
      available(%{executable: podman, image: policy.image, network: policy.network})
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

  defp rootless?(podman) do
    case Command.run(podman, ["info", "--format", "{{.Host.Security.Rootless}}"]) do
      {:ok, %{exit_status: 0, output: output}} -> {:ok, String.trim(output) == "true"}
      {:ok, result} -> {:error, {:podman_info_failed, Map.take(result, [:exit_status, :output])}}
      {:error, reason} -> {:error, {:podman_info_failed, reason}}
    end
  end

  defp require_rootless(true), do: :ok
  defp require_rootless(false), do: {:error, :podman_not_rootless}

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
