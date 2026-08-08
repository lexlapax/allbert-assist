defmodule AllbertAssist.Kernel.Contract.Settings do
  @moduledoc """
  Settings Central reads for relocated Security Central and `External.RequestSpec`.

  The binding is sealed; the values are not. Security reads posture on every
  call today — `Policy.setting_value/2` and `configured_policy/1` per
  authorization, `Status.summary/1` per invocation — so this contract forwards
  live rather than serving a value frozen at composition time. Freezing them
  would defer an operator's security-settings write until the next rebind, which
  is a behaviour change the freeze forbids (operator decision 2026-08-08).

  Unbound reads return the same shapes Settings Central already returns when a
  key or the store is unavailable, so each caller takes the built-in-default or
  settings-error branch it already has. Nothing here invents a new denial
  vocabulary, and nothing falls back to a previous generation.
  """

  alias AllbertAssist.Kernel.Contract

  @callback get(String.t()) :: {:ok, term()} | {:error, term()}
  @callback defaults() :: map()
  @callback resolved_settings() :: {:ok, map(), map()} | {:error, term()}
  @callback get_dotted(map(), String.t()) :: term()
  @callback secret_status(term()) :: atom()
  @callback version_contract_status() :: map()

  @doc "Read one effective settings value."
  @spec get(String.t()) :: {:ok, term()} | {:error, term()}
  def get(key), do: call(:get, [key], {:error, :product_not_ready})

  @doc "The composed schema defaults."
  @spec defaults() :: map()
  def defaults, do: call(:defaults, [], %{})

  @doc "The resolved effective and user settings pair."
  @spec resolved_settings() :: {:ok, map(), map()} | {:error, term()}
  def resolved_settings, do: call(:resolved_settings, [], {:error, :product_not_ready})

  @doc "Read a dotted key out of an already-resolved settings map."
  @spec get_dotted(map(), String.t()) :: term()
  def get_dotted(settings, key), do: call(:get_dotted, [settings, key], nil)

  @doc """
  Operator-facing status for one secret reference.

  Settings Central answers with an atom from a closed vocabulary, so the
  unbound value is `:missing` — the conservative member. A secret whose custody
  cannot be reached is not one an operator should be told is configured.
  """
  @spec secret_status(term()) :: atom()
  def secret_status(ref), do: call(:secret_status, [ref], :missing)

  @doc "Settings version-contract status for operator security status."
  @spec version_contract_status() :: map()
  def version_contract_status,
    do: call(:version_contract_status, [], %{error: :product_not_ready})

  defp call(fun, args, closed) do
    case Contract.fetch(:settings) do
      {:ok, implementation} -> apply(implementation, fun, args)
      {:error, _unbound} -> closed
    end
  end
end
