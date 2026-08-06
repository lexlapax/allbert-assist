defmodule AllbertAssist.DevGates.PreflightGuard do
  @moduledoc """
  Central classification and exact-state guard for expensive developer gates.

  This is plain release tooling. It runs before an expensive Mix task launches
  subprocesses and has no application-runtime authority.
  """

  alias AllbertAssist.DevGates.Preflight
  alias AllbertAssist.DevGates.PreflightAttestation

  @benchmark_commands ~w[
    bench-decide
    bench-v13-latency
    bench-v13-zero-shot
    bench-v13-fanout
    qualify-head
  ]

  def verify!(args, root) do
    if guarded?(args) do
      verifier =
        Application.get_env(
          :allbert_assist,
          :preflight_attestation_verifier,
          &default_verify/3
        )

      verifier.(root, Preflight.contract_digest(), clean_required?(args))
    else
      :ok
    end
  end

  def guarded?(["prepush" | _]), do: true
  def guarded?(["fast-local" | args]), do: Enum.any?(lane_flags(), &(&1 in args))
  def guarded?(["serial-core" | _]), do: true
  def guarded?(["release"]), do: true
  def guarded?([command]) when command in @benchmark_commands, do: true
  def guarded?([command | _]) when command in @benchmark_commands, do: true
  def guarded?(["external-smoke", "list"]), do: false
  def guarded?(["external-smoke" | _]), do: true
  def guarded?(["compatibility" | _]), do: true
  def guarded?([command]) when is_binary(command), do: String.starts_with?(command, "release.v")
  def guarded?(_args), do: false

  def clean_required?(["release"]), do: true

  def clean_required?([command]) when is_binary(command),
    do: String.starts_with?(command, "release.v")

  def clean_required?(_args), do: false

  def rules do
    %{
      "always" =>
        [
          "prepush",
          "serial-core",
          "release",
          "release.v*",
          "external-smoke (except list)",
          "compatibility"
        ] ++
          @benchmark_commands,
      "conditional" => %{"fast-local" => lane_flags()}
    }
  end

  defp default_verify(root, digest, clean_required?) do
    PreflightAttestation.verify!(root, digest, clean_required?: clean_required?)
    :ok
  end

  defp lane_flags, do: ~w[--core-lanes --stocksage-lanes --web-lanes]
end
