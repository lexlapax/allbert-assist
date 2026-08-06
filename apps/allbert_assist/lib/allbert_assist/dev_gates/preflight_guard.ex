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
  @always_guarded_commands ~w[prepush serial-core release compatibility]
  @unguarded_commands ~w[
    docs
    preflight
    preflight.test-load
    preflight.fixture
    scope
    inventory
    focused
    commit
    partition-smoke
    param-contract-sweep
    metrics
    release.structure
  ]

  def verify!(args, root) do
    case classification(args) do
      :guarded ->
        verifier =
          Application.get_env(
            :allbert_assist,
            :preflight_attestation_verifier,
            &default_verify/3
          )

        verifier.(root, Preflight.contract_digest(), clean_required?(args))

      :unguarded ->
        :ok

      :unclassified ->
        Mix.raise("unclassified allbert.test command: #{command_name(args)}")
    end
  end

  def guarded?(args), do: classification(args) == :guarded

  def classification([]), do: :unguarded

  def classification(["fast-local" | args]) do
    if Enum.any?(lane_flags(), &(&1 in args)), do: :guarded, else: :unguarded
  end

  def classification(["external-smoke", "list"]), do: :unguarded
  def classification(["external-smoke" | _]), do: :guarded

  def classification([command | _]) when command in @always_guarded_commands,
    do: :guarded

  def classification([command | _]) when command in @benchmark_commands, do: :guarded

  def classification([command | _]) when is_binary(command) do
    cond do
      String.starts_with?(command, "release.v") -> :guarded
      command in @unguarded_commands -> :unguarded
      true -> :unclassified
    end
  end

  def classification(_args), do: :unclassified

  def clean_required?(["release"]), do: true

  def clean_required?([command]) when is_binary(command),
    do: String.starts_with?(command, "release.v")

  def clean_required?(_args), do: false

  def rules do
    %{
      "always" =>
        @always_guarded_commands ++
          ["release.v*", "external-smoke (except list)"] ++
          @benchmark_commands,
      "conditional" => %{"fast-local" => lane_flags()},
      "unguarded" => @unguarded_commands ++ ["external-smoke list"]
    }
  end

  defp default_verify(root, digest, clean_required?) do
    PreflightAttestation.verify!(root, digest, clean_required?: clean_required?)
    :ok
  end

  defp lane_flags, do: ~w[--core-lanes --stocksage-lanes --web-lanes]

  defp command_name([command | _]) when is_binary(command), do: command
  defp command_name(_args), do: "<invalid>"
end
