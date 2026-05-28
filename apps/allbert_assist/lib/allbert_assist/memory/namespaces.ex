defmodule AllbertAssist.Memory.Namespaces do
  @moduledoc """
  Combined memory namespace facade.

  App-owned namespace declarations still come from `AllbertAssist.App.Registry`.
  Operator-owned system namespaces come from
  `AllbertAssist.Memory.SystemNamespaces`. Memory code that authorizes reads or
  writes consumes this facade when both origins are relevant.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Memory.SystemNamespaces

  @type origin :: :app | :system
  @type declaration :: map()

  @spec all(keyword()) :: nonempty_list(declaration())
  def all(opts \\ []) do
    app_namespaces(opts) ++ system_namespaces()
  end

  @spec app_namespaces(keyword()) :: [declaration()]
  def app_namespaces(opts \\ []) do
    opts
    |> AppRegistry.registered_memory_namespaces()
    |> Enum.map(&normalize_app_namespace/1)
  end

  @spec system_namespaces() :: [SystemNamespaces.declaration()]
  def system_namespaces, do: SystemNamespaces.all()

  @spec get(atom() | nil, atom()) :: {:ok, declaration()} | {:error, term()}
  def get(nil, namespace), do: system_namespace(namespace)

  def get(app_id, namespace) when is_atom(app_id) and is_atom(namespace) do
    all()
    |> Enum.find(&(&1.app_id == app_id and &1.namespace == namespace))
    |> case do
      nil -> {:error, {:unknown_memory_namespace, namespace}}
      declaration -> {:ok, declaration}
    end
  end

  @spec system_namespace(atom()) :: {:ok, SystemNamespaces.declaration()} | {:error, term()}
  def system_namespace(namespace), do: SystemNamespaces.get(namespace)

  defp normalize_app_namespace(%{} = declaration) do
    declaration
    |> Map.put_new(:origin, :app)
    |> Map.put_new(:category, :notes)
  end
end
