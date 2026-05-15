defmodule AllbertAssist.Plugin.Registry do
  @moduledoc """
  Volatile registry for local Allbert plugin contributions.
  """

  use GenServer

  alias AllbertAssist.Plugin.Entry
  alias AllbertAssist.Plugin.Validator

  @default_table :allbert_plugin_registry
  @control_opts [:server]

  defstruct table_name: @default_table,
            enabled?: true,
            diagnostics: %{},
            order: []

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, configured(:table_name, @default_table))
    enabled? = Keyword.get(opts, :enabled?, configured(:enabled?, true))

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
    GenServer.call(server(opts), {:register_module, module, registration_opts(opts)})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec register_manifest(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register_manifest(manifest, opts \\ []) do
    GenServer.call(server(opts), {:register_manifest, manifest, registration_opts(opts)})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec register_entry(Entry.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register_entry(%Entry{} = entry, opts \\ []) do
    GenServer.call(server(opts), {:register_entry, entry})
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

  @spec registered_plugins(keyword()) :: [Entry.t()]
  def registered_plugins(opts \\ []), do: call(opts, :registered_plugins, [])

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
    GenServer.call(server(opts), :clear)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def handle_call({_kind, _payload, _opts}, _from, %{enabled?: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({:register_module, module, opts}, _from, state) do
    case Validator.validate_module(module, opts) do
      {:ok, entry} ->
        register_entry_reply(entry, state)

      {:error, reason, diagnostics} ->
        error_reply(reason, diagnostics_key(module), diagnostics, state)
    end
  end

  def handle_call({:register_manifest, manifest, opts}, _from, state) do
    case Validator.normalize_manifest(manifest, opts) do
      {:ok, entry} ->
        register_entry_reply(entry, state)

      {:error, reason, diagnostics} ->
        error_reply(reason, manifest_key(manifest), diagnostics, state)
    end
  end

  def handle_call({:register_entry, %Entry{} = entry}, _from, state) do
    register_entry_reply(entry, state)
  end

  def handle_call({:put_diagnostics, plugin_id, diagnostics}, _from, state) do
    {:reply, :ok, put_diagnostics_state(state, plugin_id, diagnostics)}
  end

  def handle_call(:registered_plugins, _from, state) do
    {:reply, entries_in_order(state), state}
  end

  def handle_call({:lookup, plugin_id}, _from, state) do
    {:reply, lookup_entry(plugin_id, state), state}
  end

  def handle_call(:diagnostics, _from, state), do: {:reply, state.diagnostics, state}

  def handle_call(:clear, _from, state) do
    if state.enabled?, do: :ets.delete_all_objects(state.table_name)
    {:reply, :ok, %{state | diagnostics: %{}, order: []}}
  end

  defp register_entry_reply(entry, state) do
    case ensure_available(entry.plugin_id, state) do
      :ok ->
        true = :ets.insert(state.table_name, {entry.plugin_id, entry})

        state =
          state
          |> put_diagnostics_state(entry.plugin_id, entry.diagnostics)
          |> Map.update!(:order, &append_unique(&1, entry.plugin_id))

        {:reply, {:ok, entry.plugin_id}, state}

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
end
