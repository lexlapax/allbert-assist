defmodule AllbertAssist.App.Bootstrap do
  @moduledoc false

  use GenServer

  alias AllbertAssist.Pack.CompiledInventory
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Wait until configured app registration has completed."
  @spec await_ready(GenServer.server(), timeout()) :: :ok
  def await_ready(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :await_ready, timeout)
  end

  @doc false
  @spec completion_token(GenServer.server(), timeout()) ::
          {:ok, %{pid: pid(), generation: pos_integer(), completion_token: reference()}}
          | {:error, :unavailable}
  def completion_token(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :completion_token, timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts, generation: 0, completion_token: nil}, {:continue, :register_apps}}
  end

  @impl true
  def handle_continue(:register_apps, state) do
    opts = state.opts

    if Application.get_env(:allbert_assist, :apps_bootstrap, true) do
      register_configured_apps(opts)
    end

    # Plugin discovery and App registration are intentionally metadata-only,
    # so their ordinary public registration side effects do not run. Flush the
    # derived Settings composition once, after both metadata sources are
    # complete, so no pre-bootstrap partial schema can survive into readiness.
    SettingsFragments.clear_cache()

    {:noreply, %{state | generation: 1, completion_token: make_ref()}}
  end

  @impl true
  def handle_call(:await_ready, _from, state), do: {:reply, :ok, state}

  def handle_call(:completion_token, _from, state) do
    reply = %{
      pid: self(),
      generation: state.generation,
      completion_token: state.completion_token
    }

    {:reply, {:ok, reply}, state}
  end

  defp register_configured_apps(opts) do
    registry = Keyword.get(opts, :registry, AllbertAssist.App.Registry)
    plugin_registry = Keyword.get(opts, :plugin_registry, PluginRegistry)
    Enum.each(configured_apps!(plugin_registry), &register_app(&1, registry))
  end

  defp configured_apps!(plugin_registry) do
    apps = Application.get_env(:allbert_assist, :apps, default_apps())

    unless is_list(apps) do
      raise RuntimeError, "expected :allbert_assist, :apps to be a list, got: #{inspect(apps)}"
    end

    plugin_apps = PluginRegistry.registered_apps(server: plugin_registry)

    apps
    |> Kernel.++(plugin_apps)
    |> Enum.uniq()
  end

  defp register_app(module, registry) do
    case AllbertAssist.App.Registry.register_metadata(module, server: registry) do
      {:ok, app_id} ->
        Logger.info("App metadata registered: #{app_id}")

      {:error, reason} ->
        Logger.warning("App registration failed: #{inspect(module)}: #{inspect(reason)}")
    end
  end

  defp default_apps do
    case CompiledInventory.default_app_modules() do
      {:ok, modules} -> modules
      {:error, reason} -> raise "compiled default App inventory unavailable: #{inspect(reason)}"
    end
  end
end
