defmodule AllbertAssist.Session.Scratchpad do
  @moduledoc """
  Supervised volatile ETS scratchpad for local session context.
  """

  use GenServer

  require Logger

  alias AllbertAssist.Settings

  @default_table :allbert_session_scratchpad
  @default_sweep_interval_ms 60_000
  @default_ttl_minutes 30

  @type key :: {String.t(), String.t()}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, reason -> {:error, {:scratchpad_unavailable, reason}}
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)
    table_name = Keyword.get(opts, :table_name, @default_table)
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    ttl_ms = ttl_ms(opts)

    table =
      if enabled? do
        :ets.new(table_name, [
          :named_table,
          :set,
          :protected,
          read_concurrency: true,
          write_concurrency: false
        ])
      end

    state = %{
      enabled?: enabled?,
      table: table,
      ttl_ms: ttl_ms,
      sweep_interval_ms: sweep_interval_ms
    }

    maybe_schedule_sweep(state)

    Logger.info(
      "allbert session scratchpad started enabled=#{enabled?} table=#{inspect(table_name)} ttl_ms=#{ttl_ms}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(message, _from, %{enabled?: false} = state) do
    {:reply, disabled_reply(message), state}
  end

  def handle_call({:get, key, touch?}, _from, state) do
    now = monotonic_ms()

    case fetch_entry(state, key, now) do
      {:ok, entry} when touch? ->
        entry = touch_entry(entry, now, state.ttl_ms)
        store_entry(state, key, entry)
        {:reply, {:ok, entry}, state}

      {:ok, entry} ->
        {:reply, {:ok, entry}, state}

      {:error, :expired} ->
        delete_entry(state, key)
        {:reply, {:error, :not_found}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:put, key, attrs}, _from, state) do
    now = monotonic_ms()
    entry = key |> current_or_new_entry(state, now) |> apply_attrs(attrs, now, state.ttl_ms)
    store_entry(state, key, entry)
    {:reply, {:ok, entry}, state}
  end

  def handle_call({:set_active_app, key, active_app}, _from, state) do
    now = monotonic_ms()

    entry =
      key
      |> current_or_new_entry(state, now)
      |> Map.put(:active_app, active_app)
      |> touch_entry(now, state.ttl_ms)

    store_entry(state, key, entry)
    {:reply, {:ok, entry}, state}
  end

  def handle_call({:clear_active_app, key}, _from, state) do
    now = monotonic_ms()

    case fetch_entry(state, key, now) do
      {:ok, entry} ->
        entry =
          entry
          |> Map.put(:active_app, nil)
          |> touch_entry(now, state.ttl_ms)

        store_entry(state, key, entry)
        {:reply, {:ok, entry}, state}

      {:error, :expired} ->
        delete_entry(state, key)
        {:reply, {:error, :not_found}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:merge_working_memory, key, working_memory}, _from, state) do
    now = monotonic_ms()
    entry = current_or_new_entry(key, state, now)
    merged = Map.merge(entry.working_memory, working_memory)

    if :erlang.external_size(merged) > 65_536 do
      {:reply, {:error, :working_memory_too_large}, state}
    else
      entry =
        entry
        |> Map.put(:working_memory, merged)
        |> touch_entry(now, state.ttl_ms)

      store_entry(state, key, entry)
      {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:clear, key}, _from, state) do
    removed? = :ets.member(state.table, key)
    delete_entry(state, key)
    {:reply, {:ok, %{removed?: removed?}}, state}
  end

  def handle_call({:list, user_id}, _from, state) do
    now = monotonic_ms()
    {_removed, entries} = sweep_and_collect(state, now, user_id)
    {:reply, {:ok, entries}, state}
  end

  def handle_call({:touch, key}, _from, state) do
    now = monotonic_ms()

    case fetch_entry(state, key, now) do
      {:ok, entry} ->
        entry = touch_entry(entry, now, state.ttl_ms)
        store_entry(state, key, entry)
        {:reply, {:ok, entry}, state}

      {:error, :expired} ->
        delete_entry(state, key)
        {:reply, {:error, :not_found}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:sweep_expired, _from, state) do
    {removed, _entries} = sweep_and_collect(state, monotonic_ms(), :all)
    {:reply, {:ok, removed}, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_removed, _entries} = sweep_and_collect(state, monotonic_ms(), :all)
    maybe_schedule_sweep(state)
    {:noreply, state}
  end

  defp disabled_reply({:get, _key, _touch?}), do: {:error, :not_found}
  defp disabled_reply({:list, _user_id}), do: {:ok, []}
  defp disabled_reply(:sweep_expired), do: {:ok, 0}
  defp disabled_reply(_message), do: {:error, :disabled}

  defp ttl_ms(opts) do
    cond do
      is_integer(Keyword.get(opts, :ttl_ms)) ->
        Keyword.fetch!(opts, :ttl_ms)

      is_integer(Keyword.get(opts, :ttl_minutes)) ->
        Keyword.fetch!(opts, :ttl_minutes) * 60_000

      true ->
        settings_ttl_minutes() * 60_000
    end
  end

  defp settings_ttl_minutes do
    case Settings.get("sessions.scratchpad_ttl_minutes") do
      {:ok, value} when is_integer(value) -> value
      _other -> @default_ttl_minutes
    end
  rescue
    _exception -> @default_ttl_minutes
  end

  defp maybe_schedule_sweep(%{enabled?: true, sweep_interval_ms: interval})
       when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
  end

  defp maybe_schedule_sweep(_state), do: :ok

  defp current_or_new_entry(key, state, now) do
    case fetch_entry(state, key, now) do
      {:ok, entry} -> entry
      {:error, _reason} -> new_entry(key, now, state.ttl_ms)
    end
  end

  defp new_entry({user_id, session_id}, now, ttl_ms) do
    %{
      user_id: user_id,
      session_id: session_id,
      active_app: nil,
      working_memory: %{},
      metadata: %{},
      inserted_at_ms: now,
      updated_at_ms: now,
      expires_at_ms: now + ttl_ms
    }
  end

  defp fetch_entry(state, key, now) do
    case :ets.lookup(state.table, key) do
      [{^key, entry}] ->
        if expired?(entry, now), do: {:error, :expired}, else: {:ok, entry}

      [] ->
        {:error, :not_found}
    end
  end

  defp apply_attrs(entry, attrs, now, ttl_ms) do
    entry
    |> maybe_replace(:active_app, attrs)
    |> maybe_replace(:working_memory, attrs)
    |> maybe_replace(:metadata, attrs)
    |> touch_entry(now, ttl_ms)
  end

  defp maybe_replace(entry, key, attrs) do
    if Map.has_key?(attrs, key), do: Map.put(entry, key, Map.fetch!(attrs, key)), else: entry
  end

  defp touch_entry(entry, now, ttl_ms) do
    %{entry | updated_at_ms: now, expires_at_ms: now + ttl_ms}
  end

  defp store_entry(state, key, entry) do
    :ets.insert(state.table, {key, entry})
  end

  defp delete_entry(state, key), do: :ets.delete(state.table, key)

  defp sweep_and_collect(state, now, user_filter) do
    state.table
    |> :ets.tab2list()
    |> Enum.reduce({0, []}, fn {key, entry}, {removed, entries} ->
      cond do
        expired?(entry, now) ->
          delete_entry(state, key)
          {removed + 1, entries}

        user_filter == :all ->
          {removed, [entry | entries]}

        entry.user_id == user_filter ->
          {removed, [entry | entries]}

        true ->
          {removed, entries}
      end
    end)
    |> then(fn {removed, entries} ->
      {removed, Enum.sort_by(entries, & &1.session_id)}
    end)
  end

  defp expired?(entry, now), do: entry.expires_at_ms <= now
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
