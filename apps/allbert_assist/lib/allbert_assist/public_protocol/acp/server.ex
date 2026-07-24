defmodule AllbertAssist.PublicProtocol.Acp.Server do
  @moduledoc """
  Minimal ACP v1 stdio JSON-RPC server for v0.51.

  The server owns only process-local protocol session state. Durable work and
  authority continue to flow through Allbert runtime, Security Central, and
  public protocol readback.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.PublicProtocol.Acp.Mapping
  alias AllbertAssist.Runtime
  alias AllbertAssist.Surface.EventRecorder

  defstruct initialized?: false,
            client_id: Mapping.default_client_id(),
            sessions: %{}

  @type state :: %__MODULE__{
          initialized?: boolean(),
          client_id: String.t(),
          sessions: map()
        }

  @spec new_state() :: state()
  def new_state, do: %__MODULE__{}

  @spec handle_line(String.t(), state()) :: {:ok, [String.t()], state()}
  def handle_line(line, %__MODULE__{} = state) when is_binary(line) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, message} ->
        with {:ok, outbound, state} <- handle_message(message, state) do
          {:ok, Enum.map(outbound, &encode_line/1), state}
        end

      {:error, _reason} ->
        {:ok,
         [encode_line(error_response(nil, Mapping.parse_error("Invalid JSON-RPC message.")))],
         state}
    end
  end

  @spec handle_message(map(), state()) :: {:ok, [map()], state()}
  def handle_message(%{"method" => method} = message, %__MODULE__{} = state)
      when is_binary(method) do
    request_id = Map.get(message, "id")
    params = Map.get(message, "params", %{})

    case dispatch(method, params, request_id, state) do
      {:ok, outbound, state} when is_nil(request_id) ->
        {:ok, Enum.reject(outbound, &response?/1), state}

      {:ok, outbound, state} ->
        {:ok, outbound, state}

      {:error, _error, state} when is_nil(request_id) ->
        {:ok, [], state}

      {:error, error, state} ->
        {:ok, [error_response(request_id, error)], state}
    end
  end

  def handle_message(%{"id" => _id} = message, %__MODULE__{} = state)
      when is_map_key(message, "result") or is_map_key(message, "error") do
    {:ok, [], state}
  end

  def handle_message(_message, %__MODULE__{} = state) do
    {:ok,
     [error_response(nil, Mapping.invalid_request("JSON-RPC request must include a method."))],
     state}
  end

  @spec serve_stdio() :: no_return()
  def serve_stdio do
    owner = self()

    spawn_link(fn ->
      Enum.each(IO.stream(:stdio, :line), &send(owner, {:stdio_line, &1}))
      send(owner, :stdio_eof)
    end)

    serve_loop(new_state(), %{})
  end

  defp serve_loop(state, workers) do
    receive do
      {:stdio_line, line} ->
        case prompt_session_id(line) do
          {:ok, session_id} ->
            task =
              Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor, fn ->
                handle_line(line, state)
              end)

            serve_loop(state, Map.put(workers, task.ref, %{task: task, session_id: session_id}))

          :other ->
            {:ok, outbound, next_state} = handle_line(line, state)
            Enum.each(outbound, &IO.write(:stdio, &1))
            serve_loop(next_state, maybe_cancel_worker(line, workers, state))
        end

      {ref, {:ok, outbound, _worker_state}} when is_map_key(workers, ref) ->
        Process.demonitor(ref, [:flush])
        Enum.each(outbound, &IO.write(:stdio, &1))
        acknowledge_session_reports(workers[ref].session_id, state)
        serve_loop(state, Map.delete(workers, ref))

      {:DOWN, ref, :process, _pid, _reason} when is_map_key(workers, ref) ->
        serve_loop(state, Map.delete(workers, ref))

      :stdio_eof ->
        Process.sleep(:infinity)
    end
  end

  defp dispatch("initialize", params, request_id, state) do
    client_id = Mapping.client_id(params)
    state = %{state | initialized?: true, client_id: client_id}

    {:ok, [success_response(request_id, Mapping.initialize_result(params))], state}
  end

  defp dispatch("session/new", params, request_id, state) do
    with :ok <- ensure_initialized(state),
         :ok <- ensure_surface_enabled(),
         {:ok, session_attrs} <- Mapping.validate_session_params(params) do
      session = %{
        id: "acp_sess_" <> Ecto.UUID.generate(),
        client_id: state.client_id,
        cwd: Map.get(session_attrs, :cwd)
      }

      state = put_in(state.sessions[session.id], session)

      {:ok, [success_response(request_id, %{"sessionId" => session.id})], state}
    else
      {:error, error} ->
        record_protocol_rejection("session/new", params, state, error)
        {:error, error, state}
    end
  end

  defp dispatch("session/prompt", params, request_id, state) do
    with :ok <- ensure_initialized(state),
         :ok <- ensure_surface_enabled(),
         {:ok, session} <- fetch_session(params, state),
         {:ok, text} <- Mapping.flatten_prompt(params) do
      event =
        EventRecorder.record_inbound(Mapping.surface(), %{
          external_event_id: "#{Mapping.surface()}:prompt:#{Ecto.UUID.generate()}",
          external_user_id: Map.fetch!(session, :client_id),
          user_id: "public-protocol:#{Map.fetch!(session, :client_id)}",
          session_id: Map.fetch!(session, :id),
          payload_summary: "session/prompt"
        })

      with {:ok, runtime_response} <-
             Runtime.submit_user_input(Mapping.runtime_request(text, session)),
           :ok <- persist_and_acknowledge(event, runtime_response),
           {:ok, final_response} <- await_response(runtime_response),
           {:ok, outbound} <- Mapping.prompt_outbound(final_response, session, request_id) do
        {:ok, outbound, state}
      else
        {:error, reason} ->
          EventRecorder.mark_failed(event, reason)
          {:error, prompt_error(reason), state}
      end
    else
      {:error, %{} = error} ->
        record_prompt_rejection(params, state, error)
        {:error, error, state}
    end
  end

  defp dispatch("session/cancel", _params, request_id, state) do
    if is_nil(request_id) do
      {:ok, [], state}
    else
      {:ok, [success_response(request_id, %{"stopReason" => "cancelled"})], state}
    end
  end

  defp dispatch("session/request_permission", params, _request_id, state) do
    error = Mapping.advisory_permission_error()
    record_protocol_rejection("session/request_permission", params, state, error)
    {:error, error, state}
  end

  defp dispatch(method, params, _request_id, state) do
    error = Mapping.method_not_found("Unsupported ACP method: #{method}.", "unsupported_method")
    record_protocol_rejection(method, params, state, error)
    {:error, error, state}
  end

  defp persist_and_acknowledge(event, response) do
    case EventRecorder.mark_result_durable(event, response) do
      :ok ->
        Runtime.acknowledge_deliveries(response, %{channel: "acp_stdio"})

      {:error, _reason} = error ->
        _ = Runtime.delivery_failed(response, %{channel: "acp_stdio"})
        error
    end
  end

  defp await_response(%{status: :needs_confirmation} = response), do: {:ok, response}

  defp await_response(%{fanout: %{parent_id: parent_id}, user_id: user_id} = response) do
    case Runtime.await_fanout(parent_id, user_id, Runtime.fanout_continuation_timeout_ms()) do
      {:ok, report} -> {:ok, report_response(response, report)}
      {:timeout, _kickoff} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_response(response), do: {:ok, response}

  defp report_response(response, report) do
    message =
      report.children
      |> Enum.map_join("\n", fn child ->
        "- #{child.title}: #{child.status} — #{Fanout.report_child_detail(child)}"
      end)

    Map.put(response, :message, "Fan-out #{report.status}:\n#{message}")
  end

  defp prompt_session_id(line) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, %{"method" => "session/prompt", "params" => %{"sessionId" => session_id}}}
      when is_binary(session_id) ->
        {:ok, session_id}

      _other ->
        :other
    end
  end

  defp maybe_cancel_worker(line, workers, state) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, %{"method" => "session/cancel", "params" => %{"sessionId" => session_id}}} ->
        shutdown_session_workers(workers, session_id)
        cancel_session_fanouts(session_id, state)
        Map.reject(workers, fn {_ref, worker} -> worker.session_id == session_id end)

      _other ->
        workers
    end
  end

  defp shutdown_session_workers(workers, session_id) do
    workers
    |> Enum.filter(fn {_ref, worker} -> worker.session_id == session_id end)
    |> Enum.each(fn {_ref, worker} -> Task.shutdown(worker.task, :brutal_kill) end)
  end

  defp cancel_session_fanouts(session_id, state) do
    user_id = "public-protocol:#{state.client_id}"

    user_id
    |> Objectives.list_objectives()
    |> Enum.filter(fn objective ->
      objective.fanout_role == "parent" and objective.session_id == session_id and
        objective.status in ~w[open running blocked]
    end)
    |> Enum.each(fn objective ->
      Runner.run(
        "cancel_objective_run",
        %{objective_id: objective.id, reason: "ACP session/cancel"},
        %{
          user_id: user_id,
          channel: "acp_stdio",
          session_id: session_id
        }
      )
    end)
  end

  defp acknowledge_session_reports(session_id, state) do
    user_id = "public-protocol:#{state.client_id}"

    user_id
    |> Objectives.list_objectives()
    |> Enum.filter(fn objective ->
      objective.fanout_role == "parent" and objective.session_id == session_id and
        objective.report_delivery_state == "pending"
    end)
    |> Enum.each(fn parent ->
      Runtime.acknowledge_report_delivery(Fanout.receipt_for(:report, parent.id), %{
        user_id: user_id,
        thread_id: parent.source_thread_id,
        channel: "acp_stdio",
        origin_thread_ref_id: parent.origin_thread_ref_id,
        origin_thread_ref_digest: parent.origin_thread_ref_digest,
        origin_receiver_account_ref: parent.origin_receiver_account_ref
      })
    end)
  end

  defp ensure_initialized(%{initialized?: true}), do: :ok
  defp ensure_initialized(_state), do: {:error, Mapping.not_initialized_error()}

  defp ensure_surface_enabled do
    if Mapping.surface_enabled?(), do: :ok, else: {:error, Mapping.surface_disabled_error()}
  end

  defp fetch_session(%{"sessionId" => session_id}, state) when is_binary(session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, Mapping.unknown_session_error()}
    end
  end

  defp fetch_session(_params, _state),
    do:
      {:error,
       Mapping.invalid_params("sessionId is required.", "missing_session_id", "sessionId")}

  defp prompt_error(%{} = error), do: error

  defp prompt_error(reason),
    do: Mapping.invalid_params("ACP prompt failed: #{inspect(reason)}.", "runtime_error", nil)

  defp record_prompt_rejection(params, state, error) do
    session_id = if is_map(params), do: Map.get(params, "sessionId")
    reason = get_in(error, [:data, "code"]) || Map.get(error, :message) || inspect(error)

    EventRecorder.record_rejection(Mapping.surface(), %{
      external_event_id: "#{Mapping.surface()}:prompt-rejected:#{Ecto.UUID.generate()}",
      external_user_id: state.client_id,
      user_id: "public-protocol:#{state.client_id}",
      session_id: session_id,
      payload_summary: "session/prompt rejected",
      reason: reason
    })
  end

  defp record_protocol_rejection(method, params, state, error) do
    session_id = if is_map(params), do: Map.get(params, "sessionId")
    reason = get_in(error, [:data, "code"]) || Map.get(error, :message) || inspect(error)

    EventRecorder.record_rejection(Mapping.surface(), %{
      external_event_id:
        "#{Mapping.surface()}:#{method_slug(method)}-rejected:#{Ecto.UUID.generate()}",
      external_user_id: state.client_id,
      user_id: "public-protocol:#{state.client_id}",
      session_id: session_id,
      payload_summary: "#{method} rejected",
      reason: reason
    })
  end

  defp method_slug(method) do
    method
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
  end

  defp success_response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, error) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => error.code,
        "message" => error.message
      }
    }

    case Map.get(error, :data) do
      data when is_map(data) and map_size(data) > 0 -> put_in(body, ["error", "data"], data)
      _data -> body
    end
  end

  defp response?(%{"id" => _id}), do: true
  defp response?(_message), do: false

  defp encode_line(message), do: Jason.encode!(message) <> "\n"
end
