defmodule AllbertAssist.TestSupport.RegistryIsolationFixtures do
  @moduledoc false

  # v1.0.2 M2 (ADR 0082): reusable private-registry fixture for test isolation.
  #
  # `start_isolated_registries/1` starts a supervised App.Registry and
  # Plugin.Registry pair with UNIQUE process names and UNIQUE ETS table names
  # (both required — the backing ETS tables are named), registers nothing, and
  # returns the internal RegistryContext keyword
  # `[app: [server: name], plugin: [server: name]]` that registry-reading
  # functions accept. The registration wrappers pass `side_effects: false` plus
  # the private server so fixture registrations never emit global registration
  # signals and never clear the shared Settings-schema cache.

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  @doc """
  Start one private App.Registry + Plugin.Registry pair from an ExUnit setup or
  test body and return the RegistryContext keyword for it.

  `context_tag` is folded into the process and ETS table names for readability;
  uniqueness comes from `System.unique_integer/1` plus `MIX_TEST_PARTITION`.
  """
  @spec start_isolated_registries(term()) :: keyword()
  def start_isolated_registries(context_tag) do
    suffix = unique_suffix(context_tag)
    app_name = :"isolated_app_registry_#{suffix}"
    plugin_name = :"isolated_plugin_registry_#{suffix}"

    start_supervised!(
      Supervisor.child_spec(
        {AppRegistry, name: app_name, table_name: :"#{app_name}_table", enabled?: true},
        id: app_name
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {PluginRegistry, name: plugin_name, table_name: :"#{plugin_name}_table", enabled?: true},
        id: plugin_name
      )
    )

    [app: [server: app_name], plugin: [server: plugin_name]]
  end

  @doc "Register an app module into the private App.Registry, without global side effects."
  @spec register_app!(keyword(), module(), keyword()) :: atom()
  def register_app!(context, module, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:server, app_server(context))
      |> Keyword.put(:side_effects, false)

    {:ok, app_id} = AppRegistry.register(module, opts)
    app_id
  end

  @doc "Register a plugin module or entry into the private Plugin.Registry, without global side effects."
  @spec register_plugin!(keyword(), module() | PluginEntry.t(), keyword()) :: String.t()
  def register_plugin!(context, module_or_entry, opts \\ [])

  def register_plugin!(context, %PluginEntry{} = entry, opts) do
    {:ok, plugin_id} = PluginRegistry.register_entry(entry, plugin_register_opts(context, opts))
    plugin_id
  end

  def register_plugin!(context, module, opts) when is_atom(module) do
    {:ok, plugin_id} = PluginRegistry.register_module(module, plugin_register_opts(context, opts))
    plugin_id
  end

  defp plugin_register_opts(context, opts) do
    opts
    |> Keyword.put(:server, plugin_server(context))
    |> Keyword.put(:side_effects, false)
  end

  defp app_server(context), do: context |> Keyword.fetch!(:app) |> Keyword.fetch!(:server)
  defp plugin_server(context), do: context |> Keyword.fetch!(:plugin) |> Keyword.fetch!(:server)

  defp unique_suffix(context_tag) do
    tag =
      context_tag
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 60)

    partition = System.get_env("MIX_TEST_PARTITION") || "0"
    "#{tag}_p#{partition}_#{System.unique_integer([:positive])}"
  end
end
