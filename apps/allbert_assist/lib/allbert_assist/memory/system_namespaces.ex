defmodule AllbertAssist.Memory.SystemNamespaces do
  @moduledoc """
  Operator-owned memory namespaces that are not app registrations.

  System namespaces are inert declarations consumed by memory read/write
  authorization. They are not app ids, do not participate in app validation,
  and do not grant runtime authority.
  """

  @identity %{
    origin: :system,
    app_id: nil,
    namespace: :identity,
    category: :identity,
    writable: true,
    description: "Operator-authored identity and persona memory."
  }

  @namespaces [@identity]

  @type declaration :: %{
          required(:origin) => :system,
          required(:app_id) => nil,
          required(:namespace) => atom(),
          required(:category) => atom(),
          required(:writable) => boolean(),
          optional(:description) => String.t()
        }

  @spec all() :: [declaration()]
  def all, do: @namespaces

  @spec get(atom()) :: {:ok, declaration()} | {:error, {:unknown_memory_namespace, atom()}}
  def get(namespace) when is_atom(namespace) do
    case Enum.find(@namespaces, &(&1.namespace == namespace)) do
      nil -> {:error, {:unknown_memory_namespace, namespace}}
      declaration -> {:ok, declaration}
    end
  end
end
