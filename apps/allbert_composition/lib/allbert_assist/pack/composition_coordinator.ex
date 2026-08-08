defmodule AllbertAssist.Pack.CompositionCoordinator do
  @moduledoc """
  Captures one generation-bound candidate and opens the acknowledged Pack epoch.

  This is a plain GenServer: it owns one deterministic startup handshake and
  monitors the exact inputs that made it valid. It performs no agent reasoning.
  """

  use GenServer

  alias AllbertAssist.App.Bootstrap, as: AppBootstrap
  alias AllbertAssist.App.MetadataSupervisor, as: AppMetadataSupervisor
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Pack.{CandidateBuilder, ProjectionProvider, Readiness}
  alias AllbertAssist.Pack.Registry, as: PackRegistry
  alias AllbertAssist.Pack.Supervisor, as: PackSupervisor
  alias AllbertAssist.Plugin.Bootstrap, as: PluginBootstrap
  alias AllbertAssist.Plugin.MetadataSupervisor, as: PluginMetadataSupervisor
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  @name :allbert_pack_composition_owner
  @bootstrap_timeout 30_000
  @input_retry_ms 100

  defstruct phase: :collecting,
            closed: nil,
            snapshot: nil,
            epoch: nil,
            source_generations: %{},
            bootstrap_generations: %{},
            bootstrap_completions: %{},
            monitors: %{},
            opts: []

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ @name), do: GenServer.call(server, :status, 5_000)

  @impl true
  def init(opts), do: {:ok, %__MODULE__{opts: opts}, {:continue, :compose}}

  @impl true
  def handle_continue(:compose, state) do
    case compose(state.opts) do
      {:ok, result} ->
        {:noreply,
         %{
           state
           | phase: :ready,
             closed: result.closed,
             snapshot: result.snapshot,
             epoch: result.epoch,
             source_generations: result.source_generations,
             bootstrap_generations: result.bootstrap_generations,
             bootstrap_completions: result.bootstrap_completions,
             monitors: monitor_inputs(result.monitored)
         }}

      {:error, reason} ->
        handle_compose_failure(reason, state)
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      phase: state.phase,
      behavior_digest: state.snapshot && state.snapshot.behavior_digest,
      projection_sha256: state.closed && state.closed.projection_sha256,
      epoch: state.epoch,
      source_generations: state.source_generations,
      bootstrap_generations: state.bootstrap_generations
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(
        {:allbert_metadata_generation_changed, registry_pid, _subscription_ref, generation},
        state
      ) do
    {:stop, {:metadata_generation_changed, source_name(registry_pid, state), generation}, state}
  end

  def handle_info(:retry_compose, state) do
    {:noreply, state, {:continue, :compose}}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, %{owner: owner}} ->
        {:stop, {:composition_input_down, owner, stable_reason(reason)}, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp compose(opts) do
    projection_provider = Keyword.get(opts, :projection_provider, ProjectionProvider)
    app_bootstrap = Keyword.get(opts, :app_bootstrap, AppBootstrap)
    plugin_bootstrap = Keyword.get(opts, :plugin_bootstrap, PluginBootstrap)

    app_metadata_supervisor =
      Keyword.get(opts, :app_metadata_supervisor, AppMetadataSupervisor)

    plugin_metadata_supervisor =
      Keyword.get(opts, :plugin_metadata_supervisor, PluginMetadataSupervisor)

    app_registry = Keyword.get(opts, :app_registry, AppRegistry)
    plugin_registry = Keyword.get(opts, :plugin_registry, PluginRegistry)
    candidate_builder = Keyword.get(opts, :candidate_builder, CandidateBuilder)
    pack_registry = Keyword.get(opts, :pack_registry, PackRegistry)
    pack_supervisor = Keyword.get(opts, :pack_supervisor, PackSupervisor)
    readiness = Keyword.get(opts, :readiness, Readiness)

    with {:ok, bootstrap_completions} <- await_bootstrap(app_bootstrap, plugin_bootstrap),
         {:ok, %{barrier_pid: barrier_pid}} <- readiness.status(),
         {:ok, monitored} <-
           monitored_roster(
             pack_supervisor,
             barrier_pid,
             app_metadata_supervisor,
             app_registry,
             app_bootstrap,
             plugin_metadata_supervisor,
             plugin_registry,
             plugin_bootstrap,
             bootstrap_completions
           ),
         {:ok, closed} <- projection_provider.closed(),
         {:ok, app_snapshot, app_ref} <-
           app_registry.snapshot_and_subscribe(self(),
             server: monitored_pid(monitored, app_registry)
           ),
         {:ok, plugin_snapshot, plugin_ref} <-
           plugin_registry.snapshot_and_subscribe(self(),
             server: monitored_pid(monitored, plugin_registry)
           ),
         {:ok, built_candidate} <- candidate_builder.build(closed, app_snapshot, plugin_snapshot),
         :ok <-
           app_registry.bind_epoch(app_ref, app_snapshot.generation, barrier_pid,
             server: monitored_pid(monitored, app_registry)
           ),
         :ok <-
           plugin_registry.bind_epoch(plugin_ref, plugin_snapshot.generation, barrier_pid,
             server: monitored_pid(monitored, plugin_registry)
           ),
         effectful_ids <- effectful_ids(closed),
         {:ok, snapshot} <-
           pack_registry.finalize(built_candidate, effectful_ids: effectful_ids),
         metadata_sources <- [
           {monitored_pid(monitored, app_registry), app_snapshot.generation, app_ref},
           {monitored_pid(monitored, plugin_registry), plugin_snapshot.generation, plugin_ref}
         ],
         :ok <- validate_source_roster(metadata_sources),
         {:ok, epoch} <-
           readiness.open(snapshot.behavior_digest, effectful_ids,
             server: barrier_pid,
             metadata_sources: metadata_sources
           ) do
      {:ok,
       %{
         closed: closed,
         snapshot: snapshot,
         epoch: epoch,
         source_generations: %{app: app_snapshot.generation, plugin: plugin_snapshot.generation},
         bootstrap_generations: %{
           app: bootstrap_completions.app.generation,
           plugin: bootstrap_completions.plugin.generation
         },
         bootstrap_completions: bootstrap_completions,
         monitored: monitored
       }}
    end
  end

  defp await_bootstrap(app_bootstrap, plugin_bootstrap) do
    with :ok <- app_bootstrap.await_ready(app_bootstrap, @bootstrap_timeout),
         {:ok, app_completion} <-
           app_bootstrap.completion_token(app_bootstrap, @bootstrap_timeout),
         {:ok, plugin_completion} <-
           plugin_bootstrap.completion_token(plugin_bootstrap, @bootstrap_timeout),
         :ok <- valid_bootstrap_completion(app_completion),
         :ok <- valid_bootstrap_completion(plugin_completion) do
      {:ok, %{app: app_completion, plugin: plugin_completion}}
    else
      _ -> {:error, :metadata_bootstrap_unavailable}
    end
  catch
    :exit, _reason -> {:error, :metadata_bootstrap_unavailable}
  end

  defp valid_bootstrap_completion(%{
         pid: pid,
         generation: generation,
         completion_token: completion_token
       })
       when is_pid(pid) and is_integer(generation) and generation > 0 and
              is_reference(completion_token),
       do: :ok

  defp valid_bootstrap_completion(_completion), do: {:error, :metadata_bootstrap_unavailable}

  defp effectful_ids(closed) do
    closed.rows
    |> Enum.filter(&(&1.startup_role == :native_effectful))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp validate_source_roster([
         {app_pid, app_generation, app_ref},
         {plugin_pid, plugin_generation, plugin_ref}
       ])
       when is_pid(app_pid) and is_integer(app_generation) and is_reference(app_ref) and
              is_pid(plugin_pid) and is_integer(plugin_generation) and is_reference(plugin_ref) and
              app_pid != plugin_pid,
       do: :ok

  defp validate_source_roster(_sources), do: {:error, :metadata_source_roster_mismatch}

  defp monitored_roster(
         pack_supervisor,
         barrier_pid,
         app_metadata_supervisor,
         app_registry,
         app_bootstrap,
         plugin_metadata_supervisor,
         plugin_registry,
         plugin_bootstrap,
         %{app: app_completion, plugin: plugin_completion}
       ) do
    with {:ok, pack_supervisor_pid} <- resolve_pid(pack_supervisor),
         {:ok, ^barrier_pid} <- resolve_exact_pid(barrier_pid, barrier_pid),
         {:ok, app_metadata_supervisor_pid} <- resolve_pid(app_metadata_supervisor),
         {:ok, app_registry_pid} <- resolve_pid(app_registry),
         {:ok, app_bootstrap_pid} <- resolve_pid(app_bootstrap),
         {:ok, ^app_bootstrap_pid} <- resolve_exact_pid(app_bootstrap_pid, app_completion.pid),
         {:ok, plugin_metadata_supervisor_pid} <- resolve_pid(plugin_metadata_supervisor),
         {:ok, plugin_registry_pid} <- resolve_pid(plugin_registry),
         {:ok, plugin_bootstrap_pid} <- resolve_pid(plugin_bootstrap),
         {:ok, ^plugin_bootstrap_pid} <-
           resolve_exact_pid(plugin_bootstrap_pid, plugin_completion.pid) do
      {:ok,
       [
         {pack_supervisor, pack_supervisor_pid},
         {barrier_pid, barrier_pid},
         {app_metadata_supervisor, app_metadata_supervisor_pid},
         {app_registry, app_registry_pid},
         {app_bootstrap, app_bootstrap_pid},
         {plugin_metadata_supervisor, plugin_metadata_supervisor_pid},
         {plugin_registry, plugin_registry_pid},
         {plugin_bootstrap, plugin_bootstrap_pid}
       ]}
    end
  end

  defp resolve_pid(owner) when is_pid(owner), do: resolve_exact_pid(owner, owner)

  defp resolve_pid(owner) do
    case Process.whereis(owner) do
      pid when is_pid(pid) -> {:ok, pid}
      _other -> {:error, :composition_input_unavailable}
    end
  end

  defp resolve_exact_pid(pid, expected_pid) when is_pid(pid) and pid == expected_pid,
    do: {:ok, pid}

  defp resolve_exact_pid(_pid, _expected_pid), do: {:error, :composition_input_mismatch}

  defp monitored_pid(monitored, owner) do
    case List.keyfind(monitored, owner, 0) do
      {^owner, pid} -> pid
      nil -> nil
    end
  end

  defp monitor_inputs(monitored) do
    Map.new(monitored, fn {owner, pid} ->
      {Process.monitor(pid), %{owner: owner, pid: pid}}
    end)
  end

  defp source_name(pid, state) do
    Enum.find_value(state.monitors, :unknown, fn {_ref, %{owner: owner, pid: owner_pid}} ->
      if owner_pid == pid, do: owner
    end)
  end

  defp handle_compose_failure(reason, state) do
    if retryable_input_failure?(reason) do
      Process.send_after(self(), :retry_compose, @input_retry_ms)
      {:noreply, state}
    else
      {:stop, {:composition_failed, redact_reason(reason)}, state}
    end
  end

  defp retryable_input_failure?(reason)
       when reason in [
              :metadata_bootstrap_unavailable,
              :composition_input_unavailable,
              :unavailable
            ],
       do: true

  defp retryable_input_failure?(_reason), do: false

  defp redact_reason(reason) when is_atom(reason), do: reason
  defp redact_reason({tag, value}) when is_atom(tag) and is_atom(value), do: {tag, value}

  defp redact_reason(%{schema_version: 1, code: code}) when is_atom(code),
    do: {:readiness_rejected, code}

  defp redact_reason(_reason), do: :composition_rejected

  defp stable_reason(reason) when reason in [:normal, :shutdown, :killed], do: reason
  defp stable_reason({:shutdown, _reason}), do: :shutdown
  defp stable_reason(_reason), do: :unexpected
end
