defmodule AllbertAssist.Coding.TurnSupervisor do
  @moduledoc """
  M5 async boundary for Pi-mode coding turns.

  This module does not grant authority or run tools directly. It wraps an
  already-authoritative runtime turn segment in `AllbertAssist.TaskSupervisor`,
  registers the in-flight task by turn id, and converts task shutdown/timeout
  into a partial runtime response so the normal response signal, trace, and
  conversation persistence paths still run.
  """

  alias AllbertAssist.Coding.Config
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
  Shut down an in-flight turn task.

  M6 wires this to Esc and provider stream cancellation. M5 exposes only the
  addressable task boundary and partial-response behavior.
  """
  @spec shutdown(turn_id(), term(), keyword()) :: :ok | {:error, term()}
  def shutdown(turn_id, reason \\ :shutdown, opts \\ []) when is_binary(turn_id) do
    with {:ok, %{pid: pid}} <- lookup(turn_id, opts) do
      Process.exit(pid, {:shutdown, reason})
      :ok
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
