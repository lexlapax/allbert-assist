defmodule AllbertAssist.Kernel.Contract.Provider do
  @moduledoc """
  One validated contract provider declaration contributed by a compiled owner.

  A provider is compiled first-party application code. Pack metadata, a Home
  manifest, a YAML file, model output, or a bare module name cannot become an
  implementation: composition resolves the module from a compiled contribution
  and validates it before any binding exists.
  """

  @enforce_keys [:contract, :implementation, :application]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          contract: atom(),
          implementation: module(),
          application: atom()
        }

  @doc """
  Build a provider declaration from a compiled owner's contribution row.

  Shape errors are rejected here so the binder never sees a partially formed
  declaration; the binder's own validation then covers identity, uniqueness,
  callback export, and application residence.
  """
  @spec new(term()) :: {:ok, t()} | {:error, {:malformed_provider, term()}}
  def new(%__MODULE__{} = provider), do: validate(provider)

  def new({contract, implementation, application}),
    do: new(%{contract: contract, implementation: implementation, application: application})

  def new(%{contract: contract, implementation: implementation, application: application}) do
    validate(%__MODULE__{
      contract: contract,
      implementation: implementation,
      application: application
    })
  end

  def new(other), do: {:error, {:malformed_provider, other}}

  defp validate(%__MODULE__{} = provider) do
    if name_atom?(provider.contract) and name_atom?(provider.implementation) and
         name_atom?(provider.application) do
      {:ok, provider}
    else
      {:error, {:malformed_provider, provider}}
    end
  end

  # `nil`, `true`, and `false` are atoms the VM will happily accept as a module
  # or application name, so an explicit reject keeps a blank contribution row
  # from binding as if it named something.
  defp name_atom?(value), do: is_atom(value) and value not in [nil, true, false]
end
