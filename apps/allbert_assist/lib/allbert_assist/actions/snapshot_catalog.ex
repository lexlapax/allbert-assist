defmodule AllbertAssist.Actions.SnapshotCatalog do
  @moduledoc false

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Pack.ActionBinding
  alias AllbertAssist.Pack.Registry.Snapshot

  @spec modules(term()) :: [module()]
  def modules(snapshot), do: Enum.map(bindings(snapshot), & &1.module)

  @spec agent_modules(term()) :: [module()]
  def agent_modules(snapshot), do: Enum.map(agent_bindings(snapshot), & &1.module)

  @spec internal_modules(term()) :: [module()]
  def internal_modules(snapshot), do: Enum.map(internal_bindings(snapshot), & &1.module)

  @spec names(term()) :: [String.t()]
  def names(snapshot), do: Enum.map(bindings(snapshot), & &1.name)

  @spec capabilities(term()) :: [Capability.t()]
  def capabilities(snapshot), do: Enum.map(bindings(snapshot), &capability_for_binding/1)

  @spec agent_capabilities(term()) :: [Capability.t()]
  def agent_capabilities(snapshot),
    do: Enum.map(agent_bindings(snapshot), &capability_for_binding/1)

  @spec internal_capabilities(term()) :: [Capability.t()]
  def internal_capabilities(snapshot),
    do: Enum.map(internal_bindings(snapshot), &capability_for_binding/1)

  @spec capabilities_for_app(term(), atom()) :: [Capability.t()]
  def capabilities_for_app(snapshot, app_id) when is_atom(app_id) do
    snapshot
    |> bindings()
    |> Enum.filter(&(Map.get(&1.normalized_capability, :app_id) == app_id))
    |> Enum.map(&capability_for_binding/1)
  end

  def capabilities_for_app(_snapshot, _app_id), do: []

  @spec resolve(term(), term()) :: {:ok, module()} | {:error, {:unknown_action, term()}}
  def resolve(snapshot, action) do
    case find_binding(snapshot, action) do
      %ActionBinding{module: module} -> {:ok, module}
      nil -> {:error, {:unknown_action, action}}
    end
  end

  @spec capability(term(), term()) ::
          {:ok, Capability.t()} | {:error, {:unknown_action, term()}}
  def capability(snapshot, action) do
    case find_binding(snapshot, action) do
      %ActionBinding{} = binding -> {:ok, capability_for_binding(binding)}
      nil -> {:error, {:unknown_action, action}}
    end
  end

  defp agent_bindings(snapshot) do
    bindings = bindings(snapshot)

    boundary =
      bindings
      |> Enum.filter(
        &(&1.source_lane == :native_static and
            Map.get(&1.normalized_capability, :exposure) == :agent)
      )
      |> Enum.map(& &1.registry_order)
      |> Enum.max(fn -> 0 end)

    Enum.filter(bindings, fn binding ->
      (binding.source_lane == :native_static and binding.registry_order <= boundary) or
        (binding.source_lane == :legacy_plugin and
           Map.get(binding.normalized_capability, :exposure) == :agent)
    end)
  end

  defp internal_bindings(snapshot), do: bindings(snapshot) -- agent_bindings(snapshot)

  defp find_binding(snapshot, action) when is_atom(action) do
    Enum.find(bindings(snapshot), fn binding ->
      binding.module == action or binding.name == normalize_atom(action)
    end)
  end

  defp find_binding(snapshot, action) when is_binary(action) do
    normalized = normalize_name(action)
    Enum.find(bindings(snapshot), &(&1.name == normalized))
  end

  defp find_binding(_snapshot, _action), do: nil

  defp capability_for_binding(binding) do
    Capability.new(binding.module, binding.normalized_capability)
  end

  defp bindings(%Snapshot{
         schema_version: 1,
         publication: :authoritative,
         effective_actions: bindings
       })
       when is_list(bindings) do
    if Enum.all?(bindings, &match?(%ActionBinding{}, &1)), do: bindings, else: []
  end

  defp bindings(_snapshot), do: []

  defp normalize_atom(action) do
    action
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> normalize_name()
  end

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
