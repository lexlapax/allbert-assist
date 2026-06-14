defmodule AllbertAssist.Security.V053ChannelPackEvalTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial

  alias AllbertAssist.Channels.Email.Parser, as: EmailParser
  alias AllbertAssist.Channels.Telegram.Renderer, as: TelegramRenderer
  alias AllbertAssist.Confirmations
  alias AllbertAssist.SecurityFixtures.EvalInventory

  @eval_ids [
    "email-content-transfer-encoding-decoded-001",
    "telegram-callback-data-within-64b-001"
  ]

  test "v0.53 eval inventory rows are complete for M5 remediation" do
    rows = EvalInventory.rows_for_milestone(:v053)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == 2
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "email transfer encodings and encoded words decode before runtime text selection" do
    assert_eval!("email-content-transfer-encoding-decoded-001")

    assert {:ok, quoted} =
             EmailParser.parse_email("""
             From: =?UTF-8?Q?Alice_=C3=84?= <Alice@Example.COM>
             To: allbert@example.com
             Subject: =?UTF-8?Q?Pr=C3=BCfung?=
             Message-ID: <v053-encoded@example.com>
             Content-Type: text/plain; charset=utf-8
             Content-Transfer-Encoding: quoted-printable

             Pr=C3=BCfung =E2=9C=93
             """)

    assert quoted.from_address == "alice@example.com"
    assert quoted.subject == "Prüfung"
    assert quoted.text_body == "Prüfung ✓\n"

    assert {:ok, base64} =
             EmailParser.parse_email("""
             From: Alice <alice@example.com>
             To: allbert@example.com
             Subject: Base64
             Message-ID: <v053-base64@example.com>
             Content-Type: multipart/alternative; boundary="v053"

             --v053
             Content-Type: text/plain; charset=utf-8
             Content-Transfer-Encoding: base64

             SGVsbG8gQWxsYmVydAo=
             --v053--
             """)

    assert base64.text_body == "Hello Allbert\n"
  end

  test "Telegram approval callback data stays provider-bounded with fallback commands" do
    assert_eval!("telegram-callback-data-within-64b-001")

    assert {:ok, confirmation} =
             Confirmations.create(%{
               origin: %{actor: "alice", channel: "telegram", surface: "v053-eval"},
               target_action: %{name: "external_network_request"},
               target_permission: :external_network,
               target_execution_mode: :external_network_unavailable,
               security_decision: %{permission: :external_network, decision: :needs_confirmation},
               params_summary: %{url: "https://example.com"}
             })

    handoff = %{confirmation_id: confirmation["id"], status: :pending}

    assert {:ok, [_text], %{"inline_keyboard" => buttons}} =
             TelegramRenderer.render_response(%{approval_handoff: handoff})

    assert Enum.all?(List.flatten(buttons), &(byte_size(&1["callback_data"]) <= 64))

    long_id = "conf_" <> String.duplicate("provider-limit-", 6)

    assert {:ok, [fallback_text], nil} =
             TelegramRenderer.render_response(%{approval_handoff: %{confirmation_id: long_id}})

    assert fallback_text =~ "ALLBERT:APPROVE:#{long_id}"
    assert fallback_text =~ "ALLBERT:DENY:#{long_id}"
    assert fallback_text =~ "ALLBERT:SHOW:#{long_id}"
  end

  defp assert_eval!(id) do
    assert Enum.any?(EvalInventory.rows_for_milestone(:v053), &(&1.id == id))
  end
end
