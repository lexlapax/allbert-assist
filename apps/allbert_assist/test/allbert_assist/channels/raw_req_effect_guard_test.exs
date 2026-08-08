defmodule AllbertAssist.Channels.RawReqEffectGuardTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.Channels.{Discord, Matrix, Signal, Slack, Telegram, WhatsApp}
  alias AllbertAssist.TestSupport.ReadyEffectContext

  setup {Req.Test, :verify_on_exit!}

  test "missing and stale E1 carriers never invoke any channel Req plug" do
    test_pid = self()
    context = ReadyEffectContext.context()
    barrier = ReadyEffectContext.server(context)

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :transport_called)
      Req.Test.json(conn, %{"ok" => true, "result" => []})
    end)

    invoke_all([], :product_not_ready)
    refute_received :transport_called

    :ok = ReadyEffectContext.replace(barrier)
    invoke_all(context_to_opts(context), :stale_epoch)
    refute_received :transport_called
  end

  test "a ready E1 reaches Telegram through propagated request options" do
    context = ReadyEffectContext.context()

    Req.Test.expect(__MODULE__, fn %{request_path: "/bottoken/getUpdates"} = conn ->
      Req.Test.json(conn, %{"ok" => true, "result" => []})
    end)

    assert {:ok, []} =
             Telegram.Client.get_updates(
               "token",
               0,
               1,
               context_to_opts(context)
             )
  end

  defp invoke_all(opts, expected_reason) do
    assert {:error, ^expected_reason} =
             Signal.Client.send_message(
               "+15551234567",
               "+15550001111",
               "blocked",
               Keyword.merge(
                 [
                   mode: :loopback_http,
                   base_url: "http://127.0.0.1:8080",
                   plug: {Req.Test, __MODULE__}
                 ],
                 opts
               )
             )

    assert {:error, ^expected_reason} =
             Slack.Client.auth_test(
               "secret://channels/slack/missing",
               Keyword.merge([mode: :real, plug: {Req.Test, __MODULE__}], opts)
             )

    assert {:error, ^expected_reason} =
             Matrix.Client.sync(
               "https://matrix.example.com",
               "matrix-token",
               nil,
               1,
               Keyword.merge([plug: {Req.Test, __MODULE__}], opts)
             )

    assert {:error, ^expected_reason} =
             Discord.Client.users_me(
               "secret://channels/discord/missing",
               Keyword.merge([mode: :real, plug: {Req.Test, __MODULE__}], opts)
             )

    assert {:error, ^expected_reason} =
             WhatsApp.Client.phone_number(
               "whatsapp-token",
               "15551234567",
               Keyword.merge([mode: :real, plug: {Req.Test, __MODULE__}], opts)
             )

    assert {:error, ^expected_reason} =
             Telegram.Client.get_updates(
               "token",
               0,
               1,
               Keyword.merge([plug: {Req.Test, __MODULE__}], opts)
             )
  end

  defp context_to_opts(context) do
    [
      allbert_pack_epoch: context.allbert_pack_epoch,
      plug: {Req.Test, __MODULE__}
    ]
  end
end
