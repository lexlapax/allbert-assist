defmodule AllbertAssist.Coding.TurnSupervisor do
  @moduledoc """
  M5/M6 async boundary for Pi-mode coding turns.

  This module does not grant authority or run tools directly. It wraps an
  already-authoritative runtime turn segment in `AllbertAssist.TaskSupervisor`,
  registers the in-flight task by turn id, and converts task shutdown/timeout
  into a partial runtime response so the normal response signal, trace,
  conversation persistence, and stream-event paths still run.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.StreamEvent
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response

  @registry AllbertAssist.Coding.TurnRegistry
  @task_supervisor AllbertAssist.TaskSupervisor
  @register_timeout_ms 1_000

  @type turn_id :: String.t()
  @type metadata :: %{required(:turn_id) => turn_id(), optional(atom()) => term()}
  @type agent_result :: {:ok, map()} | {:error, term()}

  @doc "Run a coding turn segment under the supervised M5 boundary when enabled."
  @spec run(metadata(), (-> agent_result()), keyword()) :: agent_result()
  def run(metadata, fun, opts \\ []) when is_function(fun, 0) do
    metadata = normalize_metadata(metadata)

    if Keyword.get(opts, :supervised?, Config.turn_supervised?()) do
      run_supervised(metadata, fun, opts)
    else
      fun.()
    end
  end

  @doc "Return the in-flight task for a coding turn id."
  @spec lookup(turn_id(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def lookup(turn_id, opts \\ []) when is_binary(turn_id) do
    registry = Keyword.get(opts, :registry, @registry)

    registry
    |> Registry.lookup(turn_id)
    |> case do
      [{pid, metadata}] when is_pid(pid) ->
        {:ok, Map.merge(metadata, %{pid: pid})}

      [] ->
        {:error, :not_found}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Register the provider/model stream cancel callback for the current turn task.

  Elixir registries can only update a value from the process that owns the
  registration. Call this from inside the running coding turn task after the
  provider stream has been opened.
  """
  @spec register_stream_cancel(turn_id(), (-> term()), keyword()) ::
          :ok | {:error, :not_owner | term()}
  def register_stream_cancel(turn_id, cancel_fun, opts \\ [])
      when is_binary(turn_id) and is_function(cancel_fun, 0) do
    registry = Keyword.get(opts, :registry, @registry)

    metadata = %{
      fun: cancel_fun,
      registered_at: now(),
      source: Keyword.get(opts, :source, :provider_stream)
    }

    case Registry.update_value(registry, turn_id, fn value ->
           Map.put(value, :stream_cancel, metadata)
         end) do
      {_new_value, _old_value} -> :ok
      :error -> {:error, :not_owner}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Cancel an in-flight coding turn.

  Cancellation invokes a registered provider stream cancel callback first, then
  shuts down the supervised turn task through its registry entry. If the task is
  still alive after the configured grace window, it is killed so the turn cannot
  remain orphaned.
  """
  @spec cancel(turn_id(), term(), keyword()) ::
          {:ok,
           %{
             turn_id: turn_id(),
             stream_cancel: :ok | :not_registered | {:error, term()},
             shutdown: :ok | {:ok, :killed}
           }}
          | {:error, term()}
  def cancel(turn_id, reason \\ :operator_escape, opts \\ []) when is_binary(turn_id) do
    with {:ok, turn} <- lookup(turn_id, opts) do
      stream_cancel = cancel_stream(turn)
      shutdown = shutdown_task(turn, reason, opts)

      {:ok,
       %{
         turn_id: turn_id,
         stream_cancel: stream_cancel,
         shutdown: shutdown
       }}
    end
  end

  @doc """
  Shut down an in-flight turn task.

  This is the registry-level task shutdown primitive. M6 `cancel/3` should be
  preferred when provider stream cancellation is available.
  """
  @spec shutdown(turn_id(), term(), keyword()) :: :ok | {:error, term()}
  def shutdown(turn_id, reason \\ :shutdown, opts \\ []) when is_binary(turn_id) do
    with {:ok, turn} <- lookup(turn_id, opts) do
      case shutdown_task(turn, reason, opts) do
        :ok -> :ok
        {:ok, _status} -> :ok
      end
    end
  end

  defp run_supervised(metadata, fun, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)
    registry = Keyword.get(opts, :registry, @registry)
    max_ms = Keyword.get(opts, :timeout_ms, Config.turn_max_ms())

    if supervisor_available?(supervisor) do
      start_and_await(supervisor, registry, metadata, fun, max_ms)
    else
      fun.()
    end
  end

  defp start_and_await(supervisor, registry, metadata, fun, max_ms) do
    parent = self()
    token = make_ref()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        case register(registry, metadata, parent, token) do
          :ok -> fun.()
          {:error, reason} -> {:error, reason}
        end
      end)

    await_registration(token, metadata.turn_id)
    await_task(task, metadata, max_ms)
  end

  defp register(registry, metadata, parent, token) do
    metadata =
      metadata
      |> Map.put(:status, :running)
      |> Map.put(:started_at, now())

    case Registry.register(registry, metadata.turn_id, metadata) do
      {:ok, _owner} ->
        send(parent, {:coding_turn_registered, token, metadata.turn_id, self()})
        :ok

      {:error, reason} ->
        send(parent, {:coding_turn_register_failed, token, metadata.turn_id, reason})
        {:error, {:turn_register_failed, reason}}
    end
  end

  defp await_registration(token, turn_id) do
    receive do
      {:coding_turn_registered, ^token, ^turn_id, _pid} ->
        :ok

      {:coding_turn_register_failed, ^token, ^turn_id, _reason} ->
        :ok
    after
      @register_timeout_ms ->
        :ok
    end
  end

  defp await_task(task, metadata, max_ms) do
    case Task.yield(task, max_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:ok, partial_response(exit_status(reason), reason, metadata)}

      nil ->
        {:ok, partial_response(:timed_out, {:timeout, max_ms}, metadata)}
    end
  end

  defp partial_response(status, reason, metadata) do
    reason_text = reason |> Redactor.redact() |> inspect()
    turn_id = metadata.turn_id
    message = partial_message(status, turn_id)

    %{
      message: message,
      model_payload: message,
      surface_payload: message,
      status: status,
      actions: [
        Response.action("coding_turn", status,
          turn_id: turn_id,
          trace_metadata: %{
            turn_id: turn_id,
            status: status,
            partial?: true,
            reason: reason_text
          }
        )
      ],
      stream_events: stream_events(status, metadata, reason_text),
      turn_id: turn_id,
      diagnostics: [
        %{
          source: :coding_turn,
          turn_id: turn_id,
          status: status,
          partial?: true,
          error: reason_text
        }
      ],
      coding_turn: trace_metadata(metadata, status)
    }
  end

  defp partial_message(:timed_out, turn_id),
    do: "Coding turn #{turn_id} timed out before completion; partial turn was preserved."

  defp partial_message(:cancelled, turn_id),
    do: "Coding turn #{turn_id} stopped before completion; partial turn was preserved."

  defp partial_message(_status, turn_id),
    do: "Coding turn #{turn_id} failed before completion; partial turn was preserved."

  defp exit_status(:shutdown), do: :cancelled
  defp exit_status({:shutdown, _reason}), do: :cancelled
  defp exit_status(:killed), do: :cancelled
  defp exit_status(_reason), do: :failed

  defp stream_events(:cancelled, metadata, reason_text) do
    case StreamEvent.new(:turn_cancelled, %{
           turn_id: metadata.turn_id,
           reason: reason_text,
           metadata: %{partial?: true}
         }) do
      {:ok, event} -> [event]
      {:error, _reason} -> []
    end
  end

  defp stream_events(_status, _metadata, _reason_text), do: []

  defp cancel_stream(%{stream_cancel: %{fun: cancel_fun}}) when is_function(cancel_fun, 0) do
    cancel_fun.()
    :ok
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, Redactor.redact(reason)}}
  end

  defp cancel_stream(_turn), do: :not_registered

  defp shutdown_task(%{pid: pid}, reason, opts) when is_pid(pid) do
    grace_ms = Keyword.get(opts, :grace_ms, Config.cancel_grace_ms())
    Process.exit(pid, {:shutdown, reason})

    case await_task_exit(pid, grace_ms) do
      :down ->
        :ok

      :alive ->
        Process.exit(pid, :kill)
        {:ok, :killed}
    end
  end

  defp await_task_exit(pid, grace_ms) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :down
    after
      grace_ms ->
        Process.demonitor(ref, [:flush])
        :alive
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    turn_id =
      metadata
      |> field(:turn_id)
      |> case do
        nil -> "coding-turn-#{System.unique_integer([:positive])}"
        value -> to_string(value)
      end

    metadata
    |> atomize_known_keys()
    |> Map.put(:turn_id, turn_id)
  end

  defp trace_metadata(metadata, status) do
    metadata
    |> Map.take([
      :turn_id,
      :input_signal_id,
      :user_id,
      :operator_id,
      :thread_id,
      :session_id,
      :channel
    ])
    |> Map.put(:status, status)
    |> Map.put(:partial?, true)
  end

  defp atomize_known_keys(metadata) do
    Enum.reduce(
      [:input_signal_id, :user_id, :operator_id, :thread_id, :session_id, :channel],
      %{},
      fn key, acc ->
        case field(metadata, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end
    )
  end

  defp field(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp supervisor_available?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp supervisor_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp supervisor_available?(_other), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
