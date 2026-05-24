defmodule AllbertAssist.Sandbox do
  @moduledoc """
  Public v0.36 Elixir/OTP sandbox and gate-runner facade.

  v0.36 is report-only: a green doctor or future passing gate report never
  grants live runtime authority, loads modules, registers actions, or enables
  skills.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.Backend.Resolver
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
end
