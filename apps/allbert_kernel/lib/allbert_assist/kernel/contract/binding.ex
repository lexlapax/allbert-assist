defmodule AllbertAssist.Kernel.Contract.Binding do
  @moduledoc """
  The complete, validated contract set bound to one composition generation.

  A binding is all-or-nothing. It is published once the whole set validates and
  is deleted as a unit; there is no partial state in which some kernel concerns
  hold a provider and others do not, and no previous binding survives a release
  to be read as a fallback.
  """

  alias AllbertAssist.Kernel.Contract.Provider

  @enforce_keys [:generation, :barrier_pid, :providers]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          generation: String.t(),
          barrier_pid: pid(),
          providers: %{optional(atom()) => Provider.t()}
        }
end
