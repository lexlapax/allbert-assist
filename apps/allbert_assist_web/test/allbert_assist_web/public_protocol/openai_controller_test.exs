defmodule AllbertAssistWeb.PublicProtocol.OpenAIControllerTest do
  use AllbertAssistWeb.ConnCase, async: false, lane: :global_process_serial

  import Ecto.Query

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-openai-controller-#{System.unique_integer([:positive])}"
      )

    runner = fn _signal, request ->
      send(parent, {:runtime_request, request})

      {:ok,
       %{
         message: "Runtime response: #{request.text}",
         status: :completed,
         actions: []
       }}
    end

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    RateLimiter.reset_for_test()

    enable_openai_api!()
    {:ok, created} = TokenAuth.create(:openai_api, "openai-client", context())

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      RateLimiter.reset_for_test()
      File.rm_rf!(root)
    end)

    {:ok, token: created.token}
  end

  test "models lists only Settings-enabled aliases", %{conn: conn, token: token} do
    conn =
      conn
      |> auth_conn(token)
      |> get(~p"/v1/models")

    assert %{
             "object" => "list",
             "data" => [%{"id" => "local", "object" => "model", "owned_by" => "allbert"}]
           } = json_response(conn, 200)
  end

  test "chat completions flattens text messages into a runtime turn", %{conn: conn, token: token} do
    conn =
      conn
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "user" => "openai-user",
        "messages" => [
          %{"role" => "developer", "content" => "Be brief."},
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "Hello"}]}
        ]
      })

    body = json_response(conn, 200)
    assert body["object"] == "chat.completion"
    assert body["model"] == "local"
    assert [%{"message" => %{"role" => "assistant", "content" => content}}] = body["choices"]
    assert content =~ "developer: Be brief.\nuser: Hello"

    assert_received {:runtime_request,
                     %{
                       channel: :openai_api,
                       user_id: "openai-user",
                       metadata: %{
                         public_protocol: %{surface: "openai_api", client_id: "openai-client"}
                       }
                     }}

    assert %Event{channel: "openai_api", status: "processed", user_id: "openai-user"} =
             AllbertAssist.Repo.one(
               from(event in Event,
                 where: event.channel == "openai_api" and event.status == "processed",
                 order_by: [desc: event.inserted_at],
                 limit: 1
               )
             )
  end

  test "missing token returns OpenAI-shaped auth error", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post_json(%{
        "model" => "local",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

    body = json_response(conn, 401)
    assert body["error"]["type"] == "authentication_error"
    assert body["error"]["code"] == "missing_client_id"
    assert Map.has_key?(body["error"], "param")

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "unsupported tool and media fields are rejected before runtime", %{
    conn: conn,
    token: token
  } do
    tools_conn =
      conn
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "tools" => [],
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

    assert json_response(tools_conn, 400)["error"]["param"] == "tools"
    refute_received {:runtime_request, _request}

    media_conn =
      recycle(tools_conn)
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_audio", "input_audio" => %{"data" => "abc", "format" => "wav"}}
            ]
          }
        ]
      })

    assert json_response(media_conn, 400)["error"]["code"] == "unsupported_content_part"
    refute_received {:runtime_request, _request}
  end

  test "streaming returns event-stream chat completion chunks and DONE", %{
    conn: conn,
    token: token
  } do
    conn =
      conn
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "Stream please"}]
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    assert conn.resp_body =~ "\"object\":\"chat.completion.chunk\""
    assert conn.resp_body =~ "data: [DONE]"
  end

  test "confirmation-pending turns create client-owned readback ids", %{conn: conn, token: token} do
    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(self(), {:pending_runtime_request, request})

        {:ok,
         %{
           message: "Approval required.",
           status: :needs_confirmation,
           approval_handoff: %{confirmation_id: "conf_openai_fixture"},
           actions: []
         }}
      end
    )

    conn =
      conn
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "messages" => [%{"role" => "user", "content" => "Do something gated"}]
      })

    body = json_response(conn, 200)
    assert body["allbert_status"] == "pending"
    assert body["allbert_public_call_id"] =~ "pubcall_"

    assert {:ok, readback} =
             ResultReadback.get_for_client(
               body["allbert_public_call_id"],
               "openai_api",
               "openai-client"
             )

    assert readback.status == :pending
  end

  test "rate limit rejects before runtime with OpenAI-shaped error", %{conn: conn, token: token} do
    set_rate_limit!("openai-client", %{"limit" => 1, "period_ms" => 60_000, "burst" => 0})

    request = %{
      "model" => "local",
      "messages" => [%{"role" => "user", "content" => "Hello"}]
    }

    first =
      conn
      |> auth_conn(token)
      |> post_json(request)

    assert first.status == 200

    second =
      recycle(first)
      |> auth_conn(token)
      |> post_json(request)

    body = json_response(second, 429)
    assert body["error"]["type"] == "rate_limit_error"
    assert body["error"]["code"] == "rate_limited"

    assert get_resp_header(second, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]
  end

  defp auth_conn(conn, token, client_id \\ "openai-client") do
    conn
    |> put_req_header("x-allbert-client-id", client_id)
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp post_json(conn, body), do: post(conn, ~p"/v1/chat/completions", Jason.encode!(body))

  defp enable_openai_api! do
    assert {:ok, _setting} = Settings.put("openai_api.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("openai_api.models_enabled", ["local"], %{audit?: false})
  end

  defp set_rate_limit!(client_id, rate_limit) do
    {:ok, clients} = Settings.get("openai_api.clients")
    entry = Map.fetch!(clients, client_id)
    updated = Map.put(clients, client_id, Map.put(entry, "rate_limit", rate_limit))

    assert {:ok, _setting} = Settings.put("openai_api.clients", updated, %{audit?: false})
  end

  defp context, do: %{actor: "test", channel: "test", audit?: false}

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
