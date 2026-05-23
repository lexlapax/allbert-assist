defmodule AllbertAssist.App.Registry do
  @moduledoc """
  Volatile registry for lite Allbert workspace app contracts.

  v0.31 keeps this as the current app registry facade. M7 adds
  `AllbertAssist.Extensions.Registry` as the unified contribution index over
  compiled app and plugin contributions.
  """

  use GenServer

  alias AllbertAssist.App.Validator
  alias AllbertAssist.Settings

  @default_table :allbert_app_registry
  @nil_aliases ["", "none", "general"]
  @control_opts [:server]

  defstruct table_name: @default_table,
            enabled?: true,
            dynamic_supervisor: AllbertAssist.App.DynamicSupervisor,
            diagnostics: %{},
            order: []

  @type app_entry :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, configured(:table_name, @default_table))

    enabled? =
      Keyword.get(
        opts,
        :enabled?,
        configured(:enabled?, setting_enabled?("app_registry.registration_enabled"))
      )

    dynamic_supervisor =
      Keyword.get(opts, :dynamic_supervisor, AllbertAssist.App.DynamicSupervisor)

    table =
      if enabled? do
        :ets.new(table_name, [:named_table, :set, :protected, read_concurrency: true])
      else
        table_name
      end

    {:ok,
     %__MODULE__{table_name: table, enabled?: enabled?, dynamic_supervisor: dynamic_supervisor}}
  end

  @spec register(module(), keyword()) :: {:ok, atom()} | {:error, term()}
  def register(module, opts \\ []) do
    GenServer.call(server(opts), {:register, module, registration_opts(opts)})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec unregister(atom(), keyword()) :: :ok
  def unregister(app_id, opts \\ []) do
    GenServer.call(server(opts), {:unregister, app_id})
  catch
    :exit, _reason -> :ok
  end

  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    GenServer.call(server(opts), :clear)
  catch
    :exit, _reason -> :ok
  end

  @spec lookup(atom(), keyword()) :: {:ok, app_entry()} | {:error, :not_found}
  def lookup(app_id, opts \\ []) do
    call(opts, {:lookup, app_id}, {:error, :not_found})
  end

  @spec registered_apps(keyword()) :: [app_entry()]
  def registered_apps(opts \\ []) do
    call(opts, :registered_apps, [])
  end

  @spec registered_surfaces(keyword()) :: [map()]
  def registered_surfaces(opts \\ []) do
    call(opts, :registered_surfaces, [])
  end

  @spec registered_agents(keyword()) :: [%{app_id: atom(), module: module()}]
  def registered_agents(opts \\ []) do
    call(opts, :registered_agents, [])
  end

  @spec registered_signals(keyword()) :: [
          %{app_id: atom(), emits: [String.t()], subscribes: [String.t()]}
        ]
  def registered_signals(opts \\ []) do
    call(opts, :registered_signals, [])
  end

  @spec registered_settings_schema(keyword()) :: [map()]
  def registered_settings_schema(opts \\ []) do
    call(opts, :registered_settings_schema, [])
  end

  @spec registered_memory_namespaces(keyword()) :: [
          AllbertAssist.App.memory_namespace_declaration()
        ]
  def registered_memory_namespaces(opts \\ []) do
    call(opts, :registered_memory_namespaces, [])
  end

  @spec registered_surface_providers(keyword()) :: [
          %{
            app_id: atom(),
            module: module(),
            surfaces: [AllbertAssist.Surface.t()],
            catalog: [map()]
          }
        ]
  def registered_surface_providers(opts \\ []) do
    call(opts, :registered_surface_providers, [])
  end

  @spec registered_skill_paths(keyword()) :: [%{app_id: atom(), path: Path.t()}]
  def registered_skill_paths(opts \\ []) do
    call(opts, :registered_skill_paths, [])
  end

  @spec known_app_id?(atom(), keyword()) :: boolean()
  def known_app_id?(app_id, opts \\ []) do
    call(opts, {:known_app_id?, app_id}, false)
  end

  @spec normalize_app_id(term(), keyword()) :: {:ok, atom() | nil} | {:error, :unknown_app}
  def normalize_app_id(app_id, opts \\ [])
  def normalize_app_id(nil, _opts), do: {:ok, nil}

  def normalize_app_id(app_id, opts) when is_atom(app_id) do
    if known_app_id?(app_id, opts), do: {:ok, app_id}, else: {:error, :unknown_app}
  end

  def normalize_app_id(app_id, opts) when is_binary(app_id) do
    normalized =
      app_id
      |> String.trim()
      |> String.downcase()

    cond do
      normalized in @nil_aliases ->
        {:ok, nil}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, normalized) ->
        {:error, :unknown_app}

      true ->
        atom = String.to_existing_atom(normalized)
        normalize_app_id(atom, opts)
    end
  rescue
    ArgumentError -> {:error, :unknown_app}
  end

  def normalize_app_id(_app_id, _opts), do: {:error, :unknown_app}

  @spec actions_for(atom(), keyword()) :: [module()]
  def actions_for(app_id, opts \\ []) do
    call(opts, {:actions_for, app_id}, [])
  end

  @spec app_id_for_action(module(), keyword()) :: atom() | nil
  def app_id_for_action(action_module, opts \\ []) do
    call(opts, {:app_id_for_action, action_module}, nil)
  end

  @spec diagnostics(keyword()) :: map()
  def diagnostics(opts \\ []) do
    call(opts, :diagnostics, %{})
  end

  @impl true
  def handle_call({:register, _module, _opts}, _from, %{enabled?: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({:register, module, opts}, _from, state) do
    with {:ok, attrs} <- validate(module, opts),
         :ok <- ensure_available(attrs.app_id, state),
         :ok <- ensure_memory_namespace_available(attrs, state),
         {:ok, child_id, child_pid} <- start_child(module, opts, state) do
      entry =
        attrs
        |> Map.put(:child_id, child_id)
        |> Map.put(:child_pid, child_pid)
        |> Map.put(:registered_at_ms, System.system_time(:millisecond))
        |> Map.put(:metadata, %{})

      true = :ets.insert(state.table_name, {entry.app_id, entry})

      state =
        state
        |> put_diagnostics(entry.app_id, cross_surface_diagnostics(entry, state))
        |> Map.update!(:order, &append_unique(&1, entry.app_id))

      {:reply, {:ok, entry.app_id}, state}
    else
      {:error, reason, diagnostics} ->
        app_id = app_id_for_diagnostics(module)
        state = put_diagnostics(state, app_id, diagnostics)
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        app_id = app_id_for_diagnostics(module)
        state = put_diagnostics(state, app_id, [diagnostic(reason)])
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, app_id}, _from, state) do
    case lookup_entry(app_id, state) do
      {:ok, entry} ->
        terminate_child(entry, state)
        :ets.delete(state.table_name, app_id)

        state =
          state
          |> Map.update!(:diagnostics, &Map.delete(&1, app_id))
          |> Map.update!(:order, &List.delete(&1, app_id))

        {:reply, :ok, state}

      {:error, :not_found} ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:clear, _from, state) do
    if state.enabled?, do: :ets.delete_all_objects(state.table_name)
    {:reply, :ok, %{state | diagnostics: %{}, order: []}}
  end

  def handle_call({:lookup, app_id}, _from, state),
    do: {:reply, lookup_entry(app_id, state), state}

  def handle_call(:registered_apps, _from, state), do: {:reply, entries_in_order(state), state}

  def handle_call(:registered_surfaces, _from, state) do
    surfaces = state |> entries_in_order() |> Enum.flat_map(&entry_surfaces/1)
    {:reply, surfaces, state}
  end

  def handle_call(:registered_agents, _from, state) do
    agents =
      state
      |> entries_in_order()
      |> Enum.flat_map(fn entry ->
        entry
        |> Map.get(:agents, [])
        |> Enum.map(&%{app_id: entry.app_id, module: &1})
      end)

    {:reply, agents, state}
  end

  def handle_call(:registered_signals, _from, state) do
    signals =
      state
      |> entries_in_order()
      |> Enum.map(fn entry ->
        signals = Map.get(entry, :signals, %{emits: [], subscribes: []})
        %{app_id: entry.app_id, emits: signals.emits, subscribes: signals.subscribes}
      end)

    {:reply, signals, state}
  end

  def handle_call(:registered_settings_schema, _from, state) do
    schema =
      state
      |> entries_in_order()
      |> Enum.flat_map(&Map.get(&1, :settings_schema, []))

    {:reply, schema, state}
  end

  def handle_call(:registered_memory_namespaces, _from, state) do
    namespaces =
      state
      |> entries_in_order()
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, :memory_namespace) do
          nil -> []
          namespace -> [namespace]
        end
      end)

    {:reply, namespaces, state}
  end

  def handle_call(:registered_surface_providers, _from, state) do
    providers =
      state
      |> entries_in_order()
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, :surface_provider) do
          nil ->
            []

          provider ->
            [
              %{
                app_id: entry.app_id,
                module: provider,
                surfaces: Map.get(entry, :provider_surfaces, []),
                catalog: Map.get(entry, :surface_catalog, [])
              }
            ]
        end
      end)

    {:reply, providers, state}
  end

  def handle_call(:registered_skill_paths, _from, state) do
    paths =
      state
      |> entries_in_order()
      |> Enum.flat_map(fn entry ->
        Enum.map(entry.skill_paths, &%{app_id: entry.app_id, path: &1})
      end)

    {:reply, paths, state}
  end

  def handle_call({:known_app_id?, app_id}, _from, state) do
    {:reply, match?({:ok, _entry}, lookup_entry(app_id, state)), state}
  end

  def handle_call({:actions_for, app_id}, _from, state) do
    actions =
      case lookup_entry(app_id, state) do
        {:ok, entry} -> entry.actions
        {:error, :not_found} -> []
      end

    {:reply, actions, state}
  end

  def handle_call({:app_id_for_action, action_module}, _from, state) do
    app_id =
      state
      |> entries_in_order()
      |> Enum.find_value(fn entry ->
        if action_module in entry.actions, do: entry.app_id
      end)

    {:reply, app_id, state}
  end

  def handle_call(:diagnostics, _from, state), do: {:reply, state.diagnostics, state}

  defp validate(module, opts), do: Validator.validate(module, opts)

  defp ensure_available(app_id, state) do
    case lookup_entry(app_id, state) do
      {:ok, _entry} -> {:error, {:app_id_taken, app_id}}
      {:error, :not_found} -> :ok
    end
  end

  defp ensure_memory_namespace_available(%{memory_namespace: nil}, _state), do: :ok

  defp ensure_memory_namespace_available(%{memory_namespace: %{namespace: namespace}}, state) do
    state
    |> entries_in_order()
    |> Enum.find_value(&memory_namespace_conflict(namespace, &1))
    |> case do
      nil -> :ok
      error -> error
    end
  end

  defp memory_namespace_conflict(namespace, %{memory_namespace: %{namespace: existing}}) do
    if namespace_conflict?(namespace, existing),
      do: {:error, {:memory_namespace_taken, namespace, existing}}
  end

  defp memory_namespace_conflict(_namespace, _entry), do: nil

  defp namespace_conflict?(left, right) do
    left = Atom.to_string(left)
    right = Atom.to_string(right)

    left == right or String.starts_with?(left, right <> "_") or
      String.starts_with?(right, left <> "_")
  end

  defp start_child(module, opts, state) do
    case module.child_spec(opts) do
      :ignore ->
        {:ok, :ignore, :ignore}

      spec ->
        child_spec = Supervisor.child_spec(spec, [])

        case DynamicSupervisor.start_child(state.dynamic_supervisor, child_spec) do
          {:ok, pid} -> {:ok, child_spec.id, pid}
          {:ok, pid, _info} -> {:ok, child_spec.id, pid}
          {:error, reason} -> {:error, {:child_spec_failed, reason}}
        end
    end
  rescue
    exception -> {:error, {:child_spec_failed, Exception.message(exception)}}
  end

  defp terminate_child(%{child_pid: :ignore}, _state), do: :ok
  defp terminate_child(%{child_pid: nil}, _state), do: :ok

  defp terminate_child(%{child_pid: pid}, state) when is_pid(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(state.dynamic_supervisor, pid)
    else
      :ok
    end
  rescue
    _exception -> :ok
  end

  defp lookup_entry(_app_id, %{enabled?: false}), do: {:error, :not_found}

  defp lookup_entry(app_id, state) when is_atom(app_id) do
    case :ets.lookup(state.table_name, app_id) do
      [{^app_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  defp lookup_entry(_app_id, _state), do: {:error, :not_found}

  defp entries_in_order(%{enabled?: false}), do: []

  defp entries_in_order(state) do
    Enum.flat_map(state.order, fn app_id ->
      case lookup_entry(app_id, state) do
        {:ok, entry} -> [entry]
        {:error, :not_found} -> []
      end
    end)
  end

  defp cross_surface_diagnostics(entry, state) do
    existing_surfaces =
      state
      |> entries_in_order()
      |> Enum.flat_map(&entry_surfaces/1)

    existing_ids =
      existing_surfaces
      |> MapSet.new(& &1.id)

    existing_paths =
      existing_surfaces
      |> MapSet.new(& &1.path)

    entry_surfaces = entry_surfaces(entry)

    duplicate_id_diagnostics =
      entry_surfaces
      |> Enum.filter(&MapSet.member?(existing_ids, &1.id))
      |> Enum.map(fn surface ->
        %{
          kind: :duplicate_surface_id,
          severity: :warning,
          message: "Surface id #{inspect(surface.id)} is already registered by another app.",
          detail: %{surface_id: surface.id, app_id: entry.app_id}
        }
      end)

    duplicate_path_diagnostics =
      entry_surfaces
      |> Enum.filter(&MapSet.member?(existing_paths, &1.path))
      |> Enum.map(fn surface ->
        %{
          kind: :duplicate_route_path,
          severity: :warning,
          message: "Surface path #{inspect(surface.path)} is already registered by another app.",
          detail: %{surface_id: surface.id, path: surface.path, app_id: entry.app_id}
        }
      end)

    duplicate_id_diagnostics ++ duplicate_path_diagnostics
  end

  defp entry_surfaces(entry) do
    provider_surfaces =
      entry
      |> Map.get(:provider_surfaces, [])
      |> Enum.map(&surface_summary/1)

    provider_ids = MapSet.new(provider_surfaces, & &1.id)

    legacy_surfaces =
      entry
      |> Map.get(:surfaces, [])
      |> Enum.reject(&MapSet.member?(provider_ids, &1.id))

    legacy_surfaces ++ provider_surfaces
  end

  defp surface_summary(%AllbertAssist.Surface{} = surface) do
    %{
      id: surface.id,
      label: surface.label,
      path: surface.path,
      app_id: surface.app_id,
      kind: surface.kind,
      status: surface.status,
      provider?: true
    }
  end

  defp surface_summary(%{} = surface) do
    Map.put_new(surface, :provider?, false)
  end

  defp put_diagnostics(state, _key, []), do: state

  defp put_diagnostics(state, key, diagnostics),
    do: Map.update!(state, :diagnostics, &Map.put(&1, key, diagnostics))

  defp app_id_for_diagnostics(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :app_id, 0) do
      module.app_id()
    else
      module
    end
  rescue
    _exception -> module
  end

  defp app_id_for_diagnostics(module), do: module

  defp append_unique(order, app_id) do
    if app_id in order, do: order, else: order ++ [app_id]
  end

  defp registration_opts(opts) when is_list(opts), do: Keyword.drop(opts, @control_opts)
  defp registration_opts(opts), do: opts

  defp server(opts) when is_list(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp server(_opts), do: __MODULE__

  defp call(opts, message, default) do
    GenServer.call(server(opts), message)
  catch
    :exit, _reason -> default
  end

  defp configured(key, default) do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp setting_enabled?(key) do
    case Settings.get(key) do
      {:ok, value} when is_boolean(value) -> value
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp diagnostic({kind, _detail} = reason) when is_atom(kind),
    do: %{kind: kind, message: inspect(reason), detail: %{reason: inspect(reason)}}

  defp diagnostic(reason) when is_tuple(reason) do
    kind =
      reason
      |> elem(0)
      |> case do
        atom when is_atom(atom) -> atom
        _other -> :error
      end

    %{kind: kind, message: inspect(reason), detail: %{reason: inspect(reason)}}
  end
end
