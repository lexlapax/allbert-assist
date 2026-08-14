defmodule AllbertAssist.Runtime.TUISessionTest do
  use AllbertAssist.DataCase, async: false, lane: :global_process_serial

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias __MODULE__.ReadyInputReceipt, as: InputReceipt
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Health
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach
  alias AllbertAssist.Runtime.Attach.Server, as: AttachServer
  alias AllbertAssist.Runtime.Attach.TUIProtocol
  alias AllbertAssist.Runtime.Attach.TUISession
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias AllbertTUI.Adapter

  defmodule ReadyInputReceipt do
    @moduledoc false

    alias AllbertAssist.TestSupport.ReadyEffectContext
    alias AllbertTUI.InputReceipt

    def gate(attrs, opts),
      do: InputReceipt.gate(ReadyEffectContext.attach(attrs), opts)

    def mark_admitted(event, refs),
      do: InputReceipt.mark_admitted(event, refs, ReadyEffectContext.context())

    def mark_in_progress(event),
      do: InputReceipt.mark_in_progress(event, ReadyEffectContext.context())

    def mark_terminal(event, outcome, refs),
      do: InputReceipt.mark_terminal(event, outcome, refs, ReadyEffectContext.context())
  end

  defmodule ControllableAdapter do
    @moduledoc false

    use GenServer

    @config_key :tui_session_test_adapter

    def child_spec(opts) do
      %{
        id: Keyword.fetch!(opts, :id),
        start: {__MODULE__, :start_link, [opts]},
        restart: Keyword.get(opts, :restart, :temporary),
        type: :worker
      }
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def output(adapter, line) do
      adapter
      |> GenServer.call(:output_fun)
      |> then(& &1.(line))
    end

    def delivery_output(adapter, line) do
      adapter
      |> GenServer.call(:delivery_output_fun)
      |> then(& &1.(line))
    end

    def submit_admitted(adapter, _text, _event, receipt_id) do
      config = GenServer.call(adapter, :test_config)
      send(config.controller, {:test_submit_started, self(), receipt_id})

      if config.block_submit? do
        receive do
          {:release_test_submit, ^receipt_id} -> {:ok, {:accepted, receipt_id}}
        end
      else
        {:ok, {:accepted, receipt_id}}
      end
    end

    def cancel_current_turn(adapter, reason) do
      config = GenServer.call(adapter, :test_config)
      send(config.controller, {:test_cancel_started, self(), reason})

      if config.block_cancel? do
        receive do
          {:release_test_cancel, ^reason} -> {:ok, :cancelled}
        end
      else
        {:ok, :cancelled}
      end
    end

    def confirm(_adapter, _confirmation_id, _decision), do: {:ok, :confirmed}

    @impl true
    def init(opts) do
      config = Application.fetch_env!(:allbert_assist, @config_key)

      {:ok,
       %{
         config: config,
         delivery_output_fun: Keyword.fetch!(opts, :delivery_output_fun),
         output_fun: Keyword.fetch!(opts, :output_fun)
       }}
    end

    @impl true
    def handle_call(:test_config, _from, state), do: {:reply, state.config, state}
    def handle_call(:output_fun, _from, state), do: {:reply, state.output_fun, state}

    def handle_call(:delivery_output_fun, _from, state),
      do: {:reply, state.delivery_output_fun, state}

    def handle_call({:cancel_current_turn, reason}, _from, state) do
      send(state.config.controller, {:test_teardown_cancel, self(), reason})
      {:reply, :ok, state}
    end
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-session-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    KeyCustody.invalidate(:all)

    on_exit(fn ->
      KeyCustody.invalidate(:all)

      if original_paths_config,
        do: Application.put_env(:allbert_assist, Paths, original_paths_config),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(home)
    end)

    :ok
  end

  describe "durable input receipts" do
    test "new input is normalized and durably gated without storing its text" do
      receipt_id = TUIProtocol.new_receipt_id()

      assert {:ok,
              %{
                disposition: :dispatch,
                event: %Event{} = event,
                normalized_text: "hello\nworld"
              }} =
               InputReceipt.gate(
                 %{
                   verified_operator_id: "local",
                   profile: "  work  ",
                   input_receipt_id: receipt_id,
                   text: "  hello\r\nworld  ",
                   max_text_bytes: 32_000
                 },
                 duplicate_owner: :orphaned
               )

      assert event.channel == "tui"
      assert event.provider == "terminal"
      assert event.direction == "inbound"
      assert event.external_user_id == "work"
      assert event.external_chat_id == "tui:work"
      assert event.external_message_id == receipt_id
      assert event.user_id == "local"
      assert event.status == "received"
      assert event.receipt_normalizer_version == "tui-input-v1"
      assert event.receipt_hmac_key_ref == "secret://system/integrity_v1"
      assert event.receipt_hmac_key_version == 1
      assert event.receipt_state == "received"
      assert byte_size(event.receipt_payload_hmac) == 43
      assert String.starts_with?(event.external_event_id, "tui:r1:")
      refute event.external_event_id =~ receipt_id
      refute inspect(event) =~ "hello"
    end

    test "channel-event redaction preserves only the closed integrity reference" do
      assert {:error, changeset} =
               Channels.create_event(
                 %{
                   channel: "tui",
                   provider: "terminal",
                   direction: "inbound",
                   external_event_id: "unsafe-receipt-ref",
                   status: "received",
                   receipt_hmac_key_ref: "secret://providers/openai/api_key"
                 },
                 ReadyEffectContext.context()
               )

      assert "is invalid" in errors_on(changeset).receipt_hmac_key_ref
      refute Repo.get_by(Event, external_event_id: "unsafe-receipt-ref")
    end

    test "same normalized receipt is observed once and changed payload fails closed" do
      receipt_id = TUIProtocol.new_receipt_id()

      attrs = %{
        verified_operator_id: "local",
        profile: "work",
        input_receipt_id: receipt_id,
        text: "  same\r\npayload  ",
        max_text_bytes: 32_000
      }

      assert {:ok, %{disposition: :dispatch, event: first}} =
               InputReceipt.gate(attrs, duplicate_owner: :live)

      assert {:ok,
              %{
                disposition: :duplicate,
                event: duplicate,
                state: :received,
                outcome: nil,
                message_id: nil,
                result_ref: nil
              } = duplicate_result} =
               InputReceipt.gate(
                 %{attrs | text: "same\npayload"},
                 duplicate_owner: :live
               )

      assert duplicate.id == first.id
      refute Map.has_key?(duplicate_result, :normalized_text)

      assert {:error, :receipt_conflict} =
               InputReceipt.gate(
                 %{attrs | text: "different payload"},
                 duplicate_owner: :live
               )

      AssertBinding.check!("v121-tui-input-receipt-001", [
        :receipt_persisted_before_dispatch,
        :same_payload_idempotent,
        :changed_payload_rejected
      ])
    end

    test "receipt namespace is isolated by verified operator and normalized profile" do
      receipt_id = TUIProtocol.new_receipt_id()

      base = %{
        verified_operator_id: "operator-a",
        profile: "work",
        input_receipt_id: receipt_id,
        text: "same payload",
        max_text_bytes: 32_000
      }

      assert {:ok, %{disposition: :dispatch, event: first}} =
               InputReceipt.gate(base, duplicate_owner: :live)

      assert {:ok, %{disposition: :dispatch, event: second}} =
               InputReceipt.gate(
                 %{base | verified_operator_id: "operator-b"},
                 duplicate_owner: :live
               )

      assert {:ok, %{disposition: :dispatch, event: third}} =
               InputReceipt.gate(
                 %{base | profile: "personal"},
                 duplicate_owner: :live
               )

      assert MapSet.size(
               MapSet.new([
                 first.external_event_id,
                 second.external_event_id,
                 third.external_event_id
               ])
             ) ==
               3

      refute Enum.any?([first, second, third], &(&1.external_event_id =~ receipt_id))
    end

    test "concurrent first use yields one dispatch disposition" do
      attrs = %{
        verified_operator_id: "local",
        profile: "work",
        input_receipt_id: TUIProtocol.new_receipt_id(),
        text: "one admission",
        max_text_bytes: 32_000
      }

      results =
        1..4
        |> Task.async_stream(
          fn _ -> InputReceipt.gate(attrs, duplicate_owner: :live) end,
          max_concurrency: 4,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, {:ok, result}} -> result end)

      assert Enum.count(results, &(&1.disposition == :dispatch)) == 1
      assert Enum.count(results, &(&1.disposition == :duplicate)) == 3
      assert results |> Enum.map(& &1.event.id) |> Enum.uniq() |> length() == 1
    end

    test "receipt lifecycle stores only bounded dispatch and terminal references" do
      receipt_id = TUIProtocol.new_receipt_id()

      assert {:ok, %{event: event}} =
               InputReceipt.gate(
                 %{
                   verified_operator_id: "local",
                   profile: "work",
                   input_receipt_id: receipt_id,
                   text: "run this",
                   max_text_bytes: 32_000
                 },
                 duplicate_owner: :live
               )

      assert {:ok, admitted} =
               InputReceipt.mark_admitted(event, %{
                 input_signal_id: "signal-1",
                 thread_id: "thread-1",
                 trace_id: "trace-1"
               })

      assert admitted.receipt_state == "admitted"
      assert admitted.input_signal_id == "signal-1"
      assert admitted.thread_id == "thread-1"
      assert admitted.trace_id == "trace-1"

      assert {:ok, in_progress} = InputReceipt.mark_in_progress(admitted)
      assert in_progress.receipt_state == "in_progress"

      assert {:ok, completed} =
               InputReceipt.mark_terminal(in_progress, :completed, %{
                 receipt_message_id: "message-1",
                 receipt_result_ref: "result://conversation/message-1"
               })

      assert completed.receipt_state == "completed"
      assert completed.receipt_outcome == "completed"
      assert completed.receipt_message_id == "message-1"
      assert completed.receipt_result_ref == "result://conversation/message-1"
      assert completed.status == "processed"
    end

    test "admission fails closed instead of rebinding a durable ref" do
      assert {:ok, %{event: event}} =
               InputReceipt.gate(
                 %{
                   verified_operator_id: "local",
                   profile: "work",
                   input_receipt_id: TUIProtocol.new_receipt_id(),
                   text: "keep admission ref",
                   max_text_bytes: 32_000
                 },
                 duplicate_owner: :live
               )

      assert {:ok, durable} =
               Channels.update_event(
                 event,
                 %{thread_id: "durable-thread"},
                 ReadyEffectContext.context()
               )

      assert {:error, :invalid_receipt_transition} =
               InputReceipt.mark_admitted(event, %{thread_id: "different-thread"})

      persisted = Repo.get!(Event, durable.id)
      assert persisted.status == "received"
      assert persisted.receipt_state == "received"
      assert persisted.thread_id == "durable-thread"
    end

    test "terminalization follows the reloaded durable status and preserves exact refs" do
      cases = [
        {"processed", :failed, :completed},
        {"rejected", :completed, :rejected},
        {"failed", :completed, :failed}
      ]

      Enum.each(cases, fn {status, requested_outcome, expected_outcome} ->
        receipt_id = TUIProtocol.new_receipt_id()
        thread_id = "thread-#{status}"
        result_ref = "result-#{status}"

        assert {:ok, %{event: event}} =
                 InputReceipt.gate(
                   %{
                     verified_operator_id: "local",
                     profile: "work",
                     input_receipt_id: receipt_id,
                     text: "terminal #{status}",
                     max_text_bytes: 32_000
                   },
                   duplicate_owner: :live
                 )

        assert {:ok, admitted} = InputReceipt.mark_admitted(event, %{})

        assert {:ok, _durable_terminal} =
                 Channels.update_event(
                   admitted,
                   %{
                     status: status,
                     thread_id: thread_id,
                     receipt_result_ref: result_ref
                   },
                   ReadyEffectContext.context()
                 )

        assert {:ok, terminal} =
                 InputReceipt.mark_terminal(admitted, requested_outcome, %{
                   thread_id: thread_id,
                   receipt_message_id: "message-#{status}",
                   receipt_result_ref: result_ref
                 })

        expected = Atom.to_string(expected_outcome)
        assert terminal.status == status
        assert terminal.receipt_state == expected
        assert terminal.receipt_outcome == expected
        assert terminal.thread_id == thread_id
        assert terminal.receipt_message_id == "message-#{status}"
        assert terminal.receipt_result_ref == result_ref
      end)
    end

    test "terminalization fails closed instead of rebinding a durable ref" do
      assert {:ok, %{event: event}} =
               InputReceipt.gate(
                 %{
                   verified_operator_id: "local",
                   profile: "work",
                   input_receipt_id: TUIProtocol.new_receipt_id(),
                   text: "keep durable ref",
                   max_text_bytes: 32_000
                 },
                 duplicate_owner: :live
               )

      assert {:ok, admitted} = InputReceipt.mark_admitted(event, %{})

      assert {:ok, durable_terminal} =
               Channels.update_event(
                 admitted,
                 %{
                   status: "processed",
                   thread_id: "durable-thread"
                 },
                 ReadyEffectContext.context()
               )

      assert {:error, :invalid_receipt_transition} =
               InputReceipt.mark_terminal(admitted, :failed, %{
                 thread_id: "different-thread"
               })

      persisted = Repo.get!(Event, durable_terminal.id)
      assert persisted.status == "processed"
      assert persisted.receipt_state == "admitted"
      assert persisted.receipt_outcome == nil
      assert persisted.thread_id == "durable-thread"
    end

    test "direct transitions reject an inconsistent durable receipt tuple" do
      assert {:ok, %{event: event}} =
               InputReceipt.gate(
                 %{
                   verified_operator_id: "local",
                   profile: "work",
                   input_receipt_id: TUIProtocol.new_receipt_id(),
                   text: "inconsistent transition",
                   max_text_bytes: 32_000
                 },
                 duplicate_owner: :live
               )

      assert {:ok, admitted} = InputReceipt.mark_admitted(event, %{})

      assert {:ok, inconsistent} =
               Channels.update_event(
                 admitted,
                 %{receipt_outcome: "rejected"},
                 ReadyEffectContext.context()
               )

      assert {:error, :invalid_receipt_transition} =
               InputReceipt.mark_terminal(admitted, :completed, %{})

      persisted = Repo.get!(Event, inconsistent.id)
      assert persisted.status == "received"
      assert persisted.receipt_state == "admitted"
      assert persisted.receipt_outcome == "rejected"
    end

    test "orphaned admitted receipt becomes outcome unknown without redispatch" do
      receipt_id = TUIProtocol.new_receipt_id()

      attrs = %{
        verified_operator_id: "local",
        profile: "work",
        input_receipt_id: receipt_id,
        text: "ambiguous work",
        max_text_bytes: 32_000
      }

      assert {:ok, %{disposition: :dispatch, event: event}} =
               InputReceipt.gate(attrs, duplicate_owner: :live)

      assert {:ok, admitted} =
               InputReceipt.mark_admitted(event, %{input_signal_id: "signal-ambiguous"})

      assert {:ok,
              %{
                disposition: :duplicate,
                event: unknown,
                state: :outcome_unknown,
                outcome: :outcome_unknown,
                message_id: nil,
                result_ref: nil
              } = result} =
               InputReceipt.gate(attrs, duplicate_owner: :orphaned)

      assert unknown.id == admitted.id
      assert unknown.receipt_state == "outcome_unknown"
      assert unknown.receipt_outcome == "outcome_unknown"
      refute Map.has_key?(result, :normalized_text)

      assert {:ok, %{disposition: :duplicate, state: :outcome_unknown}} =
               InputReceipt.gate(attrs, duplicate_owner: :orphaned)
    end

    test "terminal duplicate returns only the prior safe outcome and references" do
      receipt_id = TUIProtocol.new_receipt_id()

      attrs = %{
        verified_operator_id: "local",
        profile: "work",
        input_receipt_id: receipt_id,
        text: "one terminal turn",
        max_text_bytes: 32_000
      }

      assert {:ok, %{event: event}} = InputReceipt.gate(attrs, duplicate_owner: :live)
      assert {:ok, admitted} = InputReceipt.mark_admitted(event, %{thread_id: "thread-1"})

      assert {:ok, terminal} =
               InputReceipt.mark_terminal(admitted, :completed, %{
                 receipt_message_id: "message-1",
                 receipt_result_ref: "result-1"
               })

      assert {:ok,
              %{
                disposition: :duplicate,
                event: duplicate,
                state: :completed,
                outcome: :completed,
                message_id: "message-1",
                result_ref: "result-1"
              } = result} =
               InputReceipt.gate(attrs, duplicate_owner: :orphaned)

      assert duplicate.id == terminal.id
      refute Map.has_key?(result, :normalized_text)
      refute inspect(result) =~ "one terminal turn"
    end

    test "orphaned duplicate reconciles a durable terminal status and exact refs" do
      Enum.each(
        [{"processed", :completed}, {"rejected", :rejected}, {"failed", :failed}],
        fn {status, expected_outcome} ->
          receipt_id = TUIProtocol.new_receipt_id()
          message_id = "message-#{status}"
          result_ref = "result-#{status}"

          attrs = %{
            verified_operator_id: "local",
            profile: "work",
            input_receipt_id: receipt_id,
            text: "orphaned #{status}",
            max_text_bytes: 32_000
          }

          assert {:ok, %{event: event}} = InputReceipt.gate(attrs, duplicate_owner: :live)
          assert {:ok, admitted} = InputReceipt.mark_admitted(event, %{})

          assert {:ok, durable_terminal} =
                   Channels.update_event(
                     admitted,
                     %{
                       status: status,
                       receipt_message_id: message_id,
                       receipt_result_ref: result_ref
                     },
                     ReadyEffectContext.context()
                   )

          assert {:ok,
                  %{
                    disposition: :duplicate,
                    event: reconciled,
                    state: ^expected_outcome,
                    outcome: ^expected_outcome,
                    message_id: ^message_id,
                    result_ref: ^result_ref
                  }} = InputReceipt.gate(attrs, duplicate_owner: :orphaned)

          assert reconciled.id == durable_terminal.id
          assert reconciled.status == status
          assert reconciled.receipt_state == Atom.to_string(expected_outcome)
          assert reconciled.receipt_outcome == Atom.to_string(expected_outcome)
        end
      )
    end

    test "inconsistent duplicate receipt state fails closed" do
      receipt_id = TUIProtocol.new_receipt_id()

      attrs = %{
        verified_operator_id: "local",
        profile: "work",
        input_receipt_id: receipt_id,
        text: "inconsistent receipt",
        max_text_bytes: 32_000
      }

      assert {:ok, %{event: event}} = InputReceipt.gate(attrs, duplicate_owner: :live)

      assert {:ok, inconsistent} =
               Channels.update_event(
                 event,
                 %{
                   status: "rejected",
                   receipt_state: "completed",
                   receipt_outcome: "completed"
                 },
                 ReadyEffectContext.context()
               )

      assert {:error, :receipt_conflict} =
               InputReceipt.gate(attrs, duplicate_owner: :orphaned)

      persisted = Repo.get!(Event, inconsistent.id)
      assert persisted.status == "rejected"
      assert persisted.receipt_state == "completed"
      assert persisted.receipt_outcome == "completed"
    end

    test "existing receipt with missing integrity key fails closed without replacement" do
      receipt_id = TUIProtocol.new_receipt_id()

      attrs = %{
        verified_operator_id: "local",
        profile: "work",
        input_receipt_id: receipt_id,
        text: "preserve uncertainty",
        max_text_bytes: 32_000
      }

      assert {:ok, %{disposition: :dispatch, event: event}} =
               InputReceipt.gate(attrs, duplicate_owner: :live)

      secrets_path = Secrets.secrets_path()
      assert File.exists?(secrets_path)
      File.rm!(secrets_path)
      KeyCustody.invalidate(:all)

      assert {:error, :receipt_key_unavailable} =
               InputReceipt.gate(attrs, duplicate_owner: :orphaned)

      refute File.exists?(secrets_path)
      assert Repo.get!(Event, event.id).receipt_state == "received"

      assert {:error, :receipt_key_unavailable} =
               InputReceipt.gate(
                 %{attrs | input_receipt_id: TUIProtocol.new_receipt_id()},
                 duplicate_owner: :live
               )

      refute File.exists?(secrets_path)
      assert Repo.aggregate(Event, :count) == 1
    end

    test "receipt transitions reject arbitrary or unbounded reference maps" do
      receipt_id = TUIProtocol.new_receipt_id()

      assert {:ok, %{event: event}} =
               InputReceipt.gate(
                 %{
                   verified_operator_id: "local",
                   profile: "work",
                   input_receipt_id: receipt_id,
                   text: "bounded refs",
                   max_text_bytes: 32_000
                 },
                 duplicate_owner: :live
               )

      assert {:error, :invalid_receipt_refs} =
               InputReceipt.mark_admitted(event, %{raw_input: "must not persist"})

      assert {:ok, admitted} = InputReceipt.mark_admitted(event, %{})

      assert {:error, :invalid_receipt_refs} =
               InputReceipt.mark_terminal(admitted, :completed, %{
                 output: "must not persist"
               })

      assert {:error, :invalid_receipt_refs} =
               InputReceipt.mark_terminal(admitted, :completed, %{
                 receipt_result_ref: String.duplicate("x", 257)
               })

      persisted = Repo.get!(Event, event.id)
      assert persisted.receipt_state == "admitted"
      assert persisted.receipt_outcome == nil
      assert persisted.receipt_result_ref == nil
      refute inspect(persisted) =~ "must not persist"
    end

    test "stale receipt structs cannot regress or rebind durable state" do
      assert {:ok, %{event: received}} =
               InputReceipt.gate(
                 %{
                   verified_operator_id: "local",
                   profile: "work",
                   input_receipt_id: TUIProtocol.new_receipt_id(),
                   text: "state stays terminal",
                   max_text_bytes: 32_000
                 },
                 duplicate_owner: :live
               )

      assert {:ok, admitted} =
               InputReceipt.mark_admitted(received, %{input_signal_id: "signal-1"})

      assert {:ok, in_progress} = InputReceipt.mark_in_progress(admitted)
      assert {:ok, completed} = InputReceipt.mark_terminal(in_progress, :completed, %{})

      assert {:error, :invalid_receipt_transition} =
               InputReceipt.mark_in_progress(admitted)

      assert {:error, :invalid_receipt_transition} =
               InputReceipt.mark_admitted(received, %{input_signal_id: "signal-2"})

      persisted = Repo.get!(Event, completed.id)
      assert persisted.receipt_state == "completed"
      assert persisted.receipt_outcome == "completed"
      assert persisted.input_signal_id == "signal-1"
    end
  end

  describe "daemon-owned TUI lifecycle" do
    test "application boot leaves no static or stale TUI adapter" do
      refute tui_child()
      refute Process.whereis(Adapter)
    end

    test "authenticated open starts one headless adapter and detach removes it" do
      server = start_supervised!(AttachServer)
      {socket, snapshot, client_flow} = open_session()

      assert snapshot.frame == :snapshot
      assert snapshot.seq == 1
      assert snapshot.ack == 0

      assert snapshot.payload == %{
               render_revision: 0,
               state: :idle,
               lines: [],
               gap?: false
             }

      assert %{status: :up, tui_session: :active} = AttachServer.status(server)
      assert {"tui", adapter_pid, :worker, _modules} = tui_child()
      assert Process.whereis(Adapter) == adapter_pid

      {:ok, detach, _client_flow} =
        TUIProtocol.send_frame(
          client_flow,
          :client_to_daemon,
          :detach,
          %{reason: :operator_exit}
        )

      :ok = send_term(socket, detach)
      assert %{frame: :close, payload: %{code: :client_detach}} = recv_term(socket)

      eventually(fn ->
        AttachServer.status(server).tui_session == :none and is_nil(tui_child()) and
          is_nil(Process.whereis(Adapter))
      end)
    end

    test "default client selector resolves the daemon-owned Settings profile" do
      assert {:ok, _setting} =
               Settings.put(
                 "channels.tui.profile",
                 "work",
                 ReadyEffectContext.attach(%{audit?: false})
               )

      assert {:ok, _setting} =
               Settings.put(
                 "channels.tui.identity_map",
                 [
                   %{
                     "external_user_id" => "work",
                     "user_id" => "local",
                     "enabled" => true
                   }
                 ],
                 ReadyEffectContext.attach(%{audit?: false})
               )

      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      {"tui", adapter_pid, :worker, _modules} = tui_child()

      assert %{profile: "work"} = :sys.get_state(adapter_pid)
      assert %{status: :up, tui_session: :active} = AttachServer.status(server)

      detach(socket, client_flow)
    end

    test "default client selector fails closed when daemon channel settings are unavailable" do
      server =
        start_supervised!(
          {AttachServer,
           session_opts: [
             channel_settings_fun: fn "tui" -> {:error, :settings_unavailable} end
           ]}
        )

      socket = connect_socket()
      :ok = send_term(socket, valid_open())

      assert %{frame: :close, code: :runtime_unavailable} = recv_term(socket)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)

      eventually(fn -> AttachServer.status(server).tui_session == :none end)
      refute tui_child()
      refute Process.whereis(Adapter)
    end

    test "quiet resize traffic preserves status while acknowledging beyond the retained window" do
      _server = start_controllable_server()
      {socket, _snapshot, client_flow} = open_session()

      {:ok, input, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :input, %{
          input_receipt_id: TUIProtocol.new_receipt_id(),
          text: ""
        })

      :ok = send_term(socket, input)
      {error, client_flow} = receive_until(socket, client_flow, :error)

      assert %{
               code: :invalid_input,
               message: status_text
             } = error.payload

      client_flow =
        Enum.reduce(1..40, client_flow, fn index, flow ->
          {:ok, resize, flow} =
            TUIProtocol.send_frame(flow, :client_to_daemon, :resize, %{
              columns: 80 + rem(index, 40),
              rows: 24 + rem(index, 20)
            })

          :ok = send_term(socket, resize)
          assert_status_carrier(socket, flow, resize, status_text)
        end)

      {:ok, confirmation, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :confirmation, %{
          confirmation_id: "quiet-confirmation",
          decision: :deny
        })

      :ok = send_term(socket, confirmation)
      client_flow = assert_status_carrier(socket, client_flow, confirmation, status_text)

      {:ok, cancel, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :cancel, %{
          reason: :operator_escape
        })

      :ok = send_term(socket, cancel)
      client_flow = assert_status_carrier(socket, client_flow, cancel, status_text)

      receipt_id = TUIProtocol.new_receipt_id()

      {:ok, input, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :input, %{
          input_receipt_id: receipt_id,
          text: "input after quiet pressure"
        })

      :ok = send_term(socket, input)
      client_flow = assert_status_carrier(socket, client_flow, input, status_text)
      assert_receive {:test_submit_started, _task, ^receipt_id}, 5_000

      {status, client_flow} = receive_until(socket, client_flow, :status)
      assert %{payload: %{text: "Input admitted.", input_receipt_id: ^receipt_id}} = status

      detach(socket, client_flow)
    end

    test "a slow pre-authentication peer does not serialize a valid open" do
      server = start_supervised!(AttachServer)
      stalled = connect_socket()

      eventually(fn -> AttachServer.status(server).pending_handshakes == 1 end)

      started_at = System.monotonic_time(:millisecond)
      {socket, snapshot, client_flow} = open_session(3_000)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert snapshot.frame == :snapshot
      assert elapsed < 5_000
      assert AttachServer.status(server).pending_handshakes == 1

      :gen_tcp.close(stalled)
      detach(socket, client_flow)
      eventually(fn -> AttachServer.status(server).pending_handshakes == 0 end)
    end

    test "pending handshakes are capped separately at sixteen" do
      server = start_supervised!(AttachServer)

      stalled =
        Enum.map(1..16, fn expected_count ->
          socket = connect_socket()
          eventually(fn -> AttachServer.status(server).pending_handshakes == expected_count end)
          socket
        end)

      eventually(fn -> AttachServer.status(server).pending_handshakes == 16 end)

      rejected = connect_socket()

      assert %{
               kind: :tui_session,
               frame: :close,
               session_protocol: 1,
               code: :capacity
             } = recv_term(rejected)

      :gen_tcp.close(rejected)
      Enum.each(stalled, &:gen_tcp.close/1)
      eventually(fn -> AttachServer.status(server).pending_handshakes == 0 end)
    end

    test "a second authenticated open is rejected without another adapter" do
      server = start_supervised!(AttachServer)
      {first_socket, _snapshot, client_flow} = open_session()
      second_socket = connect_socket()
      :ok = send_term(second_socket, valid_open())

      assert %{frame: :close, code: :already_attached} = recv_term(second_socket)
      assert %{tui_session: :active} = AttachServer.status(server)
      assert {"tui", adapter_pid, :worker, _modules} = tui_child()
      assert Process.whereis(Adapter) == adapter_pid

      :gen_tcp.close(second_socket)
      detach(first_socket, client_flow)
    end

    test "simultaneous authenticated opens reserve exactly one session and adapter" do
      server = start_controllable_server()
      sockets = [connect_socket(), connect_socket()]
      parent = self()

      senders =
        Enum.map(sockets, fn socket ->
          Task.async(fn ->
            send(parent, {:open_sender_ready, self()})

            receive do
              :send_open -> send_term(socket, valid_open())
            end
          end)
        end)

      Enum.each(senders, fn sender ->
        sender_pid = sender.pid
        assert_receive {:open_sender_ready, ^sender_pid}
      end)

      Enum.each(senders, &send(&1.pid, :send_open))
      Enum.each(senders, &Task.await(&1, 5_000))

      responses = Enum.map(sockets, &{&1, recv_term(&1)})

      assert [{winner, %{frame: :snapshot} = snapshot}] =
               Enum.filter(responses, fn {_socket, response} -> response.frame == :snapshot end)

      assert [{loser, %{frame: :close, code: :already_attached}}] =
               Enum.filter(responses, fn {_socket, response} -> response.frame == :close end)

      assert %{status: :up, tui_session: :active} = AttachServer.status(server)

      assert 1 ==
               AllbertAssist.Channels.Supervisor
               |> Supervisor.which_children()
               |> Enum.count(fn {id, pid, _type, _modules} -> id == "tui" and is_pid(pid) end)

      assert {:error, :closed} = :gen_tcp.recv(loser, 0, 1_000)

      {:ok, client_flow} = TUIProtocol.new_flow(snapshot.session_id)
      {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, snapshot)
      detach(winner, client_flow)
    end

    test "explicit channel disable denies open before adapter startup" do
      assert {:ok, _settings} =
               Settings.put(
                 "channels.tui.enabled",
                 false,
                 ReadyEffectContext.attach(%{audit?: false})
               )

      server = start_supervised!(AttachServer)
      socket = connect_socket()
      :ok = send_term(socket, valid_open())

      assert %{frame: :close, code: :identity_denied} = recv_term(socket)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
      refute tui_child()
      refute Process.whereis(Adapter)
    end

    test "socket loss releases the adapter, reservation, and blocked delivery custody" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, _client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid

      delivery = Task.async(fn -> TUISession.delivery_output(session_pid, "fan-out report") end)
      assert %{frame: :delta, payload: %{lines: ["fan-out report"]}} = recv_term(socket)
      assert Task.yield(delivery, 50) == nil

      :gen_tcp.close(socket)
      assert Task.await(delivery, 5_000) == {:error, :session_closed}

      eventually(fn ->
        AttachServer.status(server).tui_session == :none and is_nil(tui_child()) and
          is_nil(Process.whereis(Adapter))
      end)
    end

    test "protocol error sends the terminal close last and releases adapter and reservation" do
      server = start_controllable_server()
      {socket, snapshot, client_flow} = open_session()

      invalid_ack = %{
        kind: :tui_session,
        session_protocol: TUIProtocol.session_protocol(),
        frame: :ack,
        session_id: snapshot.session_id,
        seq: 1,
        ack: 1,
        payload: %{unexpected: true}
      }

      :ok = send_term(socket, invalid_ack)
      close = recv_term(socket)

      assert %{frame: :close, payload: %{code: :protocol_error}} = close
      assert {:ok, _client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, close)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)

      eventually(fn ->
        AttachServer.status(server).tui_session == :none and is_nil(tui_child())
      end)

      {fresh_socket, _fresh_snapshot, fresh_flow} = open_session()
      detach(fresh_socket, fresh_flow)
    end

    test "daemon output canonicalizes CRLF and LF into bounded logical lines" do
      server = start_controllable_server()
      {socket, _snapshot, client_flow} = open_session()
      {"tui", adapter_pid, :worker, _modules} = tui_child()

      assert :ok =
               ControllableAdapter.output(
                 adapter_pid,
                 "first\r\nsecond\n\nfourth\rbare"
               )

      delta = recv_term(socket)

      assert %{frame: :delta, payload: %{lines: ["first", "second", "", "fourth\rbare"]}} =
               delta

      {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, delta)

      too_many_lines = Enum.join(List.duplicate("x", 257), "\n")

      assert {:error, :output_too_large} =
               ControllableAdapter.output(adapter_pid, too_many_lines)

      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
      assert %{status: :up, tui_session: :active} = AttachServer.status(server)
      detach(socket, client_flow)
    end

    test "Settings max text bytes bounds rendered daemon output" do
      assert {:ok, _settings} =
               Settings.put(
                 "channels.tui.max_text_bytes",
                 7,
                 ReadyEffectContext.attach(%{audit?: false})
               )

      server = start_controllable_server()
      {socket, _snapshot, client_flow} = open_session()
      {"tui", adapter_pid, :worker, _modules} = tui_child()

      assert :ok = ControllableAdapter.output(adapter_pid, "1234567")
      delta = recv_term(socket)
      assert %{frame: :delta, payload: %{lines: ["1234567"]}} = delta
      {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, delta)

      assert {:error, :output_too_large} =
               ControllableAdapter.output(adapter_pid, "12345678")

      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
      assert %{status: :up, tui_session: :active} = AttachServer.status(server)
      detach(socket, client_flow)
    end

    test "ordinary daemon output retains the default 12,000-byte ceiling" do
      server = start_controllable_server()
      {socket, _snapshot, client_flow} = open_session()
      {"tui", adapter_pid, :worker, _modules} = tui_child()
      body = bounded_multiline_body(12_000)

      assert :ok = ControllableAdapter.output(adapter_pid, body)
      delta = recv_term(socket)
      assert delta.payload.lines |> Enum.join("\n") == body
      {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, delta)

      assert {:error, :output_too_large} =
               ControllableAdapter.output(adapter_pid, body <> "x")

      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
      assert %{status: :up, tui_session: :active} = AttachServer.status(server)
      detach(socket, client_flow)
    end

    test "ordinary daemon output retains the configured 32,000-byte maximum" do
      assert {:ok, _settings} =
               Settings.put(
                 "channels.tui.max_text_bytes",
                 32_000,
                 ReadyEffectContext.attach(%{audit?: false})
               )

      server = start_controllable_server()
      {socket, _snapshot, client_flow} = open_session()
      {"tui", adapter_pid, :worker, _modules} = tui_child()
      body = bounded_multiline_body(32_000)

      assert :ok = ControllableAdapter.output(adapter_pid, body)
      delta = recv_term(socket)
      assert delta.payload.lines |> Enum.join("\n") == body
      {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, delta)

      assert {:error, :output_too_large} =
               ControllableAdapter.output(adapter_pid, body <> "x")

      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
      assert %{status: :up, tui_session: :active} = AttachServer.status(server)
      detach(socket, client_flow)
    end

    test "Settings input limit rejects semantically without closing the wire session" do
      assert {:ok, _settings} =
               Settings.put(
                 "channels.tui.max_text_bytes",
                 7,
                 ReadyEffectContext.attach(%{audit?: false})
               )

      server = start_controllable_server()
      {socket, _snapshot, client_flow} = open_session()
      receipt_id = TUIProtocol.new_receipt_id()

      {:ok, input, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :input, %{
          input_receipt_id: receipt_id,
          text: "12345678"
        })

      :ok = send_term(socket, input)
      {error, client_flow} = receive_until(socket, client_flow, :error)

      assert %{
               code: :invalid_input,
               input_receipt_id: ^receipt_id,
               message: "Input is invalid."
             } = error.payload

      assert %{status: :up, tui_session: :active} = AttachServer.status(server)
      detach(socket, client_flow)
    end

    test "blocked input does not delay acknowledgement, cancellation, or detach cleanup" do
      server =
        start_controllable_server(%{
          block_submit?: true,
          block_cancel?: true
        })

      {socket, _snapshot, client_flow} = open_session()
      {"tui", adapter_pid, :worker, _modules} = tui_child()
      receipt_id = TUIProtocol.new_receipt_id()

      {:ok, input, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :input, %{
          input_receipt_id: receipt_id,
          text: "block this admitted input"
        })

      :ok = send_term(socket, input)
      assert_receive {:test_submit_started, inbound_task, ^receipt_id}, 5_000
      inbound_monitor = Process.monitor(inbound_task)

      delivery =
        Task.async(fn ->
          ControllableAdapter.delivery_output(adapter_pid, "acknowledge this report")
        end)

      {delta, client_flow} = receive_until(socket, client_flow, :delta)
      assert %{frame: :delta, payload: %{lines: ["acknowledge this report"]}} = delta
      assert Task.yield(delivery, 50) == nil

      {:ok, ack, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      assert Task.await(delivery, 1_000) == :ok

      {:ok, cancel, client_flow} =
        TUIProtocol.send_frame(
          client_flow,
          :client_to_daemon,
          :cancel,
          %{reason: :operator_interrupt}
        )

      :ok = send_term(socket, cancel)
      assert_receive {:test_cancel_started, control_task, :operator_interrupt}, 1_000
      control_monitor = Process.monitor(control_task)

      client_flow =
        assert_status_carrier(socket, client_flow, cancel, %{
          render_revision: 1,
          state: :streaming,
          text: ""
        })

      {:ok, detach, _client_flow} =
        TUIProtocol.send_frame(
          client_flow,
          :client_to_daemon,
          :detach,
          %{reason: :operator_exit}
        )

      started_at = System.monotonic_time(:millisecond)
      :ok = send_term(socket, detach)
      assert %{frame: :close, payload: %{code: :client_detach}} = recv_term(socket, 1_000)
      assert System.monotonic_time(:millisecond) - started_at < 1_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)

      assert_receive {:DOWN, ^inbound_monitor, :process, ^inbound_task, _reason}, 1_000
      assert_receive {:DOWN, ^control_monitor, :process, ^control_task, _reason}, 1_000
      assert_receive {:test_teardown_cancel, ^adapter_pid, :operator_interrupt}, 1_000

      eventually(fn ->
        AttachServer.status(server).tui_session == :none and is_nil(tui_child())
      end)
    end

    test "detach without an accepted interrupt keeps escape teardown cancellation" do
      server = start_controllable_server()
      {socket, _snapshot, client_flow} = open_session()
      {"tui", adapter_pid, :worker, _modules} = tui_child()

      detach(socket, client_flow)

      assert_receive {:test_teardown_cancel, ^adapter_pid, :operator_escape}, 1_000

      eventually(fn ->
        AttachServer.status(server).tui_session == :none and is_nil(tui_child())
      end)
    end

    test "fan-out delivery custody completes only after cumulative client acknowledgement" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid

      delivery = Task.async(fn -> TUISession.delivery_output(session_pid, "durable report") end)
      delta = recv_term(socket)
      assert %{frame: :delta, payload: %{lines: ["durable report"]}} = delta
      assert Task.yield(delivery, 50) == nil

      {:ok, client_flow} =
        TUIProtocol.accept_frame(client_flow, :daemon_to_client, delta)

      {:ok, ack, _client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      assert Task.await(delivery, 5_000) == :ok

      :gen_tcp.close(socket)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "maximum fan-out authority delivery remains byte-exact through cumulative acknowledgement" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid
      body = maximum_report_body()

      assert byte_size(body) == Report.max_body_bytes()

      delivery = Task.async(fn -> TUISession.delivery_output(session_pid, body) end)
      delta = recv_term(socket)

      assert %{frame: :delta, payload: %{mode: :append, lines: lines}} = delta
      assert length(lines) == TUIProtocol.limits().list_items
      assert Enum.sum(Enum.map(lines, &byte_size/1)) <= 48 * 1_024
      assert Enum.join(lines, "\n") == body
      assert byte_size(:erlang.term_to_binary(delta)) <= 64 * 1_024
      assert Task.yield(delivery, 50) == nil

      {:ok, client_flow} =
        TUIProtocol.accept_frame(client_flow, :daemon_to_client, delta)

      {:ok, ack, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      assert Task.await(delivery, 5_000) == :ok

      assert :ok = TUISession.output(session_pid, "ordinary presentation")
      ordinary_delta = recv_term(socket)

      assert %{frame: :delta, payload: %{lines: ["ordinary presentation"]}} = ordinary_delta

      {:ok, client_flow} =
        TUIProtocol.accept_frame(client_flow, :daemon_to_client, ordinary_delta)

      render_lines = :sys.get_state(session_pid).render_lines
      assert List.last(render_lines) == "ordinary presentation"
      assert Enum.sum(Enum.map(render_lines, &byte_size/1)) <= 12_000

      detach(socket, client_flow)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "fan-out authority delivery rejects a body above 32,768 bytes" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, _client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid
      secret_marker = "v13-overbound-private-report-marker"
      report = maximum_report_body()

      body =
        secret_marker <>
          binary_part(
            report,
            byte_size(secret_marker),
            byte_size(report) - byte_size(secret_marker)
          ) <> "x"

      assert byte_size(body) == Report.max_body_bytes() + 1

      log =
        capture_log(fn ->
          assert {:error, :output_too_large} = TUISession.delivery_output(session_pid, body)

          assert %{frame: :close, payload: %{code: :overflow, message: message}} =
                   recv_term(socket)

          assert message == "TUI output capacity was exceeded."
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
          eventually(fn -> AttachServer.status(server).tui_session == :none end)
        end)

      refute log =~ secret_marker
    end

    test "authority delivery custody survives presentation gap recovery until acknowledgement" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid

      Enum.each(1..100, fn index ->
        assert :ok = TUISession.output(session_pid, "pressure-#{index}")
      end)

      delivery =
        Task.async(fn ->
          TUISession.delivery_output(session_pid, "authority-after-gap")
        end)

      assert Task.yield(delivery, 100) == nil

      client_flow = receive_daemon_frames(socket, client_flow, 31)

      {:ok, ack, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      {authority, client_flow} = receive_until_line(socket, client_flow, "authority-after-gap")

      assert authority.frame == :delta
      assert Task.yield(delivery, 100) == nil

      {:ok, ack, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      assert Task.await(delivery, 1_000) == :ok

      detach(socket, client_flow)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "authority delivery custody under gap pressure is released by teardown" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, _client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid

      Enum.each(1..100, fn index ->
        assert :ok = TUISession.output(session_pid, "teardown-pressure-#{index}")
      end)

      delivery =
        Task.async(fn ->
          TUISession.delivery_output(session_pid, "authority-awaiting-teardown")
        end)

      assert Task.yield(delivery, 100) == nil
      :gen_tcp.close(socket)
      assert Task.await(delivery, 1_000) == {:error, :session_closed}

      eventually(fn ->
        AttachServer.status(server).tui_session == :none and is_nil(tui_child())
      end)
    end

    test "detach drains queued non-droppable frames before the final close" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid
      {completion_receipt, completion_event} = admitted_receipt("queued completion")
      {error_receipt, error_event} = admitted_receipt("queued outcome error")

      assert {:ok, _inconsistent} =
               Channels.update_event(
                 error_event,
                 %{receipt_outcome: "rejected"},
                 ReadyEffectContext.context()
               )

      Enum.each(1..31, fn index ->
        assert :ok = TUISession.output(session_pid, "window-#{index}")
      end)

      client_flow = receive_daemon_frames(socket, client_flow, 31)

      assert :ok =
               TUISession.confirmation(session_pid, %{
                 confirmation_id: "queued-confirmation-1",
                 prompt: "Approve one?",
                 expires_at_unix_ms: 0
               })

      :ok =
        TUISession.input_lifecycle(
          session_pid,
          completion_receipt,
          completion_event,
          {:terminal, {:ok, %{}}}
        )

      :ok =
        TUISession.input_lifecycle(
          session_pid,
          error_receipt,
          error_event,
          {:terminal, {:ok, %{}}}
        )

      assert :ok =
               TUISession.confirmation(session_pid, %{
                 confirmation_id: "queued-confirmation-2",
                 prompt: "Approve two?",
                 expires_at_unix_ms: 0
               })

      {:ok, detach, client_flow} =
        TUIProtocol.send_frame(
          client_flow,
          :client_to_daemon,
          :detach,
          %{reason: :operator_exit}
        )

      :ok = send_term(socket, detach)

      expected = [
        {:confirmation, "queued-confirmation-1"},
        {:completion, completion_receipt},
        {:error, :outcome_unknown},
        {:confirmation, "queued-confirmation-2"},
        {:close, :client_detach}
      ]

      _client_flow =
        Enum.reduce(expected, client_flow, fn expectation, flow ->
          frame = recv_term(socket)
          assert_expected_frame(frame, expectation)
          {:ok, flow} = TUIProtocol.accept_frame(flow, :daemon_to_client, frame)
          flow
        end)

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "outbound byte high-water replaces presentation with a bounded gap snapshot" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid
      limits = TUIProtocol.limits().daemon_outbound_unsent
      large_line = String.duplicate("b", 8 * 1_024)

      assert 40 < limits.frames
      assert 40 * byte_size(large_line) > limits.bytes

      Enum.each(1..31, fn index ->
        assert :ok = TUISession.output(session_pid, "byte-window-#{index}")
      end)

      client_flow = receive_daemon_frames(socket, client_flow, 31)

      Enum.each(1..40, fn _index ->
        assert :ok = TUISession.output(session_pid, large_line)
      end)

      {:ok, ack, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      replacement = recv_term(socket)

      assert %{
               frame: :snapshot,
               payload: %{gap?: true, lines: [^large_line], render_revision: 71}
             } = replacement

      {:ok, client_flow} =
        TUIProtocol.accept_frame(client_flow, :daemon_to_client, replacement)

      detach(socket, client_flow)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "count pressure preserves confirmation while replacing droppable status and deltas" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid
      {receipt_id, event} = admitted_receipt("pressure status")
      limits = TUIProtocol.limits().daemon_outbound_unsent

      Enum.each(1..31, fn index ->
        assert :ok = TUISession.output(session_pid, "count-window-#{index}")
      end)

      client_flow = receive_daemon_frames(socket, client_flow, 31)
      :ok = TUISession.input_lifecycle(session_pid, receipt_id, event, :in_progress)

      assert :ok =
               TUISession.confirmation(session_pid, %{
                 confirmation_id: "preserved-confirmation",
                 prompt: "Keep this authority frame?",
                 expires_at_unix_ms: 0
               })

      assert 1 + 1 + 63 > limits.frames

      Enum.each(1..63, fn index ->
        assert :ok = TUISession.output(session_pid, "queued-delta-#{index}")
      end)

      {:ok, ack, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      confirmation = recv_term(socket)
      replacement = recv_term(socket)

      assert %{
               frame: :confirmation,
               payload: %{confirmation_id: "preserved-confirmation"}
             } = confirmation

      assert %{frame: :snapshot, payload: %{gap?: true, render_revision: 94}} = replacement

      {:ok, client_flow} =
        TUIProtocol.accept_frame(client_flow, :daemon_to_client, confirmation)

      {:ok, client_flow} =
        TUIProtocol.accept_frame(client_flow, :daemon_to_client, replacement)

      detach(socket, client_flow)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "non-droppable queue overflow terminates the session and releases its reservation" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid
      limits = TUIProtocol.limits().daemon_outbound_unsent

      Enum.each(1..31, fn index ->
        assert :ok = TUISession.output(session_pid, "overflow-window-#{index}")
      end)

      _client_flow = receive_daemon_frames(socket, client_flow, 31)

      Enum.each(1..limits.frames, fn index ->
        assert :ok =
                 TUISession.confirmation(session_pid, %{
                   confirmation_id: "overflow-confirmation-#{index}",
                   prompt: "Queued confirmation #{index}",
                   expires_at_unix_ms: 0
                 })
      end)

      assert {:error, :overflow} =
               TUISession.confirmation(session_pid, %{
                 confirmation_id: "overflow-confirmation-terminal",
                 prompt: "This frame cannot fit.",
                 expires_at_unix_ms: 0
               })

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)

      eventually(fn ->
        AttachServer.status(server).tui_session == :none and is_nil(tui_child())
      end)

      {fresh_socket, _fresh_snapshot, fresh_flow} = open_session()
      detach(fresh_socket, fresh_flow)
    end

    test "presentation pressure coalesces to a non-empty full gap snapshot" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      session_pid = :sys.get_state(server).session.pid

      Enum.each(1..100, fn index ->
        assert :ok = TUISession.output(session_pid, "line-#{index}")
      end)

      client_flow =
        Enum.reduce(1..31, client_flow, fn _index, flow ->
          delta = recv_term(socket)
          assert delta.frame == :delta
          {:ok, flow} = TUIProtocol.accept_frame(flow, :daemon_to_client, delta)
          flow
        end)

      {:ok, ack, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :ack, %{})

      :ok = send_term(socket, ack)
      replacement = recv_term(socket)

      assert %{
               frame: :snapshot,
               payload: %{gap?: true, lines: lines, render_revision: 100}
             } = replacement

      assert lines != []
      assert List.last(lines) == "line-100"
      assert length(lines) <= 256
      assert Enum.sum(Enum.map(lines, &byte_size/1)) <= 48 * 1_024

      {:ok, _client_flow} =
        TUIProtocol.accept_frame(client_flow, :daemon_to_client, replacement)

      :gen_tcp.close(socket)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "slash input is receipt-gated and a same-payload retry never redispatches" do
      server = start_supervised!(AttachServer)
      {socket, _snapshot, client_flow} = open_session()
      receipt_id = TUIProtocol.new_receipt_id()

      {:ok, input, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :input, %{
          input_receipt_id: receipt_id,
          text: "/help"
        })

      :ok = send_term(socket, input)
      {completion, client_flow} = receive_until(socket, client_flow, :completion)

      assert completion.payload.input_receipt_id == receipt_id
      assert completion.payload.outcome == :completed
      assert completion.payload.duplicate? == false

      event = Repo.get_by!(Event, channel: "tui", external_message_id: receipt_id)
      assert event.receipt_state == "completed"
      assert event.receipt_outcome == "completed"

      {:ok, retry, client_flow} =
        TUIProtocol.send_frame(client_flow, :client_to_daemon, :input, %{
          input_receipt_id: receipt_id,
          text: "  /help  "
        })

      :ok = send_term(socket, retry)
      {duplicate, client_flow} = receive_until(socket, client_flow, :completion)
      assert duplicate.payload.input_receipt_id == receipt_id
      assert duplicate.payload.outcome == :completed
      assert duplicate.payload.duplicate? == true
      assert Repo.aggregate(Event, :count, :id) == 1

      detach(socket, client_flow)
      eventually(fn -> AttachServer.status(server).tui_session == :none end)
    end

    test "listener bind failure stays alive and degrades bounded health" do
      File.mkdir_p!(Attach.socket_path())
      server = start_supervised!(AttachServer)

      assert %{status: :degraded, reason: reason, tui_session: :none} =
               AttachServer.status(server)

      assert is_atom(reason)
      assert %{status: :degraded, attach: %{status: :degraded}} = Health.snapshot()
      assert Process.alive?(server)
    end
  end

  defp open_session(timeout \\ 5_000) do
    socket = connect_socket()
    :ok = send_term(socket, valid_open())
    snapshot = recv_term(socket, timeout)
    assert snapshot.frame == :snapshot
    {:ok, client_flow} = TUIProtocol.new_flow(snapshot.session_id)
    {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, snapshot)
    {socket, snapshot, client_flow}
  end

  defp start_controllable_server(overrides \\ %{}) do
    config =
      Map.merge(
        %{controller: self(), block_submit?: false, block_cancel?: false},
        overrides
      )

    original = Application.get_env(:allbert_assist, :tui_session_test_adapter)
    Application.put_env(:allbert_assist, :tui_session_test_adapter, config)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:allbert_assist, :tui_session_test_adapter),
        else: Application.put_env(:allbert_assist, :tui_session_test_adapter, original)
    end)

    start_supervised!({AttachServer, session_opts: [adapter_module: ControllableAdapter]})
  end

  defp valid_open do
    {:ok, token} = Attach.read_token()

    Attach.identity()
    |> Map.merge(%{
      kind: :tui_session,
      frame: :open,
      session_protocol: 1,
      token: token,
      profile: "default",
      terminal: %{columns: 120, rows: 40, color: :truecolor, unicode?: true}
    })
  end

  defp connect_socket(attempts \\ 50)

  defp connect_socket(attempts) when attempts > 0 do
    case :gen_tcp.connect(
           {:local, Attach.socket_path()},
           0,
           [:binary, packet: 4, active: false],
           5_000
         ) do
      {:ok, socket} ->
        socket

      {:error, :econnrefused} ->
        Process.sleep(10)
        connect_socket(attempts - 1)

      {:error, reason} ->
        flunk("attach socket connection failed: #{inspect(reason)}")
    end
  end

  defp connect_socket(0), do: flunk("attach socket did not accept a connection")

  defp send_term(socket, term),
    do: :gen_tcp.send(socket, :erlang.term_to_binary(term))

  defp recv_term(socket, timeout \\ 5_000) do
    {:ok, payload} = :gen_tcp.recv(socket, 0, timeout)
    :erlang.binary_to_term(payload, [:safe])
  end

  defp assert_status_carrier(socket, client_flow, client_frame, status_text)
       when is_binary(status_text) do
    assert_status_carrier(socket, client_flow, client_frame, %{
      render_revision: 0,
      state: :error,
      text: status_text
    })
  end

  defp assert_status_carrier(socket, client_flow, client_frame, expected_status)
       when is_map(expected_status) do
    carrier = recv_term(socket, 1_000)

    assert %{
             frame: :status,
             ack: acknowledged_seq,
             payload: %{
               render_revision: render_revision,
               state: render_state,
               text: status_text,
               input_receipt_id: nil
             }
           } = carrier

    assert render_revision == expected_status.render_revision
    assert render_state == expected_status.state
    assert status_text == expected_status.text
    assert acknowledged_seq == client_frame.seq

    assert {:ok, client_flow} =
             TUIProtocol.accept_frame(client_flow, :daemon_to_client, carrier)

    client_flow
  end

  defp receive_until(socket, client_flow, wanted_frame, attempts \\ 30)

  defp receive_until(_socket, _client_flow, wanted_frame, 0),
    do: flunk("did not receive #{wanted_frame} frame")

  defp receive_until(socket, client_flow, wanted_frame, attempts) do
    frame = recv_term(socket, 10_000)
    {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, frame)

    if frame.frame == wanted_frame,
      do: {frame, client_flow},
      else: receive_until(socket, client_flow, wanted_frame, attempts - 1)
  end

  defp receive_until_line(socket, client_flow, wanted_line, attempts \\ 30)

  defp receive_until_line(_socket, _client_flow, wanted_line, 0),
    do: flunk("did not receive line #{wanted_line}")

  defp receive_until_line(socket, client_flow, wanted_line, attempts) do
    frame = recv_term(socket, 10_000)
    {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, frame)

    if wanted_line in Map.get(frame.payload, :lines, []),
      do: {frame, client_flow},
      else: receive_until_line(socket, client_flow, wanted_line, attempts - 1)
  end

  defp receive_daemon_frames(socket, client_flow, count) do
    Enum.reduce(1..count, client_flow, fn _index, flow ->
      frame = recv_term(socket)
      {:ok, flow} = TUIProtocol.accept_frame(flow, :daemon_to_client, frame)
      flow
    end)
  end

  defp admitted_receipt(text) do
    receipt_id = TUIProtocol.new_receipt_id()

    assert {:ok, %{event: event}} =
             InputReceipt.gate(
               %{
                 verified_operator_id: "local",
                 profile: "default",
                 input_receipt_id: receipt_id,
                 text: text,
                 max_text_bytes: 32_000
               },
               duplicate_owner: :live
             )

    assert {:ok, admitted} = InputReceipt.mark_admitted(event, %{})
    {receipt_id, admitted}
  end

  defp bounded_multiline_body(bytes) when is_integer(bytes) and bytes > 0 do
    line = String.duplicate("r", 4_095) <> "\n"
    full_lines = div(bytes, byte_size(line))
    remainder = rem(bytes, byte_size(line))

    String.duplicate(line, full_lines) <> String.duplicate("r", remainder)
  end

  defp maximum_report_body do
    line_count = TUIProtocol.limits().list_items
    content_bytes = Report.max_body_bytes() - (line_count - 1)
    line_bytes = div(content_bytes, line_count)
    longer_lines = rem(content_bytes, line_count)

    1..line_count
    |> Enum.map(fn index ->
      String.duplicate("r", line_bytes + if(index <= longer_lines, do: 1, else: 0))
    end)
    |> Enum.join("\n")
  end

  defp assert_expected_frame(frame, {:confirmation, confirmation_id}) do
    assert %{frame: :confirmation, payload: %{confirmation_id: ^confirmation_id}} = frame
  end

  defp assert_expected_frame(frame, {:completion, receipt_id}) do
    assert %{frame: :completion, payload: %{input_receipt_id: ^receipt_id}} = frame
  end

  defp assert_expected_frame(frame, {:error, code}) do
    assert %{frame: :error, payload: %{code: ^code}} = frame
  end

  defp assert_expected_frame(frame, {:close, code}) do
    assert %{frame: :close, payload: %{code: ^code}} = frame
  end

  defp detach(socket, client_flow) do
    {:ok, frame, _client_flow} =
      TUIProtocol.send_frame(
        client_flow,
        :client_to_daemon,
        :detach,
        %{reason: :operator_exit}
      )

    :ok = send_term(socket, frame)
    assert %{frame: :close, payload: %{code: :client_detach}} = recv_term(socket)
    :gen_tcp.close(socket)
  end

  defp tui_child do
    AllbertAssist.Channels.Supervisor
    |> Supervisor.which_children()
    |> Enum.find(fn {id, _pid, _type, _modules} -> id == "tui" end)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")
end
