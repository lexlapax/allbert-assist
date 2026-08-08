defmodule AllbertAssistWeb.PublicProtocol.OpenAIController do
  @moduledoc """
  OpenAI-compatible HTTP API shim for v0.51.
  """

  use AllbertAssistWeb, :controller

  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.PublicProtocol.OpenAI.FanoutWait
  alias AllbertAssist.PublicProtocol.OpenAI.Mapping
  alias AllbertAssist.Runtime
  alias AllbertAssist.Surface.EventRecorder
  alias AllbertAssistWeb.PackReadiness
  alias AllbertAssistWeb.PackReadiness.HTTPGate

  plug AllbertAssistWeb.Plugs.PublicProtocolOpenAIAuth,
       [surface: "openai_api"] when action in [:chat_completions, :models]

  def models(conn, _params) do
    if PackReadiness.validate_conn(conn) == :ok do
      case Mapping.models_response() do
        {:ok, body} -> json(conn, body)
        {:error, error} -> send_error(conn, error)
      end
    else
      HTTPGate.unavailable(conn)
    end
  end

  def chat_completions(conn, params) do
    auth = conn.assigns.public_protocol_auth
    epoch = conn.private[:allbert_pack_epoch]

    case Mapping.parse_chat_request(params, auth) do
      {:ok, chat} ->
        if current?(epoch) do
          event =
            EventRecorder.record_inbound(
              "openai_api",
              %{
                external_event_id: "openai_api:chat:#{Ecto.UUID.generate()}",
                external_user_id: Map.fetch!(auth, :client_id),
                user_id: chat.user_id,
                session_id: Map.get(chat, :session_id),
                thread_id: Map.get(chat, :thread_id),
                payload_summary: "chat.completions #{chat.model}"
              },
              %{allbert_pack_epoch: epoch}
            )

          with :ok <- current(epoch),
               {:ok, runtime_response} <-
                 Runtime.submit_user_input(Mapping.runtime_request(chat, auth),
                   allbert_pack_epoch: epoch
                 ) do
            deliver_chat_response(conn, chat, auth, event, runtime_response, epoch)
          else
            {:error, reason} when reason in [:product_not_ready, :stale_epoch] ->
              HTTPGate.unavailable(conn)

            {:error, %{status: _status} = error} ->
              EventRecorder.mark_failed(event, error, %{allbert_pack_epoch: epoch})
              send_error(conn, error)

            {:error, reason} ->
              EventRecorder.mark_failed(event, reason, %{allbert_pack_epoch: epoch})
              send_error(conn, Mapping.runtime_error(reason))
          end
        else
          HTTPGate.unavailable(conn)
        end

      {:error, %{status: _status} = error} ->
        EventRecorder.record_rejection(
          "openai_api",
          %{
            external_event_id: "openai_api:rejected:#{Ecto.UUID.generate()}",
            external_user_id: Map.get(auth, :client_id),
            reason: error.code,
            payload_summary: error.message
          },
          %{allbert_pack_epoch: epoch}
        )

        send_error(conn, error)
    end
  end

  defp deliver_chat_response(conn, %{stream?: true} = chat, auth, event, response, epoch) do
    with :ok <- current(epoch),
         {:ok, kickoff} <- Mapping.chat_completion(response, chat, auth),
         {:ok, conn} <-
           conn
           |> put_resp_content_type("text/event-stream")
           |> send_chunked(200)
           |> chunk(Mapping.sse_chunk(kickoff)),
         :ok <- persist_and_acknowledge(event, response, epoch),
         :ok <- current(epoch),
         {:ok, conn} <- chunk(conn, status_chunk(kickoff, "working")) do
      finish_stream(conn, chat, auth, response, epoch)
    else
      {:error, :closed} ->
        maybe_delivery_failed(response, epoch)
        conn

      {:error, reason} ->
        maybe_delivery_failed(response, epoch)

        if current?(epoch),
          do: EventRecorder.mark_failed(event, reason, %{allbert_pack_epoch: epoch})

        conn
    end
  end

  defp deliver_chat_response(conn, chat, auth, event, response, epoch) do
    with :ok <- persist_and_acknowledge(event, response, epoch),
         {:ok, final_response} <- await_response(response, epoch),
         :ok <- current(epoch),
         {:ok, body} <- Mapping.chat_completion(final_response, chat, auth) do
      conn = json(conn, body)
      _ = acknowledge_join_report(final_response, epoch)
      conn
    else
      {:timeout, _kickoff} ->
        with :ok <- current(epoch),
             {:ok, body} <- Mapping.chat_completion(response, chat, auth) do
          json(conn, body)
        end

      {:error, reason} when reason in [:product_not_ready, :stale_epoch, :readiness_lost] ->
        HTTPGate.unavailable(conn)

      {:error, %{status: _status} = error} ->
        send_error(conn, error)

      {:error, reason} ->
        EventRecorder.mark_failed(event, reason, %{allbert_pack_epoch: epoch})
        send_error(conn, Mapping.runtime_error(reason))
    end
  end

  defp finish_stream(conn, chat, auth, response, epoch) do
    case await_response(response, epoch) do
      {:ok, final_response} ->
        with :ok <- current(epoch),
             {:ok, completion} <- Mapping.chat_completion(final_response, chat, auth),
             {:ok, conn} <- chunk(conn, Mapping.sse_chunk(completion, finish?: true)),
             :ok <- current(epoch),
             {:ok, conn} <- chunk(conn, "data: [DONE]\n\n") do
          _ = acknowledge_join_report(final_response, epoch)
          conn
        else
          _error -> conn
        end

      {:timeout, kickoff} ->
        finish_timeout_stream(conn, chat, auth, response, kickoff, epoch)

      {:error, _reason} ->
        conn
    end
  end

  defp persist_and_acknowledge(event, response, epoch) do
    with :ok <- current(epoch),
         :ok <- EventRecorder.mark_result_durable(event, response, %{allbert_pack_epoch: epoch}),
         :ok <- current(epoch) do
      Runtime.acknowledge_deliveries(response, %{
        channel: "openai_api",
        allbert_pack_epoch: epoch
      })
    else
      {:error, _reason} = error ->
        maybe_delivery_failed(response, epoch)
        error
    end
  end

  defp await_response(%{status: :needs_confirmation} = response, epoch) do
    if current?(epoch), do: {:ok, response}, else: {:error, :readiness_lost}
  end

  defp await_response(%{fanout: %{parent_id: parent_id}, user_id: user_id} = response, epoch) do
    await_fanout_epoch(parent_id, user_id, response, epoch)
  end

  defp await_response(response, epoch) do
    if current?(epoch), do: {:ok, response}, else: {:error, :readiness_lost}
  end

  defp report_response(response, report) do
    report_body = Fanout.format_report(report)

    response
    |> Map.put(:message, report_body)
    |> Map.put(:model_payload, report_body)
    |> Map.put(:surface_payload, report_body)
  end

  defp acknowledge_join_report(%{fanout: %{parent_id: parent_id}} = response, epoch) do
    context =
      %{
        user_id: response.user_id,
        thread_id: response.thread_id,
        channel: "openai_api",
        allbert_pack_epoch: epoch
      }
      |> Map.merge(get_in(response, [:fanout, :delivery_context]) || %{})

    if current?(epoch) do
      parent_id
      |> then(&Fanout.receipt_for(:report, &1))
      |> Runtime.acknowledge_report_delivery(context)
    end
  end

  defp acknowledge_join_report(_response, _epoch), do: :ok

  defp status_chunk(completion, status) do
    completion
    |> Map.put("choices", [
      %{
        "index" => 0,
        "message" => %{"role" => "assistant", "content" => ""},
        "finish_reason" => nil,
        "logprobs" => nil
      }
    ])
    |> Map.put("allbert_status", status)
    |> Mapping.sse_chunk()
  end

  defp finish_timeout_stream(conn, chat, auth, response, _kickoff, epoch) do
    with :ok <- current(epoch),
         {:ok, body} <- Mapping.chat_completion(response, chat, auth),
         {:ok, conn} <- chunk(conn, Mapping.sse_chunk(body, finish?: true)),
         :ok <- current(epoch),
         {:ok, conn} <- chunk(conn, "data: [DONE]\n\n") do
      conn
    else
      _error -> conn
    end
  end

  defp send_error(conn, error) do
    conn
    |> put_status(Mapping.error_status(error))
    |> json(Mapping.error_body(error))
  end

  defp current?(epoch), do: current(epoch) == :ok
  defp current(epoch), do: PackReadiness.validate(epoch)

  defp maybe_delivery_failed(response, epoch) do
    if current?(epoch),
      do: Runtime.delivery_failed(response, %{channel: "openai_api", allbert_pack_epoch: epoch})

    :ok
  end

  defp await_fanout_epoch(parent_id, user_id, response, epoch) do
    barrier_ref = Process.monitor(epoch.barrier_pid)
    notify_fanout_wait(epoch, barrier_ref)

    task =
      Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor, fn ->
        await_fanout(parent_id, user_id, Runtime.fanout_continuation_timeout_ms())
      end)

    task_ref = task.ref

    receive do
      {:DOWN, ^barrier_ref, :process, _pid, _reason} ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :readiness_lost}

      {^task_ref, {:ok, report}} ->
        Process.demonitor(barrier_ref, [:flush])
        {:ok, report_response(response, report)}

      {^task_ref, {:timeout, kickoff}} ->
        Process.demonitor(barrier_ref, [:flush])
        {:timeout, kickoff}

      {^task_ref, {:error, reason}} ->
        Process.demonitor(barrier_ref, [:flush])
        {:error, reason}

      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        Process.demonitor(barrier_ref, [:flush])
        {:error, :fanout_unavailable}
    end
  end

  defp await_fanout(parent_id, user_id, timeout_ms),
    do: FanoutWait.await(parent_id, user_id, timeout_ms)

  defp notify_fanout_wait(epoch, barrier_ref), do: FanoutWait.notify(epoch, barrier_ref)
end
