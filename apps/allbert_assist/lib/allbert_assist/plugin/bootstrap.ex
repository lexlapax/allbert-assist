defmodule AllbertAssist.Plugin.Bootstrap do
  @moduledoc false

  use GenServer

  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry
  alias AllbertAssist.Plugin.Validator

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts), do: {:ok, Map.new(opts), {:continue, :discover_plugins}}

  @impl true
  def handle_continue(:discover_plugins, opts) do
    if Map.get(opts, :bootstrap?, true) do
      discover_and_register(opts)
    end

    {:noreply, opts}
  end

  defp discover_and_register(opts) do
    registry = Map.get(opts, :registry, Registry)
    child_supervisor = Map.get(opts, :child_supervisor, AllbertAssist.Plugin.ChildSupervisor)

    discoveries = Map.get(opts, :discoveries) || Discovery.discover(discovery_opts(opts))
    Enum.each(discoveries, &register_discovery(&1, registry, child_supervisor))
  end

  defp register_discovery({:module, module, registration_opts}, registry, child_supervisor) do
    case Registry.register_module(module, Keyword.put(registration_opts, :server, registry)) do
      {:ok, plugin_id} ->
        Logger.info("Plugin registered: #{plugin_id}")
        start_plugin_child(plugin_id, registry, child_supervisor)

      {:error, reason} ->
        Logger.warning("Plugin registration failed: #{inspect(module)}: #{inspect(reason)}")
    end
  end

  defp register_discovery({:entry, entry}, registry, child_supervisor) do
    case Registry.register_entry(entry, server: registry) do
      {:ok, plugin_id} ->
        Logger.info("Plugin registered: #{plugin_id}")
        start_plugin_child(plugin_id, registry, child_supervisor)

      {:error, reason} ->
        Logger.warning("Plugin registration failed: #{entry.plugin_id}: #{inspect(reason)}")
    end
  end

  defp register_discovery({:diagnostic, key, diagnostics}, registry, _child_supervisor) do
    Registry.put_diagnostics(to_string(key), diagnostics, server: registry)
  end

  defp start_plugin_child(plugin_id, registry, child_supervisor) do
    with {:ok, entry} <- Registry.lookup(plugin_id, server: registry),
         false <- entry.children == :ignore do
      child_spec = Supervisor.child_spec(entry.children, [])

      case DynamicSupervisor.start_child(child_supervisor, child_spec) do
        {:ok, _pid} ->
          :ok

        {:ok, _pid, _info} ->
          :ok

        {:error, {:already_started, _pid}} ->
          Registry.put_diagnostics(plugin_id, [duplicate_child_diagnostic(child_spec)], server: registry)

        {:error, {:already_present, _pid}} ->
          Registry.put_diagnostics(plugin_id, [duplicate_child_diagnostic(child_spec)], server: registry)

        {:error, reason} ->
          Registry.put_diagnostics(plugin_id, [child_start_diagnostic(reason)], server: registry)
      end
    else
      _other -> :ok
    end
  rescue
    exception ->
      Registry.put_diagnostics(plugin_id, [child_start_diagnostic(Exception.message(exception))],
        server: registry
      )
  end

  defp duplicate_child_diagnostic(child_spec) do
    Validator.diagnostic(:error, :duplicate_child_id, "Plugin child id already exists.",
      child_id: child_spec.id
    )
  end

  defp child_start_diagnostic(reason) do
    Validator.diagnostic(:error, :plugin_child_start_failed, "Plugin child failed to start.",
      reason: inspect(reason)
    )
  end

  defp discovery_opts(opts) do
    opts
    |> Map.take([:settings, :project_root])
    |> Map.to_list()
  end
end
