defmodule AllbertAssist.Plugin.Bootstrap do
  @moduledoc false

  use GenServer

  alias AllbertAssist.Pack.{ActivationContext, ActivationGuard}
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry
  alias AllbertAssist.Plugin.Validator

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
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
    opts = Map.new(opts)

    if Map.get(opts, :bootstrap?, true) do
      discover_and_register(opts)
    end

    {:ok, %{opts: opts, generation: 1, completion_token: make_ref()}}
  end

  @impl true
  def handle_call(:completion_token, _from, state) do
    reply = %{
      pid: self(),
      generation: state.generation,
      completion_token: state.completion_token
    }

    {:reply, {:ok, reply}, state}
  end

  @doc false
  @spec activate_staged_children(keyword(), keyword()) :: :ok | {:error, term()}
  def activate_staged_children(allbert_pack_activation, opts \\ []) do
    with [{:allbert_pack_activation, %ActivationContext{}}] <- allbert_pack_activation,
         :ok <- ActivationGuard.validate(allbert_pack_activation) do
      registry = Keyword.get(opts, :registry, Registry)

      child_supervisor =
        Keyword.get(opts, :child_supervisor, AllbertAssist.Plugin.ChildSupervisor)

      Registry.registered_plugins(server: registry)
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        result = start_plugin_child(entry.plugin_id, registry, child_supervisor)
        :ok = Registry.mark_child_activation(entry.plugin_id, result, server: registry)

        case result do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {entry.plugin_id, reason}}}
        end
      end)
    end
  end

  defp discover_and_register(opts) do
    registry = Map.get(opts, :registry, Registry)
    child_supervisor = Map.get(opts, :child_supervisor, AllbertAssist.Plugin.ChildSupervisor)
    metadata_only? = Map.get(opts, :metadata_only?, false)

    discoveries = Map.get(opts, :discoveries) || Discovery.discover(discovery_opts(opts))
    Enum.each(discoveries, &register_discovery(&1, registry, child_supervisor, metadata_only?))
  end

  defp register_discovery(
         {:module, module, registration_opts},
         registry,
         child_supervisor,
         metadata_only?
       ) do
    registration_opts =
      registration_opts
      |> Keyword.put(:server, registry)
      |> maybe_suppress_side_effects(metadata_only?)

    case Registry.register_module(module, registration_opts) do
      {:ok, plugin_id} ->
        Logger.info(
          "Plugin #{if(metadata_only?, do: "metadata ", else: "")}registered: #{plugin_id}"
        )

        unless metadata_only?, do: start_plugin_child(plugin_id, registry, child_supervisor)

      {:error, reason} ->
        Logger.warning("Plugin registration failed: #{inspect(module)}: #{inspect(reason)}")
    end
  end

  defp register_discovery({:entry, entry}, registry, child_supervisor, metadata_only?) do
    case Registry.register_entry(entry, server: registry, side_effects: !metadata_only?) do
      {:ok, plugin_id} ->
        Logger.info(
          "Plugin #{if(metadata_only?, do: "metadata ", else: "")}registered: #{plugin_id}"
        )

        unless metadata_only?, do: start_plugin_child(plugin_id, registry, child_supervisor)

      {:error, reason} ->
        Logger.warning("Plugin registration failed: #{entry.plugin_id}: #{inspect(reason)}")
    end
  end

  defp register_discovery(
         {:diagnostic, key, diagnostics},
         registry,
         _child_supervisor,
         _metadata_only?
       ) do
    Registry.put_diagnostics(to_string(key), diagnostics, server: registry)
  end

  defp start_plugin_child(plugin_id, registry, child_supervisor) do
    with {:ok, entry} <- Registry.lookup(plugin_id, server: registry),
         false <- entry.children == :ignore do
      child_spec = Supervisor.child_spec(entry.children, [])

      case existing_child_id?(registry, plugin_id, child_spec.id) do
        true ->
          Registry.put_diagnostics(plugin_id, [duplicate_child_diagnostic(child_spec)],
            server: registry
          )

          {:error, :duplicate_child_id}

        false ->
          start_child(plugin_id, child_supervisor, child_spec, registry)
      end
    else
      _other -> :ok
    end
  rescue
    exception ->
      Registry.put_diagnostics(plugin_id, [child_start_diagnostic(Exception.message(exception))],
        server: registry
      )

      {:error, :plugin_child_start_failed}
  end

  defp start_child(plugin_id, child_supervisor, child_spec, registry) do
    case DynamicSupervisor.start_child(child_supervisor, child_spec) do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      {:error, {:already_started, _pid}} ->
        Registry.put_diagnostics(plugin_id, [duplicate_child_diagnostic(child_spec)],
          server: registry
        )

        {:error, :duplicate_child_id}

      {:error, {:already_present, _pid}} ->
        Registry.put_diagnostics(plugin_id, [duplicate_child_diagnostic(child_spec)],
          server: registry
        )

        {:error, :duplicate_child_id}

      {:error, reason} ->
        Registry.put_diagnostics(plugin_id, [child_start_diagnostic(reason)], server: registry)
        {:error, {:plugin_child_start_failed, reason}}
    end
  end

  defp existing_child_id?(registry, plugin_id, child_id) do
    Registry.registered_plugins(server: registry)
    |> Enum.reject(&(&1.plugin_id == plugin_id or &1.children == :ignore))
    |> Enum.any?(fn entry ->
      entry.children
      |> Supervisor.child_spec([])
      |> Map.get(:id)
      |> Kernel.==(child_id)
    end)
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

  defp maybe_suppress_side_effects(opts, true), do: Keyword.put(opts, :side_effects, false)
  defp maybe_suppress_side_effects(opts, false), do: opts
end
