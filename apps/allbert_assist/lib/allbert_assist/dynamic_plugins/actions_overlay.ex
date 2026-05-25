defmodule AllbertAssist.DynamicPlugins.ActionsOverlay do
  @moduledoc """
  Runtime overlay for v0.37 integrated dynamic action modules.

  This is a plain GenServer because it owns a small, mutable registration table
  for already-reviewed modules. The source of durable truth remains file-backed
  integration metadata under Allbert Home; this process only makes that authority
  visible to `AllbertAssist.Actions.Registry` while the loader is enabled.
  """

  use GenServer

  alias AllbertAssist.Action

  @type entry :: %{
          required(:name) => String.t(),
          required(:module) => module(),
          required(:slug) => String.t(),
          required(:revision) => String.t(),
          required(:exposure) => :agent | :internal,
          optional(:app_id) => atom() | nil
        }

  @doc "Start the overlay table."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @impl true
  def init(_opts) do
    {:ok, %{entries: %{}, diagnostics: []}}
  end

  @doc "Return integrated dynamic action modules in registration order."
  @spec modules() :: [module()]
  def modules(server \\ __MODULE__) do
    call_or_default(server, :modules, [])
  end

  @doc "Return intent-agent-visible dynamic action modules."
  @spec agent_modules() :: [module()]
  def agent_modules(server \\ __MODULE__) do
    call_or_default(server, :agent_modules, [])
  end

  @doc "Return internal-only dynamic action modules."
  @spec internal_modules() :: [module()]
  def internal_modules(server \\ __MODULE__) do
    call_or_default(server, :internal_modules, [])
  end

  @doc "Return dynamic action modules attributed to an app id."
  @spec actions_for_app(atom()) :: [module()]
  def actions_for_app(app_id, server \\ __MODULE__)

  def actions_for_app(app_id, server) when is_atom(app_id) do
    call_or_default(server, {:actions_for_app, app_id}, [])
  end

  def actions_for_app(_app_id, _server), do: []

  @doc "Return overlay diagnostics."
  @spec diagnostics() :: [map()]
  def diagnostics(server \\ __MODULE__) do
    call_or_default(server, :diagnostics, [])
  end

  @doc "Register a set of reviewed dynamic action entries atomically."
  @spec register_many([entry()], keyword()) :: :ok | {:error, term()}
  def register_many(entries, opts \\ []) when is_list(entries) do
    server = Keyword.get(opts, :server, __MODULE__)
    existing_names = Keyword.get(opts, :existing_names, [])

    case Process.whereis(server) do
      nil -> {:error, :actions_overlay_not_started}
      _pid -> GenServer.call(server, {:register_many, entries, existing_names})
    end
  end

  @doc "Unregister all actions owned by one slug/revision."
  @spec unregister(String.t(), String.t() | nil, keyword()) :: {:ok, [entry()]}
  def unregister(slug, revision \\ nil, opts \\ []) when is_binary(slug) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Process.whereis(server) do
      nil -> {:ok, []}
      _pid -> GenServer.call(server, {:unregister, slug, revision})
    end
  end

  @doc "Clear all live dynamic action registrations."
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Process.whereis(server) do
      nil -> :ok
      _pid -> GenServer.call(server, :clear)
    end
  end

  @impl true
  def handle_call(:modules, _from, state) do
    {:reply, modules_from(state.entries), state}
  end

  def handle_call(:agent_modules, _from, state) do
    {:reply, filtered_modules(state.entries, :agent), state}
  end

  def handle_call(:internal_modules, _from, state) do
    {:reply, filtered_modules(state.entries, :internal), state}
  end

  def handle_call({:actions_for_app, app_id}, _from, state) do
    modules =
      state.entries
      |> Map.values()
      |> Enum.filter(&(Map.get(&1, :app_id) == app_id))
      |> Enum.map(& &1.module)

    {:reply, modules, state}
  end

  def handle_call(:diagnostics, _from, state) do
    {:reply, Enum.reverse(state.diagnostics), state}
  end

  def handle_call({:register_many, entries, existing_names}, _from, state) do
    case validate_entries(entries, existing_names, state.entries) do
      {:ok, normalized} ->
        entries =
          Enum.reduce(normalized, state.entries, fn entry, acc ->
            Map.put(acc, entry.name, entry)
          end)

        {:reply, :ok, %{state | entries: entries}}

      {:error, reason, diagnostics} ->
        {:reply, {:error, reason}, append_diagnostics(state, diagnostics)}
    end
  end

  def handle_call({:unregister, slug, revision}, _from, state) do
    {removed, kept} =
      Enum.split_with(state.entries, fn {_name, entry} ->
        entry.slug == slug and (is_nil(revision) or entry.revision == revision)
      end)

    {:reply, {:ok, Enum.map(removed, fn {_name, entry} -> entry end)},
     %{state | entries: Map.new(kept)}}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: %{}}}
  end

  defp call_or_default(server, message, default) do
    case Process.whereis(server) do
      nil -> default
      _pid -> GenServer.call(server, message)
    end
  end

  defp modules_from(entries) do
    entries
    |> Map.values()
    |> Enum.sort_by(&{&1.slug, &1.revision, &1.name})
    |> Enum.map(& &1.module)
  end

  defp filtered_modules(entries, exposure) do
    entries
    |> Map.values()
    |> Enum.filter(&(&1.exposure == exposure))
    |> Enum.sort_by(&{&1.slug, &1.revision, &1.name})
    |> Enum.map(& &1.module)
  end

  defp validate_entries(entries, existing_names, current_entries) do
    normalized = Enum.map(entries, &normalize_entry/1)

    diagnostics =
      normalized
      |> Enum.flat_map(&entry_diagnostics(&1))
      |> Kernel.++(duplicate_input_diagnostics(normalized))
      |> Kernel.++(collision_diagnostics(normalized, existing_names, current_entries))

    if diagnostics == [] do
      {:ok, normalized}
    else
      {:error, :dynamic_action_overlay_rejected, diagnostics}
    end
  end

  defp normalize_entry(entry) when is_map(entry) do
    module = Map.fetch!(entry, :module)
    name = Map.get(entry, :name) || action_name(module)

    %{
      name: normalize_name(name),
      module: module,
      slug: to_string(Map.fetch!(entry, :slug)),
      revision: to_string(Map.fetch!(entry, :revision)),
      exposure: Map.get(entry, :exposure, :internal),
      app_id: Map.get(entry, :app_id)
    }
  end

  defp action_name(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
      module.name()
    end
  end

  defp entry_diagnostics(entry) do
    []
    |> maybe_add(not Code.ensure_loaded?(entry.module), %{
      kind: :module_not_loaded,
      severity: :error,
      message: "Dynamic action module is not loaded.",
      action_module: entry.module,
      action_name: entry.name,
      slug: entry.slug,
      revision: entry.revision
    })
    |> maybe_add(not function_exported?(entry.module, :name, 0), %{
      kind: :missing_action_name,
      severity: :error,
      message: "Dynamic action module does not export name/0.",
      action_module: entry.module,
      action_name: entry.name,
      slug: entry.slug,
      revision: entry.revision
    })
    |> maybe_add(not valid_capability?(entry.module), %{
      kind: :invalid_action_capability,
      severity: :error,
      message: "Dynamic action module does not expose valid Allbert capability metadata.",
      action_module: entry.module,
      action_name: entry.name,
      slug: entry.slug,
      revision: entry.revision
    })
    |> maybe_add(entry.exposure not in [:agent, :internal], %{
      kind: :invalid_exposure,
      severity: :error,
      message: "Dynamic action exposure must be :agent or :internal.",
      action_module: entry.module,
      action_name: entry.name,
      slug: entry.slug,
      revision: entry.revision
    })
  end

  defp valid_capability?(module) do
    function_exported?(module, :capability, 0) and
      match?({:ok, _attrs}, Action.validate_capability(module.capability()))
  rescue
    _exception -> false
  end

  defp duplicate_input_diagnostics(entries) do
    entries
    |> Enum.frequencies_by(& &1.name)
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} ->
      %{
        kind: :duplicate_dynamic_action_name,
        severity: :error,
        message: "Dynamic integration declared the same action name more than once.",
        action_name: name
      }
    end)
  end

  defp collision_diagnostics(entries, existing_names, current_entries) do
    existing_names = MapSet.new(Enum.map(existing_names, &normalize_name/1))
    current_names = MapSet.new(Map.keys(current_entries))

    entries
    |> Enum.flat_map(fn entry ->
      []
      |> maybe_add(MapSet.member?(existing_names, entry.name), %{
        kind: :dynamic_action_name_collision,
        severity: :error,
        message: "Dynamic action name collides with an existing registered action.",
        action_name: entry.name,
        action_module: entry.module,
        slug: entry.slug,
        revision: entry.revision
      })
      |> maybe_add(MapSet.member?(current_names, entry.name), %{
        kind: :dynamic_action_name_collision,
        severity: :error,
        message: "Dynamic action name collides with a live dynamic action.",
        action_name: entry.name,
        action_module: entry.module,
        slug: entry.slug,
        revision: entry.revision
      })
    end)
  end

  defp append_diagnostics(state, diagnostics) do
    %{state | diagnostics: Enum.reverse(diagnostics) ++ state.diagnostics}
  end

  defp maybe_add(diagnostics, true, diagnostic), do: [diagnostic | diagnostics]
  defp maybe_add(diagnostics, false, _diagnostic), do: diagnostics

  defp normalize_name(nil), do: ""

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
