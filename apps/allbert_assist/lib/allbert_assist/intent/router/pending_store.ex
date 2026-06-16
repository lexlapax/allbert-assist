defmodule AllbertAssist.Intent.Router.PendingStore do
  @moduledoc """
  Short-lived store of `Intent.PendingClarification` turn state (ADR 0034 / ADR
  0060), keyed by `{user_id, thread_id}` for cross-user/thread isolation. Entries
  expire after `intent.pending_clarification_ttl_ms`; `take/2` returns and removes
  a non-expired entry (and drops an expired one). The next turn resolves a reply
  against the offered options — still registry-validated and proposal-only.
  """
  use GenServer

  alias AllbertAssist.Intent.PendingClarification

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Store a pending clarification (overwrites any prior one for the same key)."
  @spec put(PendingClarification.t(), GenServer.server()) :: :ok
  def put(%PendingClarification{} = pending, server \\ __MODULE__),
    do: GenServer.call(server, {:put, pending})

  @doc "Return and remove the pending clarification for a key, if present and not expired."
  @spec take(term(), term(), GenServer.server()) :: {:ok, PendingClarification.t()} | :none
  def take(user_id, thread_id, server \\ __MODULE__),
    do: GenServer.call(server, {:take, key(user_id, thread_id)})

  @doc "Drop any pending clarification for a key."
  @spec delete(term(), term(), GenServer.server()) :: :ok
  def delete(user_id, thread_id, server \\ __MODULE__),
    do: GenServer.call(server, {:delete, key(user_id, thread_id)})

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:put, %PendingClarification{} = pending}, _from, state) do
    {:reply, :ok, Map.put(state, key(pending.user_id, pending.thread_id), pending)}
  end

  def handle_call({:take, key}, _from, state) do
    now = DateTime.utc_now()

    case Map.fetch(state, key) do
      {:ok, pending} ->
        state = Map.delete(state, key)
        if PendingClarification.expired?(pending, now), do: {:reply, :none, state}, else: {:reply, {:ok, pending}, state}

      :error ->
        {:reply, :none, state}
    end
  end

  def handle_call({:delete, key}, _from, state), do: {:reply, :ok, Map.delete(state, key)}

  defp key(user_id, thread_id), do: {to_string(user_id), to_string(thread_id)}
end
