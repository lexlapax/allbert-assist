defmodule AllbertAssist.Actions.SnapshotCatalog do
  @moduledoc false

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Pack.ActionBinding
  alias AllbertAssist.Pack.Registry.Snapshot

  @cache_key {__MODULE__, :latest_authoritative_catalog}

  @type catalog :: %{
          bindings: [ActionBinding.t()],
          modules: [module()],
          names: [String.t()],
          capabilities: [Capability.t()],
          agent_modules: [module()],
          agent_capabilities: [Capability.t()],
          internal_modules: [module()],
          internal_capabilities: [Capability.t()],
          module_index: %{optional(module()) => ActionBinding.t()},
          name_index: %{optional(String.t()) => ActionBinding.t()},
          app_index: %{optional(atom()) => [Capability.t()]}
        }

  @spec modules(term()) :: [module()]
  def modules(snapshot), do: catalog(snapshot).modules

  @spec agent_modules(term()) :: [module()]
  def agent_modules(snapshot), do: catalog(snapshot).agent_modules

  @spec internal_modules(term()) :: [module()]
  def internal_modules(snapshot), do: catalog(snapshot).internal_modules

  @spec names(term()) :: [String.t()]
  def names(snapshot), do: catalog(snapshot).names

  @spec capabilities(term()) :: [Capability.t()]
  def capabilities(snapshot), do: catalog(snapshot).capabilities

  @spec agent_capabilities(term()) :: [Capability.t()]
  def agent_capabilities(snapshot), do: catalog(snapshot).agent_capabilities

  @spec internal_capabilities(term()) :: [Capability.t()]
  def internal_capabilities(snapshot), do: catalog(snapshot).internal_capabilities

  @spec capabilities_for_app(term(), atom()) :: [Capability.t()]
  def capabilities_for_app(snapshot, app_id) when is_atom(app_id),
    do: Map.get(catalog(snapshot).app_index, app_id, [])

  def capabilities_for_app(_snapshot, _app_id), do: []

  @spec resolve(term(), term()) :: {:ok, module()} | {:error, {:unknown_action, term()}}
  def resolve(snapshot, action) do
    case find_binding(catalog(snapshot), action) do
      %ActionBinding{module: module} -> {:ok, module}
      nil -> {:error, {:unknown_action, action}}
    end
  end

  @spec capability(term(), term()) ::
          {:ok, Capability.t()} | {:error, {:unknown_action, term()}}
  def capability(snapshot, action) do
    case find_binding(catalog(snapshot), action) do
      %ActionBinding{} = binding -> {:ok, capability_for_binding(binding)}
      nil -> {:error, {:unknown_action, action}}
    end
  end

  defp catalog(%Snapshot{
         schema_version: 1,
         publication: :authoritative,
         behavior_digest: digest,
         effective_actions: bindings
       })
       when is_binary(digest) and is_list(bindings) do
    if Enum.all?(bindings, &match?(%ActionBinding{}, &1)) do
      cached_catalog(digest, bindings)
    else
      empty_catalog()
    end
  end

  defp catalog(_snapshot), do: empty_catalog()

  defp cached_catalog(digest, bindings) do
    case :persistent_term.get(@cache_key, nil) do
      {^digest, %{} = catalog} ->
        catalog

      _other ->
        catalog = build_catalog(bindings)
        :persistent_term.put(@cache_key, {digest, catalog})
        catalog
    end
  end

  defp build_catalog(bindings) do
    agent_bindings = agent_bindings(bindings)
    internal_bindings = bindings -- agent_bindings
    capabilities = Enum.map(bindings, &capability_for_binding/1)
    agent_capabilities = Enum.map(agent_bindings, &capability_for_binding/1)
    internal_capabilities = Enum.map(internal_bindings, &capability_for_binding/1)

    %{
      bindings: bindings,
      modules: Enum.map(bindings, & &1.module),
      names: Enum.map(bindings, & &1.name),
      capabilities: capabilities,
      agent_modules: Enum.map(agent_bindings, & &1.module),
      agent_capabilities: agent_capabilities,
      internal_modules: Enum.map(internal_bindings, & &1.module),
      internal_capabilities: internal_capabilities,
      module_index: Map.new(bindings, &{&1.module, &1}),
      name_index: Map.new(bindings, &{&1.name, &1}),
      app_index:
        capabilities
        |> Enum.filter(&is_atom(&1.app_id))
        |> Enum.group_by(& &1.app_id)
    }
  end

  defp empty_catalog do
    %{
      bindings: [],
      modules: [],
      names: [],
      capabilities: [],
      agent_modules: [],
      agent_capabilities: [],
      internal_modules: [],
      internal_capabilities: [],
      module_index: %{},
      name_index: %{},
      app_index: %{}
    }
  end

  defp agent_bindings(bindings) do
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

  defp find_binding(catalog, action) when is_atom(action) do
    Map.get(catalog.module_index, action) ||
      Map.get(catalog.name_index, action |> Atom.to_string() |> normalize_name())
  end

  defp find_binding(catalog, action) when is_binary(action),
    do: Map.get(catalog.name_index, normalize_name(action))

  defp find_binding(_catalog, _action), do: nil

  defp capability_for_binding(binding),
    do: Capability.new(binding.module, binding.normalized_capability)

  defp normalize_name(name) do
    name
    |> String.replace_prefix("Elixir.", "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
