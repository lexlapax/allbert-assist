defmodule AllbertAssist.Runtime.Attach.TUIProtocolTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Runtime.Attach.TUIProtocol

  @moduletag :pure_async

  @token String.duplicate("t", 43)
  @session_id :binary.copy(<<7>>, 32)
  @receipt_id Base.url_encode64(:binary.copy(<<9>>, 16), padding: false)

  describe "request kind classification" do
    test "keeps an absent or explicit command kind unary and recognizes only TUI sessions" do
      assert {:ok, :command} = TUIProtocol.classify_kind(%{})
      assert {:ok, :command} = TUIProtocol.classify_kind(%{kind: :command})
      assert {:ok, :tui_session} = TUIProtocol.classify_kind(%{kind: :tui_session})
      assert {:error, :unsupported_kind} = TUIProtocol.classify_kind(%{kind: nil})
      assert {:error, :unsupported_kind} = TUIProtocol.classify_kind(%{kind: :other})
    end
  end

  describe "pre-open close construction" do
    test "emits only an allowlisted code and a valid bounded message" do
      assert %{
               kind: :tui_session,
               frame: :close,
               session_protocol: 1,
               code: :already_attached,
               message: "A session is already attached."
             } = TUIProtocol.open_close(:already_attached, "A session is already attached.")

      bounded = TUIProtocol.open_close(:invalid_open, String.duplicate("é", 600))
      assert String.valid?(bounded.message)
      assert byte_size(bounded.message) <= 1_024

      assert %{code: :invalid_open, message: "Invalid TUI session open."} =
               TUIProtocol.open_close(:internal_exception, <<255>>)
    end
  end

  describe "session open validation" do
    test "constructs the exact normalized client open without accepting extra identity fields" do
      identity = Map.put(expected_open_identity(), :ignored, :client_only)

      assert {:ok, open} =
               TUIProtocol.session_open(
                 identity,
                 "  work  ",
                 %{columns: 80, rows: 24, color: :ansi256, unicode?: true}
               )

      assert open == %{
               kind: :tui_session,
               frame: :open,
               session_protocol: 1,
               protocol: 1,
               home: "/tmp/allbert-home",
               uid: "501",
               version: "1.2.1",
               token: @token,
               profile: "work",
               terminal: %{columns: 80, rows: 24, color: :ansi256, unicode?: true}
             }

      assert {:error, :invalid_open} =
               TUIProtocol.session_open(identity, <<255>>, open.terminal)

      assert {:error, :invalid_open} =
               TUIProtocol.session_open(identity, "default", %{open.terminal | columns: 0})
    end

    test "accepts only the exact v1 open shape and normalizes the profile selector" do
      open = valid_open() |> Map.put(:profile, "  work  ")

      assert {:ok, normalized} = TUIProtocol.validate_open(open, expected_open_identity())
      assert normalized.profile == "work"
      assert normalized.terminal == %{columns: 120, rows: 40, color: :truecolor, unicode?: true}

      assert {:ok, %{profile: "default"}} =
               TUIProtocol.validate_open(Map.put(open, :profile, "  "), expected_open_identity())
    end

    test "returns the exact stable code for each identity or protocol mismatch" do
      expected = expected_open_identity()

      for {field, value, code} <- [
            {:session_protocol, 2, :protocol_mismatch},
            {:protocol, 2, :protocol_mismatch},
            {:token, String.duplicate("x", 43), :token_mismatch},
            {:home, "/tmp/other-allbert-home", :home_mismatch},
            {:uid, "502", :uid_mismatch},
            {:version, "1.2.2", :version_mismatch}
          ] do
        assert {:error, ^code} =
                 TUIProtocol.validate_open(Map.put(valid_open(), field, value), expected)
      end

      assert {:error, :token_mismatch} =
               TUIProtocol.validate_open(
                 Map.put(valid_open(), :token, String.duplicate("t", 42)),
                 expected
               )

      assert {:error, :token_mismatch} =
               TUIProtocol.validate_open(
                 Map.put(valid_open(), :token, String.duplicate("t", 44)),
                 expected
               )

      for malformed_size <- [42, 44] do
        malformed_token = String.duplicate("t", malformed_size)

        assert {:error, :token_mismatch} =
                 TUIProtocol.validate_open(
                   Map.put(valid_open(), :token, malformed_token),
                   %{expected | token: malformed_token}
                 )
      end
    end

    test "rejects unknown fields, value types, bounds, and enums as invalid open" do
      invalid_opens = [
        Map.put(valid_open(), :unexpected, true),
        Map.delete(valid_open(), :terminal),
        Map.put(valid_open(), :frame, :input),
        Map.put(valid_open(), :session_protocol, "1"),
        Map.put(valid_open(), :home, "relative/home"),
        Map.put(valid_open(), :uid, ""),
        Map.put(valid_open(), :version, String.duplicate("v", 65)),
        Map.put(valid_open(), :profile, String.duplicate("p", 129)),
        put_in(valid_open(), [:terminal, :columns], 0),
        put_in(valid_open(), [:terminal, :rows], 201),
        put_in(valid_open(), [:terminal, :color], :millions),
        put_in(valid_open(), [:terminal, :unicode?], :yes),
        put_in(valid_open(), [:terminal, :extra], true)
      ]

      for open <- invalid_opens do
        assert {:error, :invalid_open} =
                 TUIProtocol.validate_open(open, expected_open_identity())
      end

      assert {:error, :unsupported_kind} =
               TUIProtocol.validate_open(
                 Map.put(valid_open(), :kind, :unknown),
                 expected_open_identity()
               )
    end

    test "safe-decodes only bounded uncompressed session opens" do
      encoded = :erlang.term_to_binary(valid_open())
      assert {:ok, %{frame: :open}} = TUIProtocol.decode_open(encoded, expected_open_identity())

      compressed = :erlang.term_to_binary(valid_open(), compressed: 9)
      assert TUIProtocol.compressed_term?(compressed)

      assert {:error, :invalid_open} =
               TUIProtocol.decode_open(compressed, expected_open_identity())

      refute TUIProtocol.compressed_term?(encoded)

      assert {:error, :invalid_open} =
               TUIProtocol.decode_open(<<131, 255>>, expected_open_identity())

      assert {:error, :invalid_open} =
               TUIProtocol.decode_open(:binary.copy(<<0>>, 16_385), expected_open_identity())
    end
  end

  describe "client initial response decoding" do
    test "accepts only the first daemon snapshot and returns its initialized client flow" do
      snapshot =
        frame(:snapshot, %{
          render_revision: 0,
          state: :idle,
          lines: ["ready"],
          gap?: false
        })

      assert {:ok, ^snapshot, flow} =
               snapshot
               |> :erlang.term_to_binary()
               |> TUIProtocol.decode_initial_response()

      assert flow.session_id == @session_id
      assert flow.outbound_direction == :client_to_daemon
      assert flow.bootstrapped?
      assert flow.last_received_seq == 1
      assert flow.ack_to_send == 1
      assert flow.last_peer_ack == 0
      assert flow.next_send_seq == 1
      assert flow.ack_due?
    end

    test "returns a stable rejection only for the exact pre-open close shape" do
      rejection = TUIProtocol.open_close(:already_attached, "A session is already attached.")

      assert {:error, {:open_rejected, :already_attached, "A session is already attached."}} =
               rejection
               |> :erlang.term_to_binary()
               |> TUIProtocol.decode_initial_response()

      for malformed <- [
            Map.put(rejection, :extra, true),
            Map.put(rejection, :code, :normal),
            Map.put(rejection, :session_protocol, 2),
            Map.put(rejection, :message, <<255>>),
            frame(:close, %{code: :normal, message: "closed"})
          ] do
        assert {:error, :protocol_error} =
                 malformed
                 |> :erlang.term_to_binary()
                 |> TUIProtocol.decode_initial_response()
      end
    end

    test "rejects compressed, oversized, malformed, and non-bootstrap initial frames" do
      snapshot =
        frame(:snapshot, %{
          render_revision: 0,
          state: :idle,
          lines: List.duplicate(String.duplicate("x", 128), 100),
          gap?: false
        })

      compressed = :erlang.term_to_binary(snapshot, compressed: 9)
      assert <<131, 80, _rest::binary>> = compressed
      assert {:error, :protocol_error} = TUIProtocol.decode_initial_response(compressed)

      assert {:error, :frame_too_large} =
               TUIProtocol.decode_initial_response(:binary.copy(<<0>>, 64 * 1_024 + 1))

      assert {:error, :protocol_error} = TUIProtocol.decode_initial_response(<<131, 255>>)

      for invalid <- [
            %{snapshot | seq: 2},
            %{snapshot | ack: 1},
            frame(:delta, %{render_revision: 1, mode: :append, lines: []}),
            Map.put(snapshot, :unexpected, true)
          ] do
        assert {:error, _reason} =
                 invalid
                 |> :erlang.term_to_binary()
                 |> TUIProtocol.decode_initial_response()
      end
    end
  end

  describe "post-open frame validation" do
    test "accepts every exact client-to-daemon v1 frame payload" do
      frames = [
        frame(:input, %{input_receipt_id: @receipt_id, text: "hello"}),
        frame(:resize, %{columns: 1, rows: 200}),
        frame(:cancel, %{reason: :operator_escape}),
        frame(:cancel, %{reason: :operator_interrupt}),
        frame(:confirmation, %{confirmation_id: "confirm-1", decision: :approve}),
        frame(:confirmation, %{confirmation_id: "confirm-1", decision: :deny}),
        frame(:ack, %{}),
        frame(:detach, %{reason: :operator_exit}),
        frame(:detach, %{reason: :eof})
      ]

      for candidate <- frames do
        assert :ok = TUIProtocol.validate_frame(:client_to_daemon, candidate)
      end
    end

    test "accepts every exact daemon-to-client v1 frame payload" do
      frames = [
        frame(:snapshot, %{
          render_revision: 0,
          state: :idle,
          lines: ["ready"],
          gap?: false
        }),
        frame(:delta, %{
          render_revision: 1,
          mode: :append,
          lines: ["next"]
        }),
        frame(:status, %{
          render_revision: 1,
          state: :thinking,
          text: "working",
          input_receipt_id: @receipt_id
        }),
        frame(:confirmation, %{
          confirmation_id: "confirm-1",
          prompt: "Proceed?",
          expires_at_unix_ms: 0
        }),
        frame(:completion, %{
          input_receipt_id: @receipt_id,
          outcome: :completed,
          duplicate?: false,
          result_ref: "message:1",
          lines: ["done"]
        }),
        frame(:error, %{
          code: :runtime_error,
          message: "Runtime failed.",
          input_receipt_id: nil
        }),
        frame(:close, %{code: :normal, message: "Goodbye."})
      ]

      for candidate <- frames do
        assert :ok = TUIProtocol.validate_frame(:daemon_to_client, candidate)
      end
    end

    test "rejects direction, envelope, payload, text, line, and enum drift" do
      too_many_lines = List.duplicate("x", 257)
      too_many_line_bytes = List.duplicate(String.duplicate("x", 8 * 1_024), 7)

      invalid = [
        {:daemon_to_client, frame(:input, %{input_receipt_id: @receipt_id, text: "x"}), []},
        {:client_to_daemon, frame(:unknown, %{}), []},
        {:client_to_daemon, Map.put(frame(:ack, %{}), :extra, true), []},
        {:client_to_daemon, Map.put(frame(:ack, %{}), :session_id, <<1>>), []},
        {:client_to_daemon, Map.put(frame(:ack, %{}), :session_protocol, 2), []},
        {:client_to_daemon, frame(:input, %{input_receipt_id: "not-a-receipt", text: "x"}), []},
        {:client_to_daemon,
         frame(:input, %{
           input_receipt_id: String.slice(@receipt_id, 0, 21) <> "R",
           text: "x"
         }), []},
        {:client_to_daemon, frame(:input, %{input_receipt_id: @receipt_id, text: "xx"}),
         [max_text_bytes: 1]},
        {:client_to_daemon, frame(:resize, %{columns: 501, rows: 1}), []},
        {:client_to_daemon, frame(:cancel, %{reason: :daemon_shutdown}), []},
        {:client_to_daemon, frame(:confirmation, %{confirmation_id: "", decision: :approve}), []},
        {:client_to_daemon, frame(:ack, %{unexpected: true}), []},
        {:client_to_daemon, frame(:detach, %{reason: :socket_loss}), []},
        {:daemon_to_client,
         frame(:snapshot, %{render_revision: -1, state: :idle, lines: [], gap?: false}), []},
        {:daemon_to_client,
         frame(:delta, %{render_revision: 1, mode: :clear_live, lines: ["not empty"]}), []},
        {:daemon_to_client,
         frame(:status, %{
           render_revision: 0,
           state: :unknown,
           text: "",
           input_receipt_id: nil
         }), []},
        {:daemon_to_client,
         frame(:confirmation, %{
           confirmation_id: "c",
           prompt: <<255>>,
           expires_at_unix_ms: 0
         }), []},
        {:daemon_to_client,
         frame(:completion, %{
           input_receipt_id: @receipt_id,
           outcome: :maybe,
           duplicate?: false,
           result_ref: nil,
           lines: []
         }), []},
        {:daemon_to_client,
         frame(:error, %{code: :exception, message: "x", input_receipt_id: nil}), []},
        {:daemon_to_client, frame(:close, %{code: :panic, message: "x"}), []},
        {:daemon_to_client,
         frame(:snapshot, %{
           render_revision: 0,
           state: :idle,
           lines: too_many_lines,
           gap?: false
         }), []},
        {:daemon_to_client,
         frame(:snapshot, %{
           render_revision: 0,
           state: :idle,
           lines: too_many_line_bytes,
           gap?: false
         }), []}
      ]

      for {direction, candidate, opts} <- invalid do
        assert {:error, :protocol_error} =
                 TUIProtocol.validate_frame(direction, candidate, opts)
      end
    end

    test "decodes only uncompressed structurally bounded bodies up to 64 KiB" do
      candidate = frame(:ack, %{})

      assert {:ok, ^candidate} =
               TUIProtocol.decode_frame(:erlang.term_to_binary(candidate), :client_to_daemon)

      assert {:error, :frame_too_large} =
               TUIProtocol.decode_frame(:binary.copy(<<0>>, 64 * 1_024 + 1), :client_to_daemon)

      assert {:error, :protocol_error} =
               TUIProtocol.decode_frame(
                 :erlang.term_to_binary(candidate, compressed: 9),
                 :client_to_daemon
               )

      malformed_terms = [
        {:tuple, :is_not_a_session_schema},
        1.5,
        Enum.into(1..33, %{}, &{&1, &1}),
        List.duplicate(:item, 257),
        Enum.reduce(1..9, :leaf, fn _index, acc -> [acc] end)
      ]

      for malformed <- malformed_terms do
        assert {:error, :protocol_error} =
                 TUIProtocol.decode_frame(
                   :erlang.term_to_binary(malformed),
                   :client_to_daemon
                 )
      end

      assert {:error, :protocol_error} =
               TUIProtocol.decode_frame(<<131, 255>>, :client_to_daemon)
    end
  end

  describe "adjacent presentation delta reduction" do
    test "applies every frozen same-revision reduction rule" do
      append = delta(:append, ["one"])
      replace = delta(:replace_live, ["replacement"])
      clear = delta(:clear_live, [])

      assert {:ok, %{mode: :append, lines: ["one", "two"]}} =
               TUIProtocol.reduce_adjacent_deltas(append, delta(:append, ["two"]))

      assert {:ok, ^replace} = TUIProtocol.reduce_adjacent_deltas(append, replace)
      assert {:ok, ^clear} = TUIProtocol.reduce_adjacent_deltas(append, clear)

      assert {:ok, %{mode: :replace_live, lines: ["replacement", "tail"]}} =
               TUIProtocol.reduce_adjacent_deltas(replace, delta(:append, ["tail"]))

      assert {:ok, %{mode: :replace_live, lines: ["after clear"]}} =
               TUIProtocol.reduce_adjacent_deltas(clear, delta(:append, ["after clear"]))
    end

    test "retains separate frames when revisions differ or reduction exceeds bounds" do
      assert :no_reduction =
               TUIProtocol.reduce_adjacent_deltas(
                 delta(:append, ["one"], 1),
                 delta(:append, ["two"], 2)
               )

      full = List.duplicate("x", 256)

      assert :no_reduction =
               TUIProtocol.reduce_adjacent_deltas(
                 delta(:append, full),
                 delta(:append, ["overflow"])
               )
    end
  end

  describe "frozen limits and bounded terminal payloads" do
    test "publishes pressure limits and constructs only allowlisted close/error payloads" do
      assert %{
               open_body_bytes: 16_384,
               frame_body_bytes: 65_536,
               container_depth: 8,
               map_keys: 32,
               list_items: 256,
               daemon_inbound: %{frames: 32, bytes: 262_144},
               daemon_outbound_unsent: %{frames: 64, bytes: 262_144},
               daemon_unacknowledged: %{frames: 32, bytes: 262_144},
               client_outbound_unsent: %{frames: 32, bytes: 262_144},
               client_unacknowledged: %{frames: 32, bytes: 262_144}
             } = TUIProtocol.limits()

      assert TUIProtocol.pressure_drop_order() == [:status, :delta]

      input_payload = %{
        input_receipt_id: @receipt_id,
        text: String.duplicate("x", 32_000)
      }

      assert {:ok, upper_bound} =
               TUIProtocol.encoded_frame_upper_bound(
                 :client_to_daemon,
                 :input,
                 input_payload,
                 max_text_bytes: 32_000
               )

      actual = %{
        kind: :tui_session,
        session_protocol: TUIProtocol.session_protocol(),
        frame: :input,
        session_id: :binary.copy(<<1>>, 32),
        seq: 1,
        ack: 1,
        payload: input_payload
      }

      assert byte_size(:erlang.term_to_binary(actual)) <= upper_bound

      assert {:error, :protocol_error} =
               TUIProtocol.encoded_frame_upper_bound(
                 :client_to_daemon,
                 :input,
                 %{input_receipt_id: "invalid", text: "input"},
                 max_text_bytes: 32_000
               )

      close = TUIProtocol.close_payload(:daemon_shutdown, String.duplicate("é", 600))
      assert close.code == :daemon_shutdown
      assert String.valid?(close.message)
      assert byte_size(close.message) <= 1_024

      error = TUIProtocol.error_payload(:receipt_conflict, "Receipt conflict.", @receipt_id)

      assert error == %{
               code: :receipt_conflict,
               message: "Receipt conflict.",
               input_receipt_id: @receipt_id
             }

      assert %{code: :protocol_error, message: "Protocol error."} =
               TUIProtocol.close_payload(:exception_name, <<255>>)

      assert %{code: :runtime_error, message: "Runtime error.", input_receipt_id: nil} =
               TUIProtocol.error_payload(:exception_name, <<255>>, "bad")
    end
  end

  describe "session/receipt identity and receipt input normalization" do
    test "generates canonical identifiers and freezes tui-input-v1 normalization" do
      session_id = TUIProtocol.new_session_id()
      assert is_binary(session_id) and byte_size(session_id) == 32
      refute session_id == TUIProtocol.new_session_id()

      receipt_id = TUIProtocol.new_receipt_id()
      assert byte_size(receipt_id) == 22

      assert {:ok, decoded} = Base.url_decode64(receipt_id, padding: false)
      assert byte_size(decoded) == 16
      assert Base.url_encode64(decoded, padding: false) == receipt_id

      assert {:ok, "hello\nworld\nlast"} =
               TUIProtocol.normalize_input("\u00A0hello\r\nworld\rlast\u2003", 32_000)

      assert {:ok, "a  b"} = TUIProtocol.normalize_input("  a  b  ", 32_000)
      assert {:error, :invalid_input} = TUIProtocol.normalize_input(" \r\n ", 32_000)
      assert {:error, :invalid_input} = TUIProtocol.normalize_input(<<255>>, 32_000)
      assert {:error, :invalid_input} = TUIProtocol.normalize_input("too long", 3)
      assert {:error, :invalid_input} = TUIProtocol.normalize_input("a\r\nb", 3)
      assert {:error, :invalid_input} = TUIProtocol.normalize_input("valid", 32_001)
    end
  end

  describe "direction-independent sequence and cumulative acknowledgement flow" do
    test "orders each direction, advances custody ack, and releases retained sends cumulatively" do
      assert {:ok, flow0} = TUIProtocol.new_flow(@session_id)

      snapshot = %{
        render_revision: 0,
        state: :idle,
        lines: ["ready"],
        gap?: false
      }

      assert {:ok, first_snapshot, flow1} =
               TUIProtocol.send_frame(
                 flow0,
                 :daemon_to_client,
                 :snapshot,
                 snapshot
               )

      assert %{seq: 1, ack: 0, session_id: @session_id} = first_snapshot

      assert flow1.retained_unacknowledged == %{
               1 => byte_size(:erlang.term_to_binary(first_snapshot))
             }

      input = frame(:input, %{input_receipt_id: @receipt_id, text: "hello"}, 1, 1)
      assert {:ok, flow2} = TUIProtocol.accept_frame(flow1, :client_to_daemon, input)
      assert flow2.last_received_seq == 1
      assert flow2.ack_to_send == 1
      assert flow2.last_peer_ack == 1
      assert flow2.retained_unacknowledged == %{}
      assert flow2.ack_due?

      status = %{
        render_revision: 1,
        state: :thinking,
        text: "working",
        input_receipt_id: @receipt_id
      }

      assert {:ok, status_frame, flow3} =
               TUIProtocol.send_frame(flow2, :daemon_to_client, :status, status)

      assert %{seq: 2, ack: 1, frame: :status} = status_frame
      assert Map.has_key?(flow3.retained_unacknowledged, 2)
      refute flow3.ack_due?

      peer_ack = frame(:ack, %{}, 2, 2)
      assert {:ok, flow4} = TUIProtocol.accept_frame(flow3, :client_to_daemon, peer_ack)
      refute flow4.ack_due?
      assert flow4.ack_to_send == 2
      assert flow4.retained_unacknowledged == %{}

      assert {:ok, client0} = TUIProtocol.new_flow(@session_id)

      assert {:ok, client1} =
               TUIProtocol.accept_frame(client0, :daemon_to_client, first_snapshot)

      assert {:ok, client_ack, client2} =
               TUIProtocol.send_frame(client1, :client_to_daemon, :ack, %{})

      assert %{seq: 1, ack: 1, frame: :ack} = client_ack
      assert client2.retained_unacknowledged == %{}
    end

    test "keeps schema, sequence, then acknowledgement error precedence and reserves terminal max" do
      {:ok, flow0} = TUIProtocol.new_flow(@session_id)
      input_payload = %{input_receipt_id: @receipt_id, text: "hello"}

      assert {:error, :protocol_error} =
               TUIProtocol.send_frame(flow0, :client_to_daemon, :input, input_payload)

      snapshot = %{render_revision: 0, state: :idle, lines: [], gap?: false}

      {:ok, snapshot_frame, server1} =
        TUIProtocol.send_frame(flow0, :daemon_to_client, :snapshot, snapshot)

      assert {:error, :protocol_error} =
               TUIProtocol.send_frame(server1, :client_to_daemon, :ack, %{})

      malformed_gap = frame(:input, %{input_receipt_id: @receipt_id}, 2, 1)

      assert {:error, :protocol_error} =
               TUIProtocol.accept_frame(server1, :client_to_daemon, malformed_gap)

      assert {:error, :sequence_error} =
               TUIProtocol.accept_frame(
                 server1,
                 :client_to_daemon,
                 frame(:input, input_payload, 2, 1)
               )

      assert {:error, :ack_error} =
               TUIProtocol.accept_frame(
                 server1,
                 :client_to_daemon,
                 frame(:input, input_payload, 1, 2)
               )

      {:ok, server2} =
        TUIProtocol.accept_frame(
          server1,
          :client_to_daemon,
          frame(:input, input_payload, 1, 1)
        )

      assert {:error, :sequence_error} =
               TUIProtocol.accept_frame(
                 server2,
                 :client_to_daemon,
                 frame(:input, input_payload, 1, 0)
               )

      max = TUIProtocol.limits().max_sequence

      near_exhaustion = %{
        server2
        | next_send_seq: max,
          highest_sent_seq: max - 1,
          last_peer_ack: max - 1,
          retained_unacknowledged: %{},
          retained_unacknowledged_bytes: 0
      }

      assert {:error, :protocol_error} =
               TUIProtocol.send_frame(
                 near_exhaustion,
                 :daemon_to_client,
                 :status,
                 %{render_revision: 1}
               )

      assert {:error, :sequence_error} =
               TUIProtocol.send_frame(
                 near_exhaustion,
                 :daemon_to_client,
                 :status,
                 %{render_revision: 1, state: :idle, text: "", input_receipt_id: nil}
               )

      assert {:ok, %{seq: ^max, frame: :close}, exhausted} =
               TUIProtocol.send_frame(
                 near_exhaustion,
                 :daemon_to_client,
                 :close,
                 TUIProtocol.close_payload(:sequence_error, "Sequence exhausted.")
               )

      assert exhausted.send_exhausted?

      assert {:error, :sequence_error} =
               TUIProtocol.send_frame(
                 exhausted,
                 :daemon_to_client,
                 :close,
                 TUIProtocol.close_payload(:sequence_error, "Sequence exhausted.")
               )

      server_near_receive_exhaustion = %{
        server1
        | last_received_seq: max - 1,
          ack_to_send: max - 1
      }

      assert {:error, :sequence_error} =
               TUIProtocol.accept_frame(
                 server_near_receive_exhaustion,
                 :client_to_daemon,
                 frame(:input, input_payload, max, 1)
               )

      {:ok, client0} = TUIProtocol.new_flow(@session_id)
      {:ok, client1} = TUIProtocol.accept_frame(client0, :daemon_to_client, snapshot_frame)

      client_near_receive_exhaustion = %{
        client1
        | last_received_seq: max - 1,
          ack_to_send: max - 1
      }

      terminal_close =
        frame(
          :close,
          TUIProtocol.close_payload(:sequence_error, "Sequence exhausted."),
          max,
          0
        )

      assert {:ok, client_exhausted} =
               TUIProtocol.accept_frame(
                 client_near_receive_exhaustion,
                 :daemon_to_client,
                 terminal_close
               )

      assert client_exhausted.receive_exhausted?
    end
  end

  defp valid_open do
    %{
      kind: :tui_session,
      frame: :open,
      session_protocol: 1,
      protocol: 1,
      home: "/tmp/allbert-home",
      uid: "501",
      version: "1.2.1",
      token: @token,
      profile: "default",
      terminal: %{columns: 120, rows: 40, color: :truecolor, unicode?: true}
    }
  end

  defp expected_open_identity do
    %{
      protocol: 1,
      home: "/tmp/allbert-home",
      uid: "501",
      version: "1.2.1",
      token: @token
    }
  end

  defp delta(mode, lines, revision \\ 1) do
    %{render_revision: revision, mode: mode, lines: lines}
  end

  defp frame(frame, payload, seq \\ 1, ack \\ 0) do
    %{
      kind: :tui_session,
      session_protocol: 1,
      frame: frame,
      session_id: @session_id,
      seq: seq,
      ack: ack,
      payload: payload
    }
  end
end
