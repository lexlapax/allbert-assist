defmodule AllbertAssist.Pack.Readiness do
  @moduledoc """
  Generic kernel-owned readiness barrier for finalized Pack snapshots.

  It is deliberately unaware of shipped Pack identities and effect callsites.
  Composition supplies the finalized snapshot and exact required gate ids; each
  gate proves its own liveness by acknowledging one activation epoch.

  This is a plain GenServer: it owns a short, bounded synchronization lifecycle,
  not agent reasoning, Skill composition, or a successor-agent lifecycle.
  """

  use GenServer

  alias AllbertAssist.Pack.ActivationContext
  alias AllbertAssist.Pack.Identity
  alias AllbertAssist.Pack.Registry

  @default_coordinator :allbert_pack_composition_owner
  @default_timeout 5_000
  @open_timeout 30_000
  @open_call_timeout 31_000
  @start_keys [:name, :registry, :coordinator]

  defstruct phase: :collecting,
            registry: Registry,
            coordinator: @default_coordinator,
            coordinator_monitor: nil,
            subscribers: %{},
            expected_ids: [],
            acked_ids: MapSet.new(),
            snapshot_digest: nil,
            metadata_bindings: %{},
            open_from: nil,
            deadline_ref: nil,
            diagnostics: []

  @type phase :: :collecting | :authorizing | :ready

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with :ok <- validate_start_options(opts) do
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    end
  end

  @spec subscribe(String.t(), keyword()) ::
          {:ok, %{barrier_pid: pid(), subscription_ref: reference(), phase: phase()}}
          | {:error, :unavailable | map()}
  def subscribe(pack_id, opts \\ []) do
    with {:ok, server, timeout, subscriber} <- call_options(opts, :subscribe) do
      safe_call(server, {:subscribe, pack_id, subscriber}, timeout, {:error, :unavailable})
    else
      :error -> {:error, :unavailable}
    end
  end

  @spec open(String.t(), [String.t()], keyword()) ::
          {:ok, %{barrier_pid: pid(), snapshot_digest: String.t(), phase: :ready}}
          | {:error, map()}
  def open(snapshot_digest, expected_pack_ids, opts \\ []) do
    with {:ok, server, _timeout, _subscriber} <- call_options(opts, :open) do
      safe_call(
        server,
        {:open, snapshot_digest, expected_pack_ids, Keyword.get(opts, :metadata_sources, [])},
        @open_call_timeout,
        {:error, diagnostic(:barrier_down, :collecting, nil, [], [], nil)}
      )
    else
      :error -> {:error, diagnostic(:barrier_down, :collecting, nil, [], [], nil)}
    end
  end

  @spec ack(reference(), String.t(), keyword()) :: :ok | {:error, map() | :unavailable}
  def ack(subscription_ref, snapshot_digest, opts \\ []) do
    with {:ok, server, timeout, subscriber} <- call_options(opts, :ack) do
      safe_call(
        server,
        {:ack, subscription_ref, snapshot_digest, subscriber},
        timeout,
        {:error, :unavailable}
      )
    else
      :error -> {:error, :unavailable}
    end
  end

  @spec nack(reference(), String.t(), term(), keyword()) :: :ok | {:error, map() | :unavailable}
  def nack(subscription_ref, snapshot_digest, reason, opts \\ []) do
    with {:ok, server, timeout, subscriber} <- call_options(opts, :nack) do
      safe_call(
        server,
        {:nack, subscription_ref, snapshot_digest, reason, subscriber},
        timeout,
        {:error, :unavailable}
      )
    else
      :error -> {:error, :unavailable}
    end
  end

  @spec validate_activation(ActivationContext.t(), keyword()) ::
          :ok | {:error, :product_not_ready | :stale_activation}
  def validate_activation(context, opts \\ []) do
    server = activation_server(context, opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    if valid_timeout?(timeout) and valid_server?(server) do
      safe_call(server, {:validate_activation, context}, timeout, {:error, :product_not_ready})
    else
      {:error, :product_not_ready}
    end
  end

  @spec status(keyword()) ::
          {:ok,
           %{
             phase: phase(),
             barrier_pid: pid(),
             snapshot_digest: String.t() | nil,
             expected_ids: [String.t()],
             subscribed_ids: [String.t()],
             acked_ids: [String.t()],
             diagnostics: [map()]
           }}
          | {:error, :unavailable}
  def status(opts \\ []) do
    with {:ok, server, timeout, _subscriber} <- call_options(opts, :status) do
      safe_call(server, :status, timeout, {:error, :unavailable})
    else
      :error -> {:error, :unavailable}
    end
  end

  @doc false
  @spec bind_metadata(pid(), pid(), non_neg_integer(), reference()) ::
          :ok | {:error, :stale_epoch | :invalid_phase | :unavailable}
  def bind_metadata(barrier_pid, registry_pid, generation, subscription_ref) do
    safe_call(
      barrier_pid,
      {:bind_metadata, barrier_pid, registry_pid, generation, subscription_ref},
      @default_timeout,
      {:error, :unavailable}
    )
  end

  @doc false
  @spec invalidate_metadata(pid(), pid(), non_neg_integer()) ::
          :ok | {:error, :stale_epoch | :invalid_phase | :unavailable}
  def invalidate_metadata(barrier_pid, registry_pid, generation) do
    safe_call(
      barrier_pid,
      {:invalidate_metadata, barrier_pid, registry_pid, generation},
      @default_timeout,
      {:error, :unavailable}
    )
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       registry: Keyword.get(opts, :registry, Registry),
       coordinator: Keyword.get(opts, :coordinator, @default_coordinator)
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, {:ok, public_status(state)}, state}

  def handle_call({:subscribe, pack_id, subscriber}, _from, state) do
    case subscribe_state(pack_id, subscriber, state) do
      {:ok, reply, next_state} -> {:reply, {:ok, reply}, next_state}
      {:error, diagnostic, next_state} -> {:reply, {:error, diagnostic}, next_state}
    end
  end

  def handle_call({:open, digest, expected_ids, metadata_sources}, from, state) do
    case begin_open(from, digest, expected_ids, metadata_sources, state) do
      {:reply, result, next_state} -> {:reply, result, next_state}
      {:wait, next_state} -> {:noreply, next_state}
    end
  end

  def handle_call({:ack, ref, digest, subscriber}, {caller, _tag}, state) do
    owner = if is_pid(subscriber), do: subscriber, else: caller

    case acknowledge(ref, digest, owner, state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, diagnostic} -> {:reply, {:error, diagnostic}, state}
    end
  end

  def handle_call({:nack, ref, digest, _reason, subscriber}, {caller, _tag}, state) do
    owner = if is_pid(subscriber), do: subscriber, else: caller

    if active_subscription?(ref, digest, owner, state) do
      diagnostic =
        diagnostic(
          :activation_nack,
          state.phase,
          subscriber_id(ref, state),
          state.expected_ids,
          subscribed_ids(state),
          digest
        )

      reply_open_failure(state.open_from, diagnostic)
      {:stop, :shutdown, :ok, state}
    else
      {:reply,
       {:error,
        diagnostic(
          :stale_epoch,
          state.phase,
          nil,
          state.expected_ids,
          subscribed_ids(state),
          state.snapshot_digest
        )}, state}
    end
  end

  def handle_call({:validate_activation, context}, _from, state) do
    {:reply, activation_validation(context, state), state}
  end

  def handle_call(
        {:bind_metadata, barrier_pid, registry_pid, generation, subscription_ref},
        {caller, _tag},
        state
      ) do
    case bind_metadata_state(
           barrier_pid,
           registry_pid,
           generation,
           subscription_ref,
           caller,
           state
         ) do
      {:reply, result, next_state} -> {:reply, result, next_state}
    end
  end

  def handle_call(
        {:invalidate_metadata, barrier_pid, registry_pid, generation},
        {caller, _tag},
        state
      ) do
    case invalidate_metadata_state(barrier_pid, registry_pid, generation, caller, state) do
      {:reply, result, next_state} -> {:reply, result, next_state}
      {:stop, result, next_state} -> {:stop, :shutdown, result, next_state}
    end
  end

  @impl true
  def handle_info(:open_timeout, state) when state.phase == :authorizing do
    code =
      if Enum.sort(subscribed_ids(state)) == state.expected_ids,
        do: :activation_timeout,
        else: :subscriber_timeout

    diagnostic =
      diagnostic(
        code,
        state.phase,
        nil,
        state.expected_ids,
        subscribed_ids(state),
        state.snapshot_digest
      )

    reply_open_failure(state.open_from, diagnostic)
    {:stop, :shutdown, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      state.coordinator_monitor == ref ->
        diagnostic =
          diagnostic(
            :coordinator_down,
            state.phase,
            nil,
            state.expected_ids,
            subscribed_ids(state),
            state.snapshot_digest
          )

        reply_open_failure(state.open_from, diagnostic)
        {:stop, :shutdown, state}

      subscriber =
          Enum.find_value(state.subscribers, fn {_id, sub} -> if sub.monitor == ref, do: sub end) ->
        handle_subscriber_down(pid, subscriber, state)

      _metadata_owner =
          Enum.find_value(state.metadata_bindings, fn {_registry_pid, binding} ->
            if binding.monitor == ref, do: binding
          end) ->
        diagnostic =
          diagnostic(
            :metadata_owner_down,
            state.phase,
            nil,
            state.expected_ids,
            subscribed_ids(state),
            state.snapshot_digest
          )

        reply_open_failure(state.open_from, diagnostic)
        {:stop, :shutdown, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp subscribe_state(pack_id, subscriber, state) do
    if is_binary(pack_id) and Identity.canonical_id?(pack_id) and is_pid(subscriber) do
      subscribe_state_for_pack(pack_id, subscriber, state)
    else
      {:error,
       diagnostic(
         :invalid_pack_id,
         state.phase,
         nil,
         state.expected_ids,
         subscribed_ids(state),
         state.snapshot_digest
       ), state}
    end
  end

  defp subscribe_state_for_pack(pack_id, subscriber, state) do
    case Map.fetch(state.subscribers, pack_id) do
      {:ok, existing} -> subscribe_state_existing(existing, pack_id, subscriber, state)
      :error -> subscribe_state_new(pack_id, subscriber, state)
    end
  end

  defp subscribe_state_existing(existing, pack_id, subscriber, state) do
    if existing.pid == subscriber do
      {:ok, subscription_reply(existing.ref, state.phase), state}
    else
      {:error,
       diagnostic(
         :duplicate_subscriber,
         state.phase,
         pack_id,
         state.expected_ids,
         subscribed_ids(state),
         state.snapshot_digest
       ), state}
    end
  end

  defp subscribe_state_new(pack_id, subscriber, state) do
    cond do
      state.phase == :authorizing and pack_id in state.expected_ids ->
        register_expected_subscriber(pack_id, subscriber, state)

      state.phase != :collecting ->
        {:error,
         diagnostic(
           :invalid_phase,
           state.phase,
           pack_id,
           state.expected_ids,
           subscribed_ids(state),
           state.snapshot_digest
         ), state}

      true ->
        register_collecting_subscriber(pack_id, subscriber, state)
    end
  end

  defp register_expected_subscriber(pack_id, subscriber, state) do
    ref = make_ref()
    monitor = Process.monitor(subscriber)
    subscriber_state = %{pid: subscriber, ref: ref, monitor: monitor}
    next_state = put_in(state.subscribers[pack_id], subscriber_state)

    next_state =
      if Enum.sort(subscribed_ids(next_state)) == next_state.expected_ids,
        do: activate_all(next_state),
        else: next_state

    {:ok, subscription_reply(ref, :authorizing), next_state}
  end

  defp register_collecting_subscriber(pack_id, subscriber, state) do
    ref = make_ref()
    monitor = Process.monitor(subscriber)
    subscriber_state = %{pid: subscriber, ref: ref, monitor: monitor}
    next_state = put_in(state.subscribers[pack_id], subscriber_state)
    {:ok, subscription_reply(ref, :collecting), next_state}
  end

  defp begin_open({caller, _tag} = from, digest, expected_ids, metadata_sources, state) do
    cond do
      open_matches_current_snapshot?(state, :authorizing, digest, expected_ids) ->
        {:reply,
         {:error,
          diagnostic(
            :open_in_progress,
            state.phase,
            nil,
            state.expected_ids,
            subscribed_ids(state),
            state.snapshot_digest
          )}, state}

      open_matches_current_snapshot?(state, :ready, digest, expected_ids) ->
        {:reply, {:ok, ready_reply(state)}, state}

      state.phase != :collecting ->
        {:reply,
         {:error,
          diagnostic(
            :already_open,
            state.phase,
            nil,
            state.expected_ids,
            subscribed_ids(state),
            state.snapshot_digest
          )}, state}

      not coordinator?(state.coordinator, caller) ->
        {:reply,
         {:error, diagnostic(:not_coordinator, state.phase, nil, [], subscribed_ids(state), nil)},
         state}

      not valid_open_request?(digest, expected_ids) ->
        {:reply,
         {:error,
          diagnostic(:expected_ids_mismatch, state.phase, nil, [], subscribed_ids(state), nil)},
         state}

      true ->
        validate_open_inputs(from, digest, expected_ids, metadata_sources, state)
    end
  end

  defp open_matches_current_snapshot?(state, phase, digest, expected_ids) do
    state.phase == phase and digest == state.snapshot_digest and
      expected_ids == state.expected_ids
  end

  defp valid_open_request?(digest, expected_ids) do
    valid_digest?(digest) and valid_ids?(expected_ids)
  end

  defp validate_open_inputs(from, digest, expected_ids, metadata_sources, state) do
    case Registry.snapshot(server: state.registry) do
      {:error, :collecting} ->
        {:reply,
         {:error,
          diagnostic(
            :registry_collecting,
            state.phase,
            nil,
            expected_ids,
            subscribed_ids(state),
            digest
          )}, state}

      {:error, :unavailable} ->
        {:reply,
         {:error,
          diagnostic(:barrier_down, state.phase, nil, expected_ids, subscribed_ids(state), digest)},
         state}

      {:ok, snapshot} ->
        validate_open_against_registry(
          from,
          digest,
          expected_ids,
          metadata_sources,
          snapshot,
          state
        )
    end
  end

  defp validate_open_against_registry(
         from,
         digest,
         expected_ids,
         metadata_sources,
         snapshot,
         state
       ) do
    case Registry.effectful_ids(server: state.registry) do
      {:ok, effectful_ids} ->
        check_open_preconditions(
          from,
          digest,
          expected_ids,
          metadata_sources,
          snapshot,
          effectful_ids,
          state
        )

      {:error, _reason} ->
        {:reply,
         {:error,
          diagnostic(:barrier_down, state.phase, nil, expected_ids, subscribed_ids(state), digest)},
         state}
    end
  end

  defp check_open_preconditions(
         from,
         digest,
         expected_ids,
         metadata_sources,
         snapshot,
         effectful_ids,
         state
       ) do
    cond do
      snapshot.behavior_digest != digest ->
        {:reply,
         {:error,
          diagnostic(
            :digest_mismatch,
            state.phase,
            nil,
            expected_ids,
            subscribed_ids(state),
            digest
          )}, state}

      expected_ids != effectful_ids ->
        {:reply,
         {:error,
          diagnostic(
            :expected_ids_mismatch,
            state.phase,
            nil,
            expected_ids,
            subscribed_ids(state),
            digest
          )}, state}

      not metadata_sources_match?(metadata_sources, state.metadata_bindings) ->
        {:reply,
         {:error,
          diagnostic(
            :metadata_binding_mismatch,
            state.phase,
            nil,
            expected_ids,
            subscribed_ids(state),
            digest
          )}, state}

      subscribed_ids(state) -- expected_ids != [] ->
        {:reply,
         {:error,
          diagnostic(
            :unexpected_subscriber,
            state.phase,
            nil,
            expected_ids,
            subscribed_ids(state),
            digest
          )}, state}

      true ->
        start_authorizing(from, digest, expected_ids, state)
    end
  end

  defp start_authorizing({caller, _tag} = from, digest, expected_ids, state) do
    monitor = Process.monitor(caller)

    initial = %{
      state
      | phase: :authorizing,
        snapshot_digest: digest,
        expected_ids: expected_ids,
        coordinator_monitor: monitor,
        open_from: from
    }

    if initial.expected_ids == [] do
      ready = %{initial | phase: :ready, open_from: nil}
      {:reply, {:ok, ready_reply(ready)}, ready}
    else
      {:wait, start_or_wait_open(initial, caller)}
    end
  end

  defp start_or_wait_open(state, _caller) do
    if Enum.sort(subscribed_ids(state)) == state.expected_ids do
      activate_all(state)
    else
      %{state | deadline_ref: Process.send_after(self(), :open_timeout, @open_timeout)}
    end
  end

  defp acknowledge(ref, digest, owner, %{phase: :authorizing} = state) do
    if active_subscription?(ref, digest, owner, state) do
      id = subscriber_id(ref, state)
      next_state = %{state | acked_ids: MapSet.put(state.acked_ids, id)}

      if MapSet.equal?(next_state.acked_ids, MapSet.new(next_state.expected_ids)) do
        if next_state.deadline_ref, do: Process.cancel_timer(next_state.deadline_ref)
        ready = %{next_state | phase: :ready, deadline_ref: nil}
        reply_open_success(ready.open_from, ready_reply(ready))
        {:ok, %{ready | open_from: nil}}
      else
        {:ok, next_state}
      end
    else
      {:error,
       diagnostic(
         :stale_epoch,
         state.phase,
         nil,
         state.expected_ids,
         subscribed_ids(state),
         state.snapshot_digest
       )}
    end
  end

  defp acknowledge(ref, digest, owner, %{phase: :ready} = state) do
    if subscriber_id(ref, state) &&
         active_ready_subscription?(ref, digest, owner, state) do
      {:ok, state}
    else
      {:error,
       diagnostic(
         :invalid_phase,
         state.phase,
         nil,
         state.expected_ids,
         subscribed_ids(state),
         state.snapshot_digest
       )}
    end
  end

  defp acknowledge(_ref, _digest, _owner, state),
    do:
      {:error,
       diagnostic(
         :invalid_phase,
         state.phase,
         nil,
         state.expected_ids,
         subscribed_ids(state),
         state.snapshot_digest
       )}

  defp activation_validation(%ActivationContext{} = context, %{phase: :authorizing} = state) do
    with true <- context.schema_version == 1,
         true <- is_pid(context.gate_pid) and is_pid(context.barrier_pid),
         true <- context.barrier_pid == self(),
         true <- valid_digest?(context.snapshot_digest),
         true <-
           active_subscription?(
             context.subscription_ref,
             context.snapshot_digest,
             context.gate_pid,
             state
           ),
         true <- context.pack_id == subscriber_id(context.subscription_ref, state) do
      :ok
    else
      false -> {:error, :stale_activation}
    end
  end

  defp activation_validation(%ActivationContext{}, _state), do: {:error, :product_not_ready}
  defp activation_validation(_context, _state), do: {:error, :product_not_ready}

  defp bind_metadata_state(barrier_pid, registry_pid, generation, subscription_ref, caller, state) do
    binding = {registry_pid, generation, subscription_ref}

    cond do
      state.phase != :collecting ->
        {:reply, {:error, :invalid_phase}, state}

      invalid_bind_request?(barrier_pid, registry_pid, generation, subscription_ref, caller) ->
        {:reply, {:error, :stale_epoch}, state}

      matching_metadata_binding?(state, registry_pid, binding) ->
        {:reply, :ok, state}

      Map.has_key?(state.metadata_bindings, registry_pid) ->
        {:reply, {:error, :stale_epoch}, state}

      true ->
        {:reply, :ok, put_metadata_binding(state, registry_pid, binding)}
    end
  end

  defp invalid_bind_request?(barrier_pid, registry_pid, generation, subscription_ref, caller) do
    barrier_pid != self() or caller != registry_pid or not is_pid(registry_pid) or
      not is_integer(generation) or generation < 0 or not is_reference(subscription_ref)
  end

  defp matching_metadata_binding?(state, registry_pid, binding) do
    Map.has_key?(state.metadata_bindings, registry_pid) and
      state.metadata_bindings[registry_pid].tuple == binding
  end

  defp put_metadata_binding(state, registry_pid, binding) do
    binding_state = %{tuple: binding, monitor: Process.monitor(registry_pid)}
    %{state | metadata_bindings: Map.put(state.metadata_bindings, registry_pid, binding_state)}
  end

  defp invalidate_metadata_state(barrier_pid, registry_pid, generation, caller, state) do
    binding_state = state.metadata_bindings[registry_pid]
    binding = binding_state && binding_state.tuple

    cond do
      barrier_pid != self() or caller != registry_pid or not is_pid(registry_pid) ->
        {:reply, {:error, :stale_epoch}, state}

      binding != {registry_pid, generation, elem_or_nil(binding, 2)} ->
        {:reply, {:error, :stale_epoch}, state}

      state.phase == :collecting ->
        Process.demonitor(binding_state.monitor, [:flush])

        {:reply, :ok,
         %{state | metadata_bindings: Map.delete(state.metadata_bindings, registry_pid)}}

      true ->
        if binding_state, do: Process.demonitor(binding_state.monitor, [:flush])

        {:stop, :ok,
         %{state | metadata_bindings: Map.delete(state.metadata_bindings, registry_pid)}}
    end
  end

  defp elem_or_nil(tuple, index) when is_tuple(tuple) and tuple_size(tuple) > index,
    do: elem(tuple, index)

  defp elem_or_nil(_tuple, _index), do: nil

  defp active_subscription?(ref, digest, owner, state) do
    case Enum.find(state.subscribers, fn {_id, sub} -> sub.ref == ref end) do
      {id, %{pid: ^owner}} ->
        state.phase == :authorizing and digest == state.snapshot_digest and
          id in state.expected_ids and not MapSet.member?(state.acked_ids, id)

      _ ->
        false
    end
  end

  defp active_ready_subscription?(ref, digest, owner, state) do
    case Enum.find(state.subscribers, fn {_id, sub} -> sub.ref == ref end) do
      {id, %{pid: ^owner}} ->
        digest == state.snapshot_digest and id in state.expected_ids and
          MapSet.member?(state.acked_ids, id)

      _ ->
        false
    end
  end

  defp subscriber_id(ref, state) do
    Enum.find_value(state.subscribers, fn {id, sub} -> if sub.ref == ref, do: id end)
  end

  defp activate_all(state) do
    Enum.each(state.expected_ids, fn id ->
      sub = state.subscribers[id]
      send(sub.pid, {:allbert_pack_activate, self(), sub.ref, state.snapshot_digest})
    end)

    deadline_ref = state.deadline_ref || Process.send_after(self(), :open_timeout, @open_timeout)
    %{state | deadline_ref: deadline_ref}
  end

  defp handle_subscriber_down(_pid, subscriber, %{phase: :collecting} = state) do
    id = Enum.find_value(state.subscribers, fn {id, sub} -> if sub == subscriber, do: id end)
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, id)}}
  end

  defp handle_subscriber_down(_pid, subscriber, state) do
    id = Enum.find_value(state.subscribers, fn {id, sub} -> if sub == subscriber, do: id end)

    diagnostic =
      diagnostic(
        :subscriber_down,
        state.phase,
        id,
        state.expected_ids,
        subscribed_ids(state),
        state.snapshot_digest
      )

    reply_open_failure(state.open_from, diagnostic)
    {:stop, :shutdown, state}
  end

  defp public_status(state) do
    %{
      phase: state.phase,
      barrier_pid: self(),
      snapshot_digest: state.snapshot_digest,
      expected_ids: state.expected_ids,
      subscribed_ids: subscribed_ids(state),
      acked_ids: state.acked_ids |> MapSet.to_list() |> Enum.sort(),
      diagnostics: state.diagnostics
    }
  end

  defp ready_reply(state),
    do: %{barrier_pid: self(), snapshot_digest: state.snapshot_digest, phase: :ready}

  defp subscription_reply(ref, phase),
    do: %{barrier_pid: self(), subscription_ref: ref, phase: phase}

  defp subscribed_ids(state), do: state.subscribers |> Map.keys() |> Enum.sort()

  defp reply_open_success({caller, tag}, result) when is_pid(caller) and not is_nil(tag),
    do: GenServer.reply({caller, tag}, {:ok, result})

  defp reply_open_success(_from, _result), do: :ok

  defp reply_open_failure({caller, tag}, diagnostic) when is_pid(caller) and not is_nil(tag),
    do: GenServer.reply({caller, tag}, {:error, diagnostic})

  defp reply_open_failure(_from, _diagnostic), do: :ok

  defp metadata_sources_match?(sources, bindings) when is_list(sources) do
    Enum.sort(sources) == bindings |> Map.values() |> Enum.map(& &1.tuple) |> Enum.sort()
  end

  defp metadata_sources_match?(_sources, _bindings), do: false

  defp coordinator?(coordinator, caller) when is_pid(coordinator), do: coordinator == caller
  defp coordinator?(coordinator, caller), do: safe_whereis(coordinator) == caller

  defp safe_whereis(name) do
    try do
      GenServer.whereis(name)
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp call_options(opts, mode) when is_list(opts) do
    allowed = allowed_call_option_keys(mode)

    if valid_call_option_shape?(opts, allowed) do
      build_call_options(opts)
    else
      :error
    end
  end

  defp call_options(_opts, _mode), do: :error

  defp allowed_call_option_keys(mode) do
    subscriber_key = if mode in [:subscribe, :ack, :nack], do: [:subscriber], else: []
    metadata_key = if mode == :open, do: [:metadata_sources], else: []

    [:server, :timeout] ++ subscriber_key ++ metadata_key
  end

  defp valid_call_option_shape?(opts, allowed) do
    Keyword.keyword?(opts) and Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) and
      Enum.all?(Keyword.keys(opts), &(&1 in allowed))
  end

  defp build_call_options(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    subscriber = Keyword.get(opts, :subscriber, self())

    if valid_server?(server) and valid_timeout?(timeout) and is_pid(subscriber),
      do: {:ok, server, timeout, subscriber},
      else: :error
  end

  defp activation_server(%ActivationContext{barrier_pid: server}, opts) when is_pid(server) do
    case Keyword.get(opts, :server, server) do
      ^server -> server
      _different -> :invalid
    end
  end

  defp activation_server(_context, _opts), do: :invalid
  defp valid_server?(server) when is_pid(server), do: true
  defp valid_server?(server) when is_atom(server) and server not in [nil, true, false], do: true
  defp valid_server?(_server), do: false

  defp valid_timeout?(timeout),
    do: is_integer(timeout) and timeout > 0 and timeout <= @open_call_timeout

  defp valid_digest?(digest),
    do: is_binary(digest) and String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp valid_ids?(ids),
    do:
      is_list(ids) and ids == Enum.sort(ids) and ids == Enum.uniq(ids) and
        Enum.all?(ids, &(is_binary(&1) and Identity.canonical_id?(&1)))

  defp validate_start_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in @start_keys)) and
         valid_server?(Keyword.get(opts, :registry, Registry)) and
         valid_server?(Keyword.get(opts, :coordinator, @default_coordinator)) and
         valid_name?(Keyword.get(opts, :name, __MODULE__)) do
      :ok
    else
      {:error, {:invalid_options, :invalid}}
    end
  end

  defp validate_start_options(_opts), do: {:error, {:invalid_options, :not_keyword}}
  defp valid_name?(nil), do: true
  defp valid_name?(name), do: valid_server?(name)

  defp safe_call(server, message, timeout, fallback) do
    try do
      GenServer.call(server, message, timeout)
    rescue
      _ -> fallback
    catch
      :exit, _ -> fallback
    end
  end

  defp diagnostic(code, phase, pack_id, expected_ids, actual_ids, snapshot_digest) do
    %{
      schema_version: 1,
      code: code,
      phase: phase,
      pack_id: pack_id,
      expected_ids: expected_ids,
      actual_ids: actual_ids,
      snapshot_digest: snapshot_digest,
      detail: %{}
    }
  end
end
