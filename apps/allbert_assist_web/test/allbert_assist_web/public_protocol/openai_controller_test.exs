defmodule AllbertAssistWeb.PublicProtocol.OpenAIControllerTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Ecto.Query

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.FanoutRoles
  alias AllbertAssistWeb.PublicProtocol.OpenAIController

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)

    original_wait_observer =
      Application.get_env(:allbert_assist_web, :openai_fanout_wait_observer)

    original_fanout_awaiter = Application.get_env(:allbert_assist_web, :openai_fanout_awaiter)

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
      restore_web_env(:openai_fanout_wait_observer, original_wait_observer)
      restore_web_env(:openai_fanout_awaiter, original_fanout_awaiter)
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

  test "direct models dispatch without the HTTPGate-carried epoch is frozen unavailable" do
    conn = OpenAIController.models(Phoenix.ConnTest.build_conn(:get, "/v1/models", ""), %{})

    assert conn.status == 503
    assert json_response(conn, 503)["error"]["code"] == "product_not_ready"
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

  test "streaming readiness loss cancels continuation with no post-loss durable result or ACK",
       %{conn: conn, token: token} do
    user_id = "public-protocol:openai-client"

    assert {:ok, parent} =
             Objectives.create_objective(
               %{
                 user_id: user_id,
                 title: "OpenAI readiness loss",
                 objective: "Remain pending after the SSE epoch is lost",
                 fanout_role: "parent",
                 source_channel: "openai_api",
                 source_surface: "api"
               },
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    test_pid = self()
    Application.put_env(:allbert_assist_web, :openai_fanout_wait_observer, test_pid)

    Application.put_env(:allbert_assist_web, :openai_fanout_awaiter, fn _parent,
                                                                        _user,
                                                                        _timeout ->
      receive do
        :never -> :unreachable
      end
    end)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        {:ok,
         %{
           message: "Fan-out kickoff before readiness loss",
           status: :completed,
           actions: [],
           fanout: %{parent_id: parent.id, delivery_context: %{}}
         }}
      end,
      fanout_timeout_ms: 30_000
    )

    request =
      Task.async(fn ->
        conn
        |> auth_conn(token)
        |> post_json(%{
          "model" => "local",
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "Stream across loss"}]
        })
      end)

    assert_receive {:openai_fanout_waiting, request_pid, epoch, barrier_ref}, 5_000
    assert request_pid == request.pid

    event_before = latest_openai_event!()
    parent_before = AllbertAssist.Repo.reload!(parent)
    assert event_before.status == "processed"
    refute parent_before.report_delivery_state == "delivered"

    send(request_pid, {:DOWN, barrier_ref, :process, epoch.barrier_pid, :shutdown})
    response_conn = Task.await(request, 5_000)

    assert response_conn.status == 200
    assert response_conn.resp_body =~ "Fan-out kickoff before readiness loss"
    assert response_conn.resp_body =~ ~s("allbert_status":"working")
    refute response_conn.resp_body =~ "data: [DONE]"

    event_after = AllbertAssist.Repo.reload!(event_before)
    parent_after = AllbertAssist.Repo.reload!(parent)

    assert event_after.status == event_before.status
    assert event_after.payload_summary == event_before.payload_summary
    assert parent_after.kickoff_delivery_state == parent_before.kickoff_delivery_state
    assert parent_after.report_delivery_state == parent_before.report_delivery_state
    refute parent_after.report_delivery_state == "delivered"
  end

  test "fanout non-streaming records kickoff before start and holds for joined report", %{
    conn: conn,
    token: token
  } do
    enable_automatic_fanout!()
    FanoutRoles.configure!()
    selector = Task.async(&FanoutReportFixture.select_next_report/0)

    conn =
      conn
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "messages" => [
          %{
            "role" => "user",
            "content" => "Do these 2 tasks in parallel: first task; second task"
          }
        ]
      })

    assert {:ok, _selected} =
             Task.await(selector, FanoutReportFixture.composition_await_timeout_ms())

    body = json_response(conn, 200)

    [parent] =
      "public-protocol:openai-client"
      |> AllbertAssist.Objectives.list_objectives()
      |> Enum.filter(&(&1.fanout_role == "parent"))

    assert get_in(body, ["choices", Access.at(0), "message", "content"]) ==
             Fanout.format_report(Fanout.report(parent))

    assert parent.kickoff_delivery_state == "acknowledged"
    children = Fanout.children(parent)

    assert Enum.map(children, & &1.status) == ["completed", "completed"]

    assert AllbertAssist.Repo.reload!(parent).report_source == "deterministic_fallback"
    assert AllbertAssist.Repo.reload!(parent).report_delivery_state == "delivered"
    assert_fanout_quiesced(parent.id)
  end

  test "fanout streaming flushes kickoff, working status, joined report, and DONE", %{
    conn: conn,
    token: token
  } do
    enable_automatic_fanout!()
    FanoutRoles.configure!()
    selector = Task.async(&FanoutReportFixture.select_next_report/0)

    conn =
      conn
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "stream" => true,
        "messages" => [
          %{
            "role" => "user",
            "content" => "Do these 2 tasks in parallel: first task; second task"
          }
        ]
      })

    assert {:ok, _selected} =
             Task.await(selector, FanoutReportFixture.composition_await_timeout_ms())

    assert conn.status == 200
    assert conn.resp_body =~ "I split this into 2 tasks"
    assert conn.resp_body =~ ~s("allbert_status":"working")

    [parent] =
      "public-protocol:openai-client"
      |> AllbertAssist.Objectives.list_objectives()
      |> Enum.filter(&(&1.fanout_role == "parent"))

    assert conn.resp_body =~ Jason.encode!(Fanout.format_report(Fanout.report(parent)))
    assert conn.resp_body =~ "data: [DONE]"

    eventually(fn -> AllbertAssist.Repo.reload!(parent).report_delivery_state == "delivered" end)
    assert_fanout_quiesced(parent.id)
  end

  for selection_source <- [:model, :fallback] do
    test "fanout non-streaming emits exact stored #{selection_source} report bytes", %{
      conn: conn,
      token: token
    } do
      selection_source = unquote(selection_source)
      selected = selected_public_report!(selection_source)
      install_joined_report_runner!(selected.parent.id)

      conn =
        conn
        |> auth_conn(token)
        |> post_json(%{
          "model" => "local",
          "allbert_thread_id" => selected.parent.source_thread_id,
          "messages" => [%{"role" => "user", "content" => "Return the joined report"}]
        })

      parent = AllbertAssist.Repo.reload!(selected.parent)

      assert get_in(json_response(conn, 200), [
               "choices",
               Access.at(0),
               "message",
               "content"
             ]) == parent.report_body

      assert parent.report_body == selected.report_body

      eventually(fn ->
        AllbertAssist.Repo.reload!(parent).report_delivery_state == "delivered"
      end)
    end

    test "fanout streaming final chunk emits exact stored #{selection_source} report bytes", %{
      conn: conn,
      token: token
    } do
      selection_source = unquote(selection_source)
      selected = selected_public_report!(selection_source)
      install_joined_report_runner!(selected.parent.id)

      conn =
        conn
        |> auth_conn(token)
        |> post_json(%{
          "model" => "local",
          "stream" => true,
          "allbert_thread_id" => selected.parent.source_thread_id,
          "messages" => [%{"role" => "user", "content" => "Stream the joined report"}]
        })

      parent = AllbertAssist.Repo.reload!(selected.parent)

      assert conn.status == 200
      assert final_sse_content(conn.resp_body) == parent.report_body
      assert parent.report_body == selected.report_body
      assert conn.resp_body =~ "data: [DONE]"

      eventually(fn ->
        AllbertAssist.Repo.reload!(parent).report_delivery_state == "delivered"
      end)
    end
  end

  test "fanout timeout returns kickoff while the eventual report remains pending", %{
    conn: conn,
    token: token
  } do
    enable_automatic_fanout!()
    FanoutRoles.configure!()
    selector = Task.async(&FanoutReportFixture.select_next_report/0)

    runtime_config = Application.get_env(:allbert_assist, Runtime, [])

    Application.put_env(
      :allbert_assist,
      Runtime,
      Keyword.put(runtime_config, :fanout_timeout_ms, 0)
    )

    conn =
      conn
      |> auth_conn(token)
      |> post_json(%{
        "model" => "local",
        "messages" => [
          %{
            "role" => "user",
            "content" => "Do these 2 tasks in parallel: first task; second task"
          }
        ]
      })

    assert {:ok, _selected} =
             Task.await(selector, FanoutReportFixture.composition_await_timeout_ms())

    assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) =~
             "I split this into 2 tasks"

    [parent] =
      "public-protocol:openai-client"
      |> AllbertAssist.Objectives.list_objectives()
      |> Enum.filter(&(&1.fanout_role == "parent"))

    eventually(fn -> AllbertAssist.Repo.reload!(parent).report_delivery_state == "pending" end)
    assert_fanout_quiesced(parent.id)
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
    assert {:ok, _setting} =
             Settings.put(
               "openai_api.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "openai_api.models_enabled",
               ["local"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp enable_automatic_fanout! do
    assert {:ok, _setting} =
             Settings.put(
               "objectives.fanout.rollout_mode",
               "automatic",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp set_rate_limit!(client_id, rate_limit) do
    {:ok, clients} = Settings.get("openai_api.clients")
    entry = Map.fetch!(clients, client_id)
    updated = Map.put(clients, client_id, Map.put(entry, "rate_limit", rate_limit))

    assert {:ok, _setting} =
             Settings.put(
               "openai_api.clients",
               updated,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp selected_public_report!(selection_source) do
    user_id = "public-protocol:openai-client"
    {:ok, thread} = Conversations.create_general_thread(user_id, "OpenAI report parity")

    FanoutReportFixture.selected_report!(selection_source, %{
      user_id: user_id,
      source_channel: "openai_api",
      source_surface: "api",
      source_thread_id: thread.id
    })
  end

  defp install_joined_report_runner!(parent_id) do
    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        {:ok,
         %{
           message: "The joined report is ready.",
           status: :completed,
           actions: [],
           fanout: %{parent_id: parent_id, delivery_context: %{}}
         }}
      end
    )
  end

  defp final_sse_content(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: {"))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
    |> List.last()
    |> get_in(["choices", Access.at(0), "delta", "content"])
  end

  defp context do
    AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
      actor: "test",
      channel: "test",
      audit?: false
    })
  end

  defp latest_openai_event! do
    AllbertAssist.Repo.one!(
      from(event in Event,
        where: event.channel == "openai_api",
        order_by: [desc: event.inserted_at],
        limit: 1
      )
    )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp restore_web_env(key, nil), do: Application.delete_env(:allbert_assist_web, key)
  defp restore_web_env(key, value), do: Application.put_env(:allbert_assist_web, key, value)

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp assert_fanout_quiesced(parent_id) do
    eventually(fn ->
      Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent_id}) == []
    end)
  end
end
