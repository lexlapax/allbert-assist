defmodule AllbertAssistWeb.PublicProtocol.OpenAIController do
  @moduledoc """
  OpenAI-compatible HTTP API shim for v0.51.
  """

  use AllbertAssistWeb, :controller

  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.PublicProtocol.OpenAI.Mapping
  alias AllbertAssist.Runtime
  alias AllbertAssist.Surface.EventRecorder

  plug AllbertAssistWeb.Plugs.PublicProtocolOpenAIAuth,
       [surface: "openai_api"] when action in [:chat_completions, :models]

  def models(conn, _params) do
    case Mapping.models_response() do
      {:ok, body} -> json(conn, body)
      {:error, error} -> send_error(conn, error)
    end
  end

  def chat_completions(conn, params) do
    auth = conn.assigns.public_protocol_auth

    case Mapping.parse_chat_request(params, auth) do
      {:ok, chat} ->
        event =
          EventRecorder.record_inbound("openai_api", %{
            external_event_id: "openai_api:chat:#{Ecto.UUID.generate()}",
            external_user_id: Map.fetch!(auth, :client_id),
            user_id: chat.user_id,
            session_id: Map.get(chat, :session_id),
            thread_id: Map.get(chat, :thread_id),
            payload_summary: "chat.completions #{chat.model}"
          })

        with {:ok, runtime_response} <-
               Runtime.submit_user_input(Mapping.runtime_request(chat, auth)) do
          deliver_chat_response(conn, chat, auth, event, runtime_response)
        else
          {:error, %{status: _status} = error} ->
            EventRecorder.mark_failed(event, error)
            send_error(conn, error)

          {:error, reason} ->
            EventRecorder.mark_failed(event, reason)
            send_error(conn, Mapping.runtime_error(reason))
        end

      {:error, %{status: _status} = error} ->
        EventRecorder.record_rejection("openai_api", %{
          external_event_id: "openai_api:rejected:#{Ecto.UUID.generate()}",
          external_user_id: Map.get(auth, :client_id),
          reason: error.code,
          payload_summary: error.message
        })

        send_error(conn, error)
    end
  end

  defp deliver_chat_response(conn, %{stream?: true} = chat, auth, event, response) do
    with {:ok, kickoff} <- Mapping.chat_completion(response, chat, auth),
         {:ok, conn} <-
           conn
           |> put_resp_content_type("text/event-stream")
           |> send_chunked(200)
           |> chunk(Mapping.sse_chunk(kickoff)),
         :ok <- persist_and_acknowledge(event, response),
         {:ok, conn} <- chunk(conn, status_chunk(kickoff, "working")) do
      finish_stream(conn, chat, auth, response)
    else
      {:error, :closed} ->
        _ = Runtime.delivery_failed(response, %{channel: "openai_api"})
        conn

      {:error, reason} ->
        _ = Runtime.delivery_failed(response, %{channel: "openai_api"})
        EventRecorder.mark_failed(event, reason)
        conn
    end
  end

  defp deliver_chat_response(conn, chat, auth, event, response) do
    with :ok <- persist_and_acknowledge(event, response),
         {:ok, final_response} <- await_response(response),
         {:ok, body} <- Mapping.chat_completion(final_response, chat, auth) do
      conn = json(conn, body)
      _ = acknowledge_join_report(final_response)
      conn
    else
      {:timeout, _kickoff} ->
        with {:ok, body} <- Mapping.chat_completion(response, chat, auth) do
          json(conn, body)
        end

      {:error, %{status: _status} = error} ->
        send_error(conn, error)

      {:error, reason} ->
        EventRecorder.mark_failed(event, reason)
        send_error(conn, Mapping.runtime_error(reason))
    end
  end

  defp finish_stream(conn, chat, auth, response) do
    case await_response(response) do
      {:ok, final_response} ->
        with {:ok, completion} <- Mapping.chat_completion(final_response, chat, auth),
             {:ok, conn} <- chunk(conn, Mapping.sse_chunk(completion, finish?: true)),
             {:ok, conn} <- chunk(conn, "data: [DONE]\n\n") do
          _ = acknowledge_join_report(final_response)
          conn
        else
          _error -> conn
        end

      {:timeout, kickoff} ->
        finish_timeout_stream(conn, chat, auth, response, kickoff)

      {:error, _reason} ->
        conn
    end
  end

  defp persist_and_acknowledge(event, response) do
    case EventRecorder.mark_result_durable(event, response) do
      :ok ->
        Runtime.acknowledge_deliveries(response, %{channel: "openai_api"})

      {:error, _reason} = error ->
        _ = Runtime.delivery_failed(response, %{channel: "openai_api"})
        error
    end
  end

  defp await_response(%{status: :needs_confirmation} = response), do: {:ok, response}

  defp await_response(%{fanout: %{parent_id: parent_id}, user_id: user_id} = response) do
    case Runtime.await_fanout(parent_id, user_id, Runtime.fanout_continuation_timeout_ms()) do
      {:ok, report} -> {:ok, report_response(response, report)}
      {:timeout, kickoff} -> {:timeout, kickoff}
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

    response
    |> Map.put(:message, "Fan-out #{report.status}:\n#{message}")
    |> Map.put(:model_payload, "Fan-out #{report.status}:\n#{message}")
    |> Map.put(:surface_payload, "Fan-out #{report.status}:\n#{message}")
  end

  defp acknowledge_join_report(%{fanout: %{parent_id: parent_id}} = response) do
    context =
      %{
        user_id: response.user_id,
        thread_id: response.thread_id,
        channel: "openai_api"
      }
      |> Map.merge(get_in(response, [:fanout, :delivery_context]) || %{})

    parent_id
    |> then(&Fanout.receipt_for(:report, &1))
    |> Runtime.acknowledge_report_delivery(context)
  end

  defp acknowledge_join_report(_response), do: :ok

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

  defp finish_timeout_stream(conn, chat, auth, response, _kickoff) do
    with {:ok, body} <- Mapping.chat_completion(response, chat, auth),
         {:ok, conn} <- chunk(conn, Mapping.sse_chunk(body, finish?: true)),
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
end
