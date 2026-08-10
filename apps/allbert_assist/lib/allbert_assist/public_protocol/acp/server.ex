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
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.PublicProtocol.Acp.Mapping
  alias AllbertAssist.Runtime
  alias AllbertAssist.Surface.EventRecorder

  defstruct initialized?: false,
            client_id: Mapping.default_client_id(),
            sessions: %{},
            report_deliveries: [],
            report_delivery_epochs: %{}

  @type state :: %__MODULE__{
          initialized?: boolean(),
          client_id: String.t(),
          sessions: map(),
          report_deliveries: [String.t()],
          report_delivery_epochs: %{optional(String.t()) => map()}
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

      {ref, {:ok, outbound, worker_state}} when is_map_key(workers, ref) ->
        Process.demonitor(ref, [:flush])

        _result =
          acknowledge_written_reports(outbound, worker_state, workers[ref].session_id, state)

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
         {:ok, text} <- Mapping.flatten_prompt(params),
         {:ok, epoch} <- EffectGuard.admit_ready(),
         :ok <- EffectGuard.validate(epoch) do
      event =
        EventRecorder.record_inbound(
          Mapping.surface(),
          %{
            external_event_id: "#{Mapping.surface()}:prompt:#{Ecto.UUID.generate()}",
            external_user_id: Map.fetch!(session, :client_id),
            user_id: "public-protocol:#{Map.fetch!(session, :client_id)}",
            session_id: Map.fetch!(session, :id),
            payload_summary: "session/prompt"
          },
          %{allbert_pack_epoch: epoch}
        )

      with {:ok, runtime_response} <-
             Runtime.submit_user_input(
               Mapping.runtime_request(text, session),
               allbert_pack_epoch: epoch
             ),
           :ok <- persist_and_acknowledge(event, runtime_response, epoch),
           {:ok, final_response} <- await_response(runtime_response),
           {:ok, outbound} <- Mapping.prompt_outbound(final_response, session, request_id) do
        report_deliveries = report_delivery_ids(final_response)

        {:ok, outbound,
         %{
           state
           | report_deliveries: report_deliveries,
             report_delivery_epochs: Map.new(report_deliveries, &{&1, epoch})
         }}
      else
        {:error, reason} ->
          maybe_mark_failed(event, reason, epoch)
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

  defp persist_and_acknowledge(event, response, epoch) do
    with :ok <- EffectGuard.validate(epoch) do
      case EventRecorder.mark_result_durable(event, response, %{allbert_pack_epoch: epoch}) do
        :ok ->
          with :ok <- EffectGuard.validate(epoch) do
            Runtime.acknowledge_kickoff_delivery(response, %{
              channel: "acp_stdio",
              allbert_pack_epoch: epoch
            })
          end

        {:error, _reason} = error ->
          if EffectGuard.validate(epoch) == :ok,
            do:
              Runtime.delivery_failed(response, %{
                channel: "acp_stdio",
                allbert_pack_epoch: epoch
              })

          error
      end
    end
  end

  defp maybe_mark_failed(event, reason, epoch) do
    if EffectGuard.validate(epoch) == :ok,
      do: EventRecorder.mark_failed(event, reason, %{allbert_pack_epoch: epoch})

    :ok
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
    report_body = Fanout.format_report(report)

    response
    |> Map.put(:message, Enum.join([response.message, report_body], "\n\n"))
    |> Map.put(:joined_report_parent_id, report.parent_objective_id)
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

  @doc false
  @spec cancel_session_fanouts(String.t(), state()) :: :ok
  def cancel_session_fanouts(session_id, %__MODULE__{} = state) do
    user_id = "public-protocol:#{state.client_id}"

    user_id
    |> Objectives.control_objectives(session_id: session_id, fanout_role: "parent")
    |> Enum.each(fn objective ->
      case Fanout.parent_projection(objective) do
        %{phase: phase} when phase in [:awaiting_kickoff, :running] ->
          Runner.run(
            "cancel_objective_run",
            %{objective_id: objective.id, reason: "ACP session/cancel"},
            %{
              user_id: user_id,
              channel: "acp_stdio",
              session_id: session_id
            }
          )

        %{phase: :recovering} ->
          Fanout.wake_recovery(objective)

        _not_active ->
          :ok
      end
    end)

    :ok
  end

  defp report_delivery_ids(response) do
    pending_ids =
      response
      |> Map.get(:pending_reports, [])
      |> Enum.map(&Map.get(&1, :parent_objective_id))

    [Map.get(response, :joined_report_parent_id) | pending_ids]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc false
  @spec acknowledge_written_reports([term()], state(), String.t(), state(), function()) ::
          :ok | {:error, term()}
  def acknowledge_written_reports(
        outbound,
        %__MODULE__{} = worker_state,
        session_id,
        %__MODULE__{} = owner_state,
        writer_fun \\ &IO.write(:stdio, &1)
      )
      when is_list(outbound) and is_binary(session_id) and is_function(writer_fun, 1) do
    with :ok <- write_all(outbound, writer_fun) do
      acknowledge_report_deliveries(
        worker_state.report_deliveries,
        session_id,
        worker_state,
        owner_state
      )
    end
  end

  defp write_all(outbound, writer_fun) do
    Enum.reduce_while(outbound, :ok, fn line, :ok ->
      case safe_write(writer_fun, line) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:stdio_write_failed, reason}}}
      end
    end)
  end

  defp safe_write(writer_fun, line) do
    case writer_fun.(line) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_write_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The epoch for a given report delivery is stamped on the worker_state that
  # ran the dispatch which admitted it (report_delivery_epochs), not on the
  # owner_state passed in for identity -- looking it up on owner_state always
  # returned nil (owner_state.report_delivery_epochs is empty at this point)
  # and every acknowledgement failed with :product_not_ready.
  defp acknowledge_report_deliveries(parent_ids, session_id, worker_state, owner_state) do
    user_id = "public-protocol:#{owner_state.client_id}"

    Enum.reduce_while(parent_ids, :ok, fn parent_id, result ->
      acknowledge_report(
        parent_id,
        result,
        user_id,
        session_id,
        Map.get(worker_state.report_delivery_epochs, parent_id)
      )
    end)
  end

  defp acknowledge_report(parent_id, :ok, user_id, session_id, epoch) do
    case Objectives.get_objective(user_id, parent_id) do
      {:ok,
       %{fanout_role: "parent", report_delivery_state: "pending", session_id: ^session_id} =
           parent} ->
        acknowledge_pending_report(parent, user_id, epoch)

      _not_delivered_by_worker ->
        {:cont, :ok}
    end
  end

  defp acknowledge_pending_report(parent, user_id, epoch) do
    context = %{
      user_id: user_id,
      thread_id: parent.source_thread_id,
      channel: "acp_stdio",
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      origin_receiver_account_ref: parent.origin_receiver_account_ref,
      allbert_pack_epoch: epoch
    }

    case Runtime.acknowledge_report_delivery(Fanout.receipt_for(:report, parent.id), context) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {parent.id, reason}}}
    end
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

  defp prompt_error({:inbound_admission_failed, _kind} = reason),
    do: Mapping.invalid_params(Runtime.operator_error_message(reason), "runtime_error", nil)

  defp prompt_error(reason),
    do: Mapping.invalid_params("ACP prompt failed: #{inspect(reason)}.", "runtime_error", nil)

  defp record_prompt_rejection(params, state, error) do
    session_id = if is_map(params), do: Map.get(params, "sessionId")
    reason = get_in(error, [:data, "code"]) || Map.get(error, :message) || inspect(error)

    EventRecorder.record_rejection(
      Mapping.surface(),
      %{
        external_event_id: "#{Mapping.surface()}:prompt-rejected:#{Ecto.UUID.generate()}",
        external_user_id: state.client_id,
        user_id: "public-protocol:#{state.client_id}",
        session_id: session_id,
        payload_summary: "session/prompt rejected",
        reason: reason
      },
      effect_context(state)
    )
  end

  defp record_protocol_rejection(method, params, state, error) do
    session_id = if is_map(params), do: Map.get(params, "sessionId")
    reason = get_in(error, [:data, "code"]) || Map.get(error, :message) || inspect(error)

    EventRecorder.record_rejection(
      Mapping.surface(),
      %{
        external_event_id:
          "#{Mapping.surface()}:#{method_slug(method)}-rejected:#{Ecto.UUID.generate()}",
        external_user_id: state.client_id,
        user_id: "public-protocol:#{state.client_id}",
        session_id: session_id,
        payload_summary: "#{method} rejected",
        reason: reason
      },
      effect_context(state)
    )
  end

  # Protocol rejections can occur before session/prompt admits an epoch. The
  # state struct never carries one (it is only populated once a prompt is
  # admitted), so admit a fresh epoch here instead of always reading nil --
  # Channels.create_event/2 fails closed without one and the rejection audit
  # event was silently dropped otherwise.
  defp effect_context(_state) do
    case EffectGuard.admit_ready() do
      {:ok, epoch} -> %{allbert_pack_epoch: epoch}
      {:error, _reason} -> %{}
    end
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
