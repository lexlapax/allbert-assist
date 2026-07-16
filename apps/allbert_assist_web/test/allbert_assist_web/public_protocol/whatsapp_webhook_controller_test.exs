defmodule AllbertAssistWeb.PublicProtocol.WhatsAppWebhookControllerTest do
  use AllbertAssistWeb.ConnCase, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssistWeb.Plugs.PublicProtocolBodyCap
  alias AllbertAssistWeb.Plugs.PublicProtocolBodyReader
  alias AllbertAssistWeb.Plugs.PublicProtocolWebhookAuth

  @phone_number_id "15551234567"
  @app_secret_ref "secret://channels/whatsapp/app_secret"
  @verify_token_ref "secret://channels/whatsapp/webhook_verify_token"
  @app_secret "whatsapp-app-secret"
  @verify_token "verify-token"

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-whatsapp-webhook-controller-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    RateLimiter.reset_for_test()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      RateLimiter.reset_for_test()
      File.rm_rf!(root)
    end)

    configure_whatsapp_webhook!()
    :ok
  end

  test "verification challenge answers hub.challenge without runtime authority", %{conn: conn} do
    conn =
      get(
        conn,
        ~p"/webhooks/whatsapp/#{@phone_number_id}",
        %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => @verify_token,
          "hub.challenge" => "challenge-123"
        }
      )

    assert conn.status == 200
    assert conn.resp_body == "challenge-123"

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "challenge rejects an invalid verify token", %{conn: conn} do
    conn =
      get(
        conn,
        ~p"/webhooks/whatsapp/#{@phone_number_id}",
        %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong",
          "hub.challenge" => "challenge-123"
        }
      )

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "invalid_webhook_verify_token"
  end

  test "pre-parser auth preserves raw body for Plug.Parsers" do
    raw_body = ~s({"object":"whatsapp_business_account","entry":[{"id":"entry-1"}]})

    conn =
      Phoenix.ConnTest.build_conn(:post, "/webhooks/whatsapp/#{@phone_number_id}", raw_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature(raw_body))
      |> PublicProtocolWebhookAuth.call([])

    refute conn.halted
    assert conn.private[:allbert_public_protocol_raw_body] == raw_body

    assert {:ok, ^raw_body, parsed_conn} =
             PublicProtocolBodyReader.read_body(conn, length: 10_485_760)

    assert parsed_conn.private[:allbert_public_protocol_raw_body] == raw_body
  end

  test "valid signature is accepted and exposes only raw-body hash evidence", %{conn: conn} do
    raw_body = ~s({"object":"whatsapp_business_account","entry":[{"id":"entry-1"}]})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature(raw_body))
      |> post(~p"/webhooks/whatsapp/#{@phone_number_id}", raw_body)

    assert conn.status == 202

    response = json_response(conn, 202)
    assert response["status"] == "accepted"
    assert response["surface"] == "whatsapp_webhook"
    assert response["phone_number_id"] == @phone_number_id
    assert response["raw_body_sha256"] == sha256(raw_body)
    refute inspect(response) =~ raw_body
  end

  test "bad signature is rejected before invalid JSON can be parsed", %{conn: conn} do
    raw_body = "{not json"

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=" <> String.duplicate("0", 64))
      |> post(~p"/webhooks/whatsapp/#{@phone_number_id}", raw_body)

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "invalid_webhook_signature"
  end

  test "missing signature is rejected before invalid JSON can be parsed", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/whatsapp/#{@phone_number_id}", "{not json")

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "missing_webhook_signature"
  end

  test "body cap applies to webhook path before parser/runtime work" do
    assert {:ok, _setting} =
             Settings.put("public_protocol.max_body_bytes", 1024, %{audit?: false})

    conn =
      Phoenix.ConnTest.build_conn(:post, "/webhooks/whatsapp/#{@phone_number_id}", "{}")
      |> put_req_header("content-length", "1025")
      |> PublicProtocolBodyCap.call([])

    assert conn.halted
    assert conn.status == 413
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "body_too_large"
  end

  test "rate limit bucket is per WhatsApp phone number id", %{conn: conn} do
    set_whatsapp_rate_limit!(%{"limit" => 1, "period_ms" => 60_000, "burst" => 0})
    raw_body = ~s({"object":"whatsapp_business_account","entry":[]})

    first =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature(raw_body))
      |> post(~p"/webhooks/whatsapp/#{@phone_number_id}", raw_body)

    assert first.status == 202

    second =
      recycle(first)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature(raw_body))
      |> post(~p"/webhooks/whatsapp/#{@phone_number_id}", raw_body)

    assert second.status == 429
    assert json_response(second, 429)["error"]["code"] == "rate_limited"
  end

  defp configure_whatsapp_webhook! do
    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.phone_number_id", @phone_number_id, %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.app_secret_ref", @app_secret_ref, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.webhook_verify_token_ref", @verify_token_ref, %{
               audit?: false
             })

    assert {:ok, _secret} =
             Secrets.put_secret(@app_secret_ref, @app_secret, %{actor: "test", channel: :test})

    assert {:ok, _secret} =
             Secrets.put_secret(@verify_token_ref, @verify_token, %{
               actor: "test",
               channel: :test
             })

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.webhook_enabled", true, %{audit?: false})
  end

  defp set_whatsapp_rate_limit!(rate_limit) do
    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.webhook_rate_limit.limit", rate_limit["limit"], %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.webhook_rate_limit.period_ms",
               rate_limit["period_ms"],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.webhook_rate_limit.burst", rate_limit["burst"], %{
               audit?: false
             })
  end

  defp signature(raw_body) do
    digest =
      :crypto.mac(:hmac, :sha256, @app_secret, raw_body)
      |> Base.encode16(case: :lower)

    "sha256=#{digest}"
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
