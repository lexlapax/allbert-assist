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
end
