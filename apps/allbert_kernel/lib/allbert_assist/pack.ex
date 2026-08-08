defmodule AllbertAssist.Pack do
  @moduledoc """
  Contribution contract implemented by trusted, descriptor-bearing OTP applications.

  A Pack descriptor identifies its owning application. The remaining callbacks
  return inert contribution rows until the matching subsystem inversion consumes
  them.
  """

  alias AllbertAssist.Pack.Descriptor

  @callback descriptor() :: Descriptor.t()
  @callback apps() :: [term()]
  @callback actions() :: [term()]
  @callback settings_fragments() :: [term()]
  @callback settings_migrations() :: [term()]
  @callback channels() :: [term()]
  @callback surfaces() :: [term()]
  @callback skill_roots() :: [term()]
  @callback home_roots() :: [term()]
  @callback jobs() :: [term()]
  @callback stores() :: [term()]
  @callback prompt_rules() :: [term()]
  @callback intent_descriptors() :: [term()]
  @callback cli_groups() :: [term()]
  @callback release_assets() :: [term()]
  @callback test_lanes() :: [term()]

  @doc """
  Kernel concern-contract providers this owner supplies.

  Returns `[{contract_id, implementation_module}]` for members of the closed
  `AllbertAssist.Kernel.Contract` set. Unlike the contribution callbacks above,
  these rows do not enter the canonical-JSON row pipeline: a provider is a
  compiled module reference, and routing it through a JSON payload would mean
  atomizing a string, which the descriptor contract forbids. Composition pairs
  each row with this owner's own validated application before the binder sees
  it.

  Optional and empty by default, so an owner that supplies no kernel provider
  needs no implementation.
  """
  @callback kernel_contracts() :: [{atom(), module()}]

  @optional_callbacks kernel_contracts: 0
end
