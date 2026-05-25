defmodule AllbertAssist.Sandbox.Backends.AppleContainer do
  @moduledoc """
  Optional Apple `container` backend candidate for the v0.36 sandbox.

  Apple `container` is accepted only when doctor can prove local policy support.
  Until that proof path is green, the backend reports unavailable and `auto`
  falls through to the next candidate.
  """

  @behaviour AllbertAssist.Sandbox.Backend

  alias AllbertAssist.Sandbox.Host

  @impl true
  def id, do: :apple_container

  @impl true
  def platforms, do: [:macos]

  @impl true
  def available?(_policy), do: false

  @impl true
  def doctor(policy) do
    cond do
      not Host.macos_apple_container_capable?(policy.host) ->
        unavailable(:host_not_apple_container_capable)

      is_nil(System.find_executable("container")) ->
        unavailable({:missing_executable, "container"})

      true ->
        unavailable(:policy_enforcement_doctor_not_green)
    end
  end

  @impl true
  def run(_bundle, _command_spec, _policy), do: {:error, :apple_container_run_not_supported}

  @impl true
  def cleanup(_bundle), do: :ok

  defp unavailable(reason) do
    %{id: id(), status: :unavailable, reason: reason, metadata: %{}, diagnostics: []}
  end
end
