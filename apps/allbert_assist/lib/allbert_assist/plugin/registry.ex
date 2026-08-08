defmodule AllbertAssist.Plugin.Registry do
  @moduledoc """
  Volatile registry for local Allbert plugin contributions.

  v0.31 keeps this as the current plugin registry facade. M7 adds
  `AllbertAssist.Extensions.Registry` as the unified contribution index over
  compiled app and plugin contributions.
  """

  use GenServer

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Pack.{EffectGuard, Readiness}
  alias AllbertAssist.Plugin.Entry
  alias AllbertAssist.Plugin.Registry.{MetadataEntry, MetadataSnapshot}
  alias AllbertAssist.Plugin.Validator
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments
  alias AllbertAssist.Signals

  @default_table :allbert_plugin_registry
  @control_opts [:server, :side_effects]
  @mutation_timeout_ms 60_000
  @mutation_poll_ms 25

  defstruct table_name: @default_table,
            enabled?: true,
            diagnostics: %{},
            order: [],
            mutations: %{},
            generation: 0,
            metadata_subscriptions: %{},
            epoch_binding: nil

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
        configured(:enabled?, setting_enabled?("plugins.registration_enabled"))
      )

    table =
      if enabled? do
        :ets.new(table_name, [:named_table, :set, :protected, read_concurrency: true])
      else
        table_name
      end

    {:ok, %__MODULE__{table_name: table, enabled?: enabled?}}
  end

  @spec register_module(module(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register_module(module, opts \\ []) do
    selected_server = server(opts)
    admission = mutation_admission(selected_server, opts)

    result =
      selected_server
      |> GenServer.call({:register_module, module, registration_opts(opts), admission})
      |> finish_registration(selected_server)

    if match?({:ok, _plugin_id}, result) and side_effects?(opts) do
      clear_settings_schema_cache()
      {:ok, plugin_id} = result
      emit_plugin_registered(plugin_id, opts)
    end

    result
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec register_manifest(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register_manifest(manifest, opts \\ []) do
    selected_server = server(opts)
    admission = mutation_admission(selected_server, opts)

    result =
      selected_server
      |> GenServer.call({:register_manifest, manifest, registration_opts(opts), admission})
      |> finish_registration(selected_server)

    if match?({:ok, _plugin_id}, result) and side_effects?(opts) do
      clear_settings_schema_cache()
      {:ok, plugin_id} = result
      emit_plugin_registered(plugin_id, opts)
    end

    result
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec register_entry(Entry.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register_entry(%Entry{} = entry, opts \\ []) do
    selected_server = server(opts)
    admission = mutation_admission(selected_server, opts)

    result =
      selected_server
      |> GenServer.call({:register_entry, entry, admission})
      |> finish_registration(selected_server)

    if match?({:ok, _plugin_id}, result) and side_effects?(opts) do
      clear_settings_schema_cache()
      {:ok, plugin_id} = result
      emit_plugin_registered(plugin_id, opts)
    end

    result
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec put_diagnostics(String.t(), [map()], keyword()) :: :ok
  def put_diagnostics(plugin_id, diagnostics, opts \\ [])
      when is_binary(plugin_id) and is_list(diagnostics) do
    GenServer.call(server(opts), {:put_diagnostics, plugin_id, diagnostics})
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec mark_child_activation(String.t(), :ok | {:error, term()}, keyword()) :: :ok
  def mark_child_activation(plugin_id, result, opts \\ []) when is_binary(plugin_id) do
    GenServer.call(server(opts), {:mark_child_activation, plugin_id, result})
  catch
    :exit, _reason -> :ok
  end

  @spec registered_plugins(keyword()) :: [Entry.t()]
  def registered_plugins(opts \\ []) do
    opts
    |> call(:registered_plugins, [])
    |> Enum.filter(&(&1.status == :enabled))
  end

  @doc false
  @spec snapshot_and_subscribe(pid(), keyword()) ::
          {:ok, MetadataSnapshot.t(), reference()} | {:error, :unavailable}
  def snapshot_and_subscribe(subscriber, opts \\ [])

  def snapshot_and_subscribe(subscriber, opts) when is_pid(subscriber) do
    call(opts, {:snapshot_and_subscribe, subscriber}, {:error, :unavailable})
  end

  def snapshot_and_subscribe(_subscriber, _opts), do: {:error, :unavailable}

  @doc false
  @spec bind_epoch(reference(), non_neg_integer(), pid(), keyword()) ::
          :ok
          | {:error, :stale_generation | :stale_subscription | :already_bound | :unavailable}
  def bind_epoch(subscription_ref, generation, barrier_pid, opts \\ []) do
    call(
      opts,
      {:bind_epoch, subscription_ref, generation, barrier_pid},
      {:error, :unavailable}
    )
  end

  @spec lookup(String.t(), keyword()) :: {:ok, Entry.t()} | {:error, :not_found}
  def lookup(plugin_id, opts \\ [])

  def lookup(plugin_id, opts) when is_binary(plugin_id) do
    call(opts, {:lookup, plugin_id}, {:error, :not_found})
  end

  def lookup(_plugin_id, _opts), do: {:error, :not_found}

  @spec diagnostics(keyword()) :: map()
  def diagnostics(opts \\ []), do: call(opts, :diagnostics, %{})

  @spec registered_apps(keyword()) :: [module()]
  def registered_apps(opts \\ []) do
    opts |> registered_plugins() |> Enum.flat_map(& &1.apps)
  end

  @spec registered_channels(keyword()) :: [map()]
  def registered_channels(opts \\ []) do
    opts |> registered_plugins() |> Enum.flat_map(& &1.channels)
  end

  @spec registered_actions(keyword()) :: [module()]
  def registered_actions(opts \\ []) do
    opts |> registered_plugins() |> Enum.flat_map(& &1.actions)
  end

  @spec registered_skill_paths(keyword()) :: [
          %{plugin_id: String.t(), path: Path.t(), trust_status: atom(), source: atom()}
        ]
  def registered_skill_paths(opts \\ []) do
    opts
    |> registered_plugins()
    |> Enum.flat_map(fn entry ->
      Enum.map(entry.skill_paths, fn path ->
        %{
          plugin_id: entry.plugin_id,
          path: path,
          trust_status: entry.trust_status,
          source: entry.source
        }
      end)
    end)
  end

  @spec registered_settings_schema(keyword()) :: [map()]
  def registered_settings_schema(opts \\ []) do
    opts |> registered_plugins() |> Enum.flat_map(& &1.settings_schema)
  end

  @spec registered_child_specs(keyword()) :: [%{plugin_id: String.t(), child_spec: term()}]
  def registered_child_specs(opts \\ []) do
    opts
    |> registered_plugins()
    |> Enum.reject(&(&1.children == :ignore))
    |> Enum.map(&%{plugin_id: &1.plugin_id, child_spec: &1.children})
  end

  @spec plugin_id_for_action(module(), keyword()) :: String.t() | nil
  def plugin_id_for_action(action_module, opts \\ [])

  def plugin_id_for_action(action_module, opts) when is_atom(action_module) do
    opts
    |> registered_plugins()
    |> Enum.find_value(fn entry ->
      if action_module in entry.actions, do: entry.plugin_id
    end)
  end

  def plugin_id_for_action(_action_module, _opts), do: nil

  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    count = opts |> registered_plugins() |> length()
    result = GenServer.call(server(opts), :clear)

    if side_effects?(opts) do
      clear_settings_schema_cache()
      if count > 0, do: emit_plugin_registry_cleared(count)
    end

    result
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def handle_call({_kind, _payload, _opts}, _from, %{enabled?: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({_kind, _payload, _opts, _admission}, _from, %{enabled?: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({:register_module, module, opts, admission}, _from, state) do
    case Validator.validate_module(module, opts) do
      {:ok, entry} ->
        register_entry_reply(entry, admission, state)

      {:error, reason, diagnostics} ->
        error_reply(reason, diagnostics_key(module), diagnostics, state)
    end
  end

  def handle_call({:register_manifest, manifest, opts, admission}, _from, state) do
    case Validator.normalize_manifest(manifest, opts) do
      {:ok, entry} ->
        register_entry_reply(entry, admission, state)

      {:error, reason, diagnostics} ->
        error_reply(reason, manifest_key(manifest), diagnostics, state)
    end
  end

  def handle_call({:register_entry, %Entry{} = entry, admission}, _from, state) do
    register_entry_reply(entry, admission, state)
  end

  def handle_call({:put_diagnostics, plugin_id, diagnostics}, _from, state) do
    {:reply, :ok, put_diagnostics_state(state, plugin_id, diagnostics)}
  end

  def handle_call({:mark_child_activation, plugin_id, result}, _from, state) do
    {:reply, :ok, mark_child_activation_state(state, plugin_id, result)}
  end

  def handle_call(:registered_plugins, _from, state) do
    {:reply, entries_in_order(state), state}
  end

  def handle_call({:snapshot_and_subscribe, subscriber}, _from, state) do
    subscription_ref = make_ref()
    monitor_ref = Process.monitor(subscriber)

    subscription = %{
      pid: subscriber,
      monitor_ref: monitor_ref,
      generation: state.generation
    }

    snapshot = %MetadataSnapshot{
      schema_version: 1,
      generation: state.generation,
      entries: metadata_entries(state)
    }

    state = put_in(state.metadata_subscriptions[subscription_ref], subscription)
    {:reply, {:ok, snapshot, subscription_ref}, state}
  end

  def handle_call(
        {:bind_epoch, subscription_ref, generation, barrier_pid},
        _from,
        state
      ) do
    case bind_epoch_state(subscription_ref, generation, barrier_pid, state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, plugin_id}, _from, state) do
    {:reply, lookup_entry(plugin_id, state), state}
  end

  def handle_call(:diagnostics, _from, state), do: {:reply, state.diagnostics, state}

  def handle_call({:mutation_status, receipt, barrier_pid}, _from, state) do
    {:reply, mutation_status(receipt, barrier_pid, state), state}
  end

  def handle_call(:clear, _from, state) do
    before_entries = metadata_entries(state)

    case maybe_authorize_candidate_mutation(state, before_entries != []) do
      {:ok, state} ->
        if state.enabled?, do: :ets.delete_all_objects(state.table_name)

        state =
          %{state | diagnostics: %{}, order: [], mutations: %{}}
          |> advance_generation_if_changed(before_entries)

        {:reply, :ok, state}

      {:error, _reason} ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    {:noreply, drop_metadata_monitor(state, monitor_ref)}
  end

  defp register_entry_reply(entry, admission, state) do
    case ensure_available(entry.plugin_id, state) do
      :ok ->
        before_entries = metadata_entries(state)
        replacement_required? = admission.replacement_aware? and not is_nil(state.epoch_binding)

        with :ok <- admit_plugin_mutation(entry, admission, replacement_required?),
             {:ok, state} <- authorize_candidate_mutation(state) do
          true = :ets.insert(state.table_name, {entry.plugin_id, entry})

          state =
            state
            |> put_diagnostics_state(entry.plugin_id, entry.diagnostics)
            |> Map.update!(:order, &append_unique(&1, entry.plugin_id))
            |> advance_generation_if_changed(before_entries)

          plugin_mutation_reply(entry, admission, replacement_required?, state)
        else
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        diagnostics = [
          Validator.diagnostic(:error, :duplicate_plugin_id, "Plugin id is already registered.")
        ]

        {:reply, {:error, reason}, put_diagnostics_state(state, entry.plugin_id, diagnostics)}
    end
  end

  defp error_reply(reason, key, diagnostics, state) do
    {:reply, {:error, reason}, put_diagnostics_state(state, key, diagnostics)}
  end

  defp ensure_available(plugin_id, state) do
    case lookup_entry(plugin_id, state) do
      {:ok, _entry} -> {:error, {:plugin_id_taken, plugin_id}}
      {:error, :not_found} -> :ok
    end
  end

  defp lookup_entry(_plugin_id, %{enabled?: false}), do: {:error, :not_found}

  defp lookup_entry(plugin_id, state) when is_binary(plugin_id) do
    case :ets.lookup(state.table_name, plugin_id) do
      [{^plugin_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  defp entries_in_order(%{enabled?: false}), do: []

  defp entries_in_order(state) do
    Enum.flat_map(state.order, fn plugin_id ->
      case lookup_entry(plugin_id, state) do
        {:ok, entry} -> [entry]
        {:error, :not_found} -> []
      end
    end)
  end

  defp metadata_entries(state) do
    state
    |> entries_in_order()
    |> Enum.map(&MetadataEntry.from_entry/1)
  end

  defp advance_generation_if_changed(state, previous_entries) do
    current_entries = metadata_entries(state)

    if current_entries == previous_entries do
      state
    else
      generation = state.generation + 1

      Enum.each(state.metadata_subscriptions, fn {subscription_ref, subscription} ->
        send(
          subscription.pid,
          {:allbert_metadata_generation_changed, self(), subscription_ref, generation}
        )
      end)

      %{state | generation: generation}
    end
  end

  defp authorize_candidate_mutation(%{epoch_binding: nil} = state), do: {:ok, state}

  defp authorize_candidate_mutation(%{epoch_binding: binding} = state) do
    case Readiness.invalidate_metadata(binding.barrier_pid, self(), binding.generation) do
      :ok ->
        Process.demonitor(binding.monitor_ref, [:flush])
        {:ok, %{state | epoch_binding: nil}}

      {:error, _reason} ->
        {:error, :product_not_ready}
    end
  end

  defp maybe_authorize_candidate_mutation(state, false), do: {:ok, state}
  defp maybe_authorize_candidate_mutation(state, true), do: authorize_candidate_mutation(state)

  defp bind_epoch_state(_subscription_ref, _generation, _barrier_pid, %{epoch_binding: binding})
       when not is_nil(binding),
       do: {:error, :already_bound}

  defp bind_epoch_state(subscription_ref, generation, barrier_pid, state)
       when is_reference(subscription_ref) and is_integer(generation) and generation >= 0 and
              is_pid(barrier_pid) do
    case Map.fetch(state.metadata_subscriptions, subscription_ref) do
      :error ->
        {:error, :stale_subscription}

      {:ok, %{generation: captured_generation}}
      when captured_generation != generation or generation != state.generation ->
        {:error, :stale_generation}

      {:ok, _subscription} ->
        case Readiness.bind_metadata(barrier_pid, self(), generation, subscription_ref) do
          :ok ->
            monitor_ref = Process.monitor(barrier_pid)

            {:ok,
             %{
               state
               | epoch_binding: %{
                   barrier_pid: barrier_pid,
                   generation: generation,
                   subscription_ref: subscription_ref,
                   monitor_ref: monitor_ref
                 }
             }}

          {:error, _reason} ->
            {:error, :unavailable}
        end
    end
  end

  defp bind_epoch_state(_subscription_ref, _generation, _barrier_pid, _state),
    do: {:error, :unavailable}

  defp drop_metadata_monitor(state, monitor_ref) do
    subscriptions =
      Map.reject(state.metadata_subscriptions, fn {_ref, subscription} ->
        subscription.monitor_ref == monitor_ref
      end)

    epoch_binding =
      case state.epoch_binding do
        %{monitor_ref: ^monitor_ref} -> nil
        binding -> binding
      end

    %{state | metadata_subscriptions: subscriptions, epoch_binding: epoch_binding}
  end

  defp mutation_admission(selected_server, opts) do
    global_pid = Process.whereis(__MODULE__)

    %{
      replacement_aware?:
        side_effects?(opts) and
          (selected_server == __MODULE__ or
             (is_pid(global_pid) and selected_server == global_pid))
    }
  end

  defp admit_plugin_mutation(_entry, %{replacement_aware?: false}, _replacement_required?),
    do: :ok

  defp admit_plugin_mutation(%{children: :ignore}, _admission, _replacement_required?), do: :ok

  defp admit_plugin_mutation(_entry, _admission, false), do: {:error, :product_not_ready}

  defp admit_plugin_mutation(_entry, _admission, true) do
    with {:ok, epoch} <- EffectGuard.admit_ready(), do: EffectGuard.validate(epoch)
  end

  defp plugin_mutation_reply(
         entry,
         %{replacement_aware?: true},
         true,
         state
       ) do
    mutation_ref = make_ref()
    digest = metadata_entry_digest(entry)

    mutation = %{
      mutation_ref: mutation_ref,
      generation: state.generation,
      plugin_id: entry.plugin_id,
      metadata_digest: digest,
      status: if(entry.children == :ignore, do: :activated, else: :pending),
      reason: nil
    }

    receipt = Map.take(mutation, [:mutation_ref, :generation, :plugin_id, :metadata_digest])
    {:reply, {:await_mutation, receipt}, put_in(state.mutations[entry.plugin_id], mutation)}
  end

  defp plugin_mutation_reply(entry, _admission, _replacement_required?, state),
    do: {:reply, {:ok, entry.plugin_id}, state}

  defp finish_registration({:await_mutation, receipt}, selected_server) do
    deadline = System.monotonic_time(:millisecond) + @mutation_timeout_ms
    await_plugin_mutation(selected_server, receipt, deadline)
  end

  defp finish_registration(result, _selected_server), do: result

  defp await_plugin_mutation(selected_server, receipt, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :product_not_ready}
    else
      barrier_pid =
        case Readiness.status(timeout: 1_000) do
          {:ok, %{phase: :ready, barrier_pid: pid}} -> pid
          _other -> nil
        end

      case safe_registry_call(selected_server, {:mutation_status, receipt, barrier_pid}) do
        :ready ->
          {:ok, receipt.plugin_id}

        {:failed, _reason} ->
          {:ok, receipt.plugin_id}

        _other ->
          Process.sleep(@mutation_poll_ms)
          await_plugin_mutation(selected_server, receipt, deadline)
      end
    end
  end

  defp mutation_status(receipt, barrier_pid, state) do
    with %{
           plugin_id: plugin_id,
           mutation_ref: mutation_ref,
           generation: generation,
           metadata_digest: digest
         } <- receipt,
         %{mutation_ref: ^mutation_ref, generation: ^generation, metadata_digest: ^digest} =
           mutation <- Map.get(state.mutations, plugin_id),
         {:ok, entry} <- lookup_entry(plugin_id, state),
         true <- metadata_entry_digest(entry) == digest do
      case mutation.status do
        :failed -> {:failed, mutation.reason}
        :activated -> mutation_ready_status(mutation, barrier_pid, state)
        _other -> :pending
      end
    else
      _other -> :stale
    end
  end

  defp mutation_ready_status(mutation, barrier_pid, state) do
    case state.epoch_binding do
      %{barrier_pid: ^barrier_pid, generation: generation}
      when is_pid(barrier_pid) and generation >= mutation.generation ->
        :ready

      _other ->
        :pending
    end
  end

  defp mark_child_activation_state(state, plugin_id, result) do
    case Map.fetch(state.mutations, plugin_id) do
      {:ok, mutation} ->
        next =
          case result do
            :ok -> Map.merge(mutation, %{status: :activated, reason: nil})
            {:error, reason} -> Map.merge(mutation, %{status: :failed, reason: reason})
          end

        put_in(state.mutations[plugin_id], next)

      :error ->
        state
    end
  end

  defp metadata_entry_digest(entry) do
    entry
    |> MetadataEntry.from_entry()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp safe_registry_call(selected_server, message) do
    GenServer.call(selected_server, message, 5_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp put_diagnostics_state(state, _key, []), do: state

  defp put_diagnostics_state(state, key, diagnostics) do
    Map.update!(state, :diagnostics, &Map.put(&1, key, diagnostics))
  end

  defp append_unique(order, plugin_id) do
    if plugin_id in order, do: order, else: order ++ [plugin_id]
  end

  defp diagnostics_key(module) when is_atom(module), do: inspect(module)

  defp manifest_key(%{"plugin_id" => plugin_id}) when is_binary(plugin_id), do: plugin_id
  defp manifest_key(_manifest), do: "invalid_manifest"

  defp registration_opts(opts) when is_list(opts), do: Keyword.drop(opts, @control_opts)
  defp registration_opts(opts), do: opts

  defp server(opts) when is_list(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp server(_opts), do: __MODULE__

  # v1.0.2 M2 (ADR 0082): internal-only fixture mode. `side_effects: false`
  # suppresses the shared Settings-schema cache invalidation and global
  # registration signals while keeping validation, the GenServer call, and
  # registry-local state identical. The production default stays true.
  defp side_effects?(opts) when is_list(opts), do: Keyword.get(opts, :side_effects, true)
  defp side_effects?(_opts), do: true

  defp call(opts, message, default) do
    GenServer.call(server(opts), message)
  catch
    :exit, _reason -> default
  end

  defp clear_settings_schema_cache do
    if Code.ensure_loaded?(SettingsFragments) do
      SettingsFragments.clear_cache()
    end

    :ok
  end

  defp emit_plugin_registered(plugin_id, opts) do
    metadata =
      case lookup(plugin_id, opts) do
        {:ok, entry} -> plugin_metadata(entry)
        {:error, :not_found} -> %{plugin_id: plugin_id, action_names: []}
      end

    Signals.emit_registration(:plugin_registered, metadata)
    ActionsRegistry.emit_registry_changed(:plugin_registered, metadata)
  end

  defp emit_plugin_registry_cleared(count) do
    metadata = %{cleared_count: count}
    Signals.emit_registration(:plugin_registry_cleared, metadata)
    ActionsRegistry.emit_registry_changed(:plugin_registry_cleared, metadata)
  end

  defp plugin_metadata(%Entry{} = entry) do
    %{
      plugin_id: entry.plugin_id,
      display_name: entry.display_name,
      status: entry.status,
      trust_status: entry.trust_status,
      action_names: Enum.map(entry.actions, &safe_action_name/1),
      app_modules: Enum.map(entry.apps, &inspect/1)
    }
  end

  defp safe_action_name(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
      module.name()
    else
      inspect(module)
    end
  end

  defp safe_action_name(value), do: inspect(value)

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
end
