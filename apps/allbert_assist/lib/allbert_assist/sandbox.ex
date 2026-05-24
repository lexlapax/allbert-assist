defmodule AllbertAssist.Sandbox do
  @moduledoc """
  Public v0.36 Elixir/OTP sandbox and gate-runner facade.

  v0.36 is report-only: a green doctor or future passing gate report never
  grants live runtime authority, loads modules, registers actions, or enables
  skills.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.Backend.Resolver
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.DoctorReport
  alias AllbertAssist.Sandbox.Policy

  @doc "Return a fail-closed sandbox doctor report."
  @spec doctor(keyword()) :: DoctorReport.t()
  def doctor(opts \\ []) do
    Paths.ensure_home!()
    policy = Policy.load!(opts)

    if policy.enabled? do
      policy
      |> Resolver.resolve(opts)
      |> DoctorReport.from_resolution(policy)
    else
      DoctorReport.disabled(policy)
    end
  end

  @doc "Build a disposable copy-in/copy-out sandbox bundle."
  @spec build_bundle(map(), keyword()) :: {:ok, Bundle.t()} | {:error, map()}
  def build_bundle(params, opts \\ []) when is_map(params) do
    Paths.ensure_home!()
    Bundle.build(params, opts)
  end

  @doc "Run a sandbox command. Implemented in the backend milestone."
  @spec run_command(term(), term(), keyword()) :: {:error, :not_implemented_until_m3}
  def run_command(_bundle, _command_spec, _opts \\ []), do: {:error, :not_implemented_until_m3}

  @doc "Run a named sandbox gate. Implemented in the gate-runner milestone."
  @spec run_gate(term(), keyword()) :: {:error, :not_implemented_until_m5}
  def run_gate(_params, _opts \\ []), do: {:error, :not_implemented_until_m5}

  @doc "Discard a sandbox bundle."
  @spec cleanup(Bundle.t() | String.t()) :: :ok | {:error, term()}
  def cleanup(%Bundle{root: root}), do: cleanup(root)

  def cleanup(root) when is_binary(root) do
    case File.rm_rf(root) do
      {:ok, _paths} -> :ok
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end
end
