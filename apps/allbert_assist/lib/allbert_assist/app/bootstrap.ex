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

  @doc """
  Retry registrations deferred by an incomplete action catalog.

  Returns the modules still deferred. Safe to call repeatedly.
  """
  @spec retry_pending(GenServer.server(), timeout()) :: {:ok, [module()]}
  def retry_pending(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :retry_pending, timeout)
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
    {:ok, %{opts: opts, generation: 0, completion_token: nil, pending: []},
     {:continue, :register_apps}}
  end

  @impl true
  def handle_continue(:register_apps, state) do
    opts = state.opts

    pending =
      if Application.get_env(:allbert_assist, :apps_bootstrap, true) do
        register_configured_apps(opts)
      else
        []
      end

    # Plugin discovery and App registration are intentionally metadata-only,
    # so their ordinary public registration side effects do not run. Flush the
    # derived Settings composition once, after both metadata sources are
    # complete, so no pre-bootstrap partial schema can survive into readiness.
    SettingsFragments.clear_cache()

    {:noreply, %{state | generation: 1, completion_token: make_ref(), pending: pending}}
  end

  @impl true
  def handle_call(:await_ready, _from, state) do
    {:reply, :ok, retry_pending_registrations(state)}
  end

  def handle_call(:retry_pending, _from, state) do
    state = retry_pending_registrations(state)
    {:reply, {:ok, state.pending}, state}
  end

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

    plugin_registry
    |> configured_apps!()
    |> Enum.flat_map(&register_app(&1, registry))
  end

  # An App whose actions are not yet in the compiled catalog is not a broken App
  # -- the catalog is incomplete. That happens whenever a pack contributing
  # actions is not yet loaded, which is the ordinary state of a residual-only
  # VM at boot: the pack's registry_order tokens leave a hole and the catalog
  # fails closed for everyone. Before v1.4 M9 those registrations were logged and
  # dropped, so a transient condition became permanent and every App declaring a
  # plugin-owned action stayed unregistered for the life of the VM.
  #
  # They are retried instead, on await_ready/2 and on the explicit
  # retry_pending/2, both of which are synchronization points a caller reaches
  # only when it is about to depend on the registry. Operator decision 2026-08-11.
  defp retry_pending_registrations(state) do
    registry = Keyword.get(state.opts, :registry, AllbertAssist.App.Registry)
    plugin_registry = Keyword.get(state.opts, :plugin_registry, PluginRegistry)

    # Re-derive rather than replaying only the stored failures. A pack that
    # registered after boot contributes its App through the plugin registry, so
    # that App was never ATTEMPTED -- it is not a deferred failure, it is a
    # newcomer. Both cases are the same condition from the registry's point of
    # view: an App that belongs and is not there yet.
    candidates =
      plugin_registry
      |> configured_apps!()
      |> Enum.concat(state.pending)
      |> Enum.uniq()
      |> Enum.reject(&registered_module?(&1, registry))

    still_pending = Enum.flat_map(candidates, &register_app(&1, registry))

    if still_pending == state.pending do
      state
    else
      SettingsFragments.clear_cache()

      %{
        state
        | pending: still_pending,
          generation: state.generation + 1,
          completion_token: make_ref()
      }
    end
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

  defp registered_module?(module, registry) do
    registry
    |> then(&AllbertAssist.App.Registry.registered_apps(server: &1))
    |> Enum.any?(&(&1.module == module))
  end

  # Returns the modules still awaiting a complete catalog, so callers can fold
  # them into pending state rather than discarding the failure.
  defp register_app(module, registry) do
    case AllbertAssist.App.Registry.register_metadata(module, server: registry) do
      {:ok, app_id} ->
        Logger.info("App metadata registered: #{app_id}")
        []

      {:error, {:unknown_action_module, _action} = reason} ->
        Logger.info(
          "App registration deferred until the action catalog completes: " <>
            "#{inspect(module)}: #{inspect(reason)}"
        )

        [module]

      {:error, reason} ->
        Logger.warning("App registration failed: #{inspect(module)}: #{inspect(reason)}")
        []
    end
  end

  defp default_apps do
    case CompiledInventory.default_app_modules() do
      {:ok, modules} -> modules
      {:error, reason} -> raise "compiled default App inventory unavailable: #{inspect(reason)}"
    end
  end
end
