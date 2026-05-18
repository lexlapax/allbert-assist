defmodule AllbertAssist.Workspace.Fragment.Guard do
  @moduledoc """
  In-memory guard state for workspace FragmentEnvelope emission.

  This is a plain GenServer because the state is small, local, and purely
  protective: boot-cached action emitter IDs plus per-emitter/user rate-limit
  counters. It has no Jido lifecycle, command routing, or successor-agent
  semantics.
  """

  use GenServer

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Objectives.AgentRegistry

  @internal_emitters MapSet.new([
                       "AllbertAssist.Workspace.Canvas",
                       "workspace_canvas"
                     ])

  @type state :: %{
          required(:action_emitters) => MapSet.t(String.t()),
          required(:rate_counts) => %{
            optional({String.t(), String.t()}) => %{
              required(:started_at) => integer(),
              required(:count) => integer()
            }
          }
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @impl true
  def init(_opts) do
    {:ok, %{action_emitters: action_emitter_ids(), rate_counts: %{}}}
  end

  @doc "Return true when the emitter is an allowed action, objective delegate, or workspace system emitter."
  @spec emitter_allowed?(term()) :: boolean()
  def emitter_allowed?(emitter_id) when is_binary(emitter_id) do
    call({:emitter_allowed?, emitter_id}, fn ->
      internal_emitter_id?(emitter_id) or action_emitter_id?(emitter_id) or
        objective_agent_emitter?(emitter_id)
    end)
  end

  def emitter_allowed?(_emitter_id), do: false

  @doc "Check and record one fragment emission against the current rate window."
  @spec check_rate(String.t(), String.t(), pos_integer()) :: :ok | {:error, :rate_limited}
  def check_rate(emitter_id, user_id, limit)
      when is_binary(emitter_id) and is_binary(user_id) and is_integer(limit) and limit > 0 do
    now = System.monotonic_time(:millisecond)
    call({:check_rate, emitter_id, user_id, limit, now}, :ok)
  end

  def check_rate(_emitter_id, _user_id, _limit), do: {:error, :rate_limited}

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    call(:reset_for_test, :ok)
  end

  @doc false
  @spec action_emitter_ids() :: MapSet.t(String.t())
  def action_emitter_ids do
    ActionsRegistry.modules()
    |> Enum.flat_map(fn module ->
      [inspect(module), module.name()]
    end)
    |> MapSet.new()
  end

  @impl true
  def handle_call({:emitter_allowed?, emitter_id}, _from, state) do
    allowed? =
      internal_emitter_id?(emitter_id) or
        MapSet.member?(state.action_emitters, emitter_id) or
        action_emitter_id?(emitter_id) or
        objective_agent_emitter?(emitter_id)

    {:reply, allowed?, state}
  end

  def handle_call({:check_rate, emitter_id, user_id, limit, now}, _from, state) do
    key = {emitter_id, user_id}
    counts = prune_rate_counts(state.rate_counts, now)
    window = Map.get(counts, key)

    cond do
      is_nil(window) or now - window.started_at >= 1_000 ->
        {:reply, :ok, %{state | rate_counts: Map.put(counts, key, %{started_at: now, count: 1})}}

      window.count >= limit ->
        {:reply, {:error, :rate_limited}, %{state | rate_counts: counts}}

      true ->
        updated = %{window | count: window.count + 1}
        {:reply, :ok, %{state | rate_counts: Map.put(counts, key, updated)}}
    end
  end

  def handle_call(:reset_for_test, _from, _state) do
    {:reply, :ok, %{action_emitters: action_emitter_ids(), rate_counts: %{}}}
  end

  defp call(message, fallback) when is_function(fallback, 0) do
    case server() do
      nil -> fallback.()
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _reason -> fallback.()
  end

  defp call(message, fallback) do
    case server() do
      nil -> fallback
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _reason -> fallback
  end

  defp server, do: Process.whereis(__MODULE__)

  defp action_emitter_id?(emitter_id) do
    match?({:ok, _module}, ActionsRegistry.resolve(emitter_id))
  end

  defp internal_emitter_id?(emitter_id), do: MapSet.member?(@internal_emitters, emitter_id)

  defp objective_agent_emitter?(emitter_id) do
    case AgentRegistry.lookup(emitter_id) do
      {:ok, _entry} ->
        true

      {:error, _reason} ->
        Enum.any?(safe_objective_entries(), fn entry ->
          emitter_id == inspect(entry.module)
        end)
    end
  catch
    :exit, _reason -> false
  end

  defp safe_objective_entries do
    AgentRegistry.list()
  catch
    :exit, _reason -> []
  end

  defp prune_rate_counts(counts, now) do
    Map.filter(counts, fn {_key, window} -> now - window.started_at < 1_000 end)
  end
end
