defmodule AllbertAssist.CLI.TuiTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Channels.TUI.InputDriver
  alias AllbertAssist.CLI.Tui
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach.TUIProtocol
  alias AllbertAssist.SecurityFixtures.AssertBinding

  @terminal %{columns: 100, rows: 30, color: :ansi256, unicode?: true}

  test "model disclosure is rendered and acknowledged before daemon attachment" do
    with_disclosure_home(fn ->
      :ok = Disclosure.mark_pending(hosted_selection())
      parent = self()

      callbacks =
        callbacks(parent,
          open: fn _profile, _terminal ->
            send(parent, {:ordered_event, :open})
            {:error, :not_available}
          end
        )

      assert {:error, :not_available} =
               Tui.launch(
                 callbacks: callbacks,
                 model_disclosure_output: fn text ->
                   send(parent, {:ordered_event, {:disclosure, text}})
                   :ok
                 end
               )

      assert_receive {:ordered_event, {:disclosure, text}}
      assert text =~ "Your message will leave this device for openai"
      assert_receive {:ordered_event, :open}
      refute Disclosure.pending?(:tui)
    end)
  end

  test "failed disclosure output preserves pending truth and never opens the daemon" do
    with_disclosure_home(fn ->
      :ok = Disclosure.mark_pending(hosted_selection())

      callbacks =
        callbacks(self(),
          open: fn _profile, _terminal -> flunk("daemon opened before disclosure delivery") end
        )

      assert {:error, {:disclosure_render_failed, :closed}} =
               Tui.launch(
                 callbacks: callbacks,
                 model_disclosure_output: fn _text -> {:error, :closed} end
               )

      assert Disclosure.pending?(:tui)

      assert Tui.error_message({:disclosure_render_failed, :closed}) =~
               "no hosted prompt was sent"
    end)
  end

  test "absent daemon is actionable and never mutates terminal or starts input" do
    parent = self()

    callbacks =
      callbacks(parent,
        open: fn profile, terminal ->
          send(parent, {:client_event, {:open, profile, terminal}, self()})
          {:error, :not_available}
        end
      )

    assert {:error, :not_available} = Tui.launch(callbacks: callbacks)
    assert_receive {:client_event, {:open, "default", @terminal}, _client}
    refute_receive {:client_event, :enter_terminal, _client}
    refute_receive {:client_event, :start_input, _client}
    assert Tui.error_message(:not_available) =~ "Start or repair `allbert serve`"
    assert Tui.error_message(:not_available) =~ "did not start an embedded runtime"

    AssertBinding.check!("v121-tui-no-daemon-001", [
      :attach_failure_actionable,
      :terminal_unchanged,
      :embedded_runtime_not_started
    ])
  end

  test "open rejection stays canonical and gives occupied-session guidance" do
    callbacks =
      callbacks(self(),
        open: fn _profile, _terminal ->
          {:error, {:open_rejected, :already_attached, "A TUI session is already attached."}}
        end
      )

    assert {:error, {:open_rejected, :already_attached, _message}} =
             Tui.launch(callbacks: callbacks)

    refute_receive {:client_event, :install_signals, _client}
    refute_receive {:client_event, :enter_terminal, _client}

    assert Tui.error_message({:open_rejected, :already_attached, "ignored"}) =~
             "already attached"
  end

  test "validated snapshot precedes terminal mutation and render precedes cumulative ack" do
    {open_result, server_flow} = session(:fake_socket, 17)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)

    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))

    assert event_index(ready, :install_signals) < event_index(ready, :enter_terminal)
    assert event_index(ready, :enter_terminal) < event_index(ready, :start_input)
    assert event_index(ready, {:write, :any}) < event_index(ready, {:wire, :ack})
    assert Enum.any?(ready, &match?({:prompt, _driver, "allbert> "}, &1))

    initial_ack = wire!(ready, :ack)
    {:ok, server_flow} = accept_client(server_flow, initial_ack)

    {delta, server_flow} =
      daemon_frame(server_flow, :delta, %{
        render_revision: 1,
        mode: :append,
        lines: ["hello from daemon"]
      })

    send(task.pid, {:tcp, :fake_socket, :erlang.term_to_binary(delta)})
    rendered = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))

    assert event_index(rendered, {:write, :any}) < event_index(rendered, {:wire, :ack})
    assert rendered |> write_text() |> String.contains?("hello from daemon")

    delta_ack = wire!(rendered, :ack)
    {:ok, server_flow} = accept_client(server_flow, delta_ack)

    finish_normally(task, :fake_socket, server_flow)
  end

  test "daemon-frame ack failure stops cleanly without exposing retained receipt state" do
    {open_result, server_flow} = session(:ack_failure_socket, 100)
    parent = self()
    {:ok, fail_send} = Agent.start_link(fn -> false end)

    callbacks =
      callbacks(parent,
        open: fn _profile, _terminal -> open_result end,
        send: fn _socket, payload ->
          frame = :erlang.binary_to_term(payload, [:safe])
          send(parent, {:client_event, {:wire, frame}, self()})

          if Agent.get(fail_send, & &1), do: {:error, :closed}, else: :ok
        end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    send(task.pid, {:tui_input_line, self(), "private retained payload"})
    submitted = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    input = wire!(submitted, :input)
    {:ok, server_flow} = accept_client(server_flow, input)

    Agent.update(fail_send, fn _current -> true end)

    {status, _server_flow} =
      daemon_frame(server_flow, :status, %{
        render_revision: 0,
        state: :thinking,
        text: "Input is in progress.",
        input_receipt_id: input.payload.input_receipt_id
      })

    send(task.pid, {:tcp, :ack_failure_socket, :erlang.term_to_binary(status)})

    assert {:error, {:ambiguous_close, {:socket_send_failed, :closed}, 1} = reason} =
             Task.await(task, 5_000)

    refute Tui.error_message(reason) =~ "private retained payload"
    assert_receive {:client_event, :restore_terminal, _client}
    assert_receive {:client_event, {:close, :ack_failure_socket}, _client}
  end

  test "input receipt is generated before send, retained through status, and released on completion" do
    {open_result, server_flow} = session(:receipt_socket, 18)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)

    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    send(task.pid, {:tui_input_line, self(), "  hello receipt  "})
    submitted = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    input = wire!(submitted, :input)

    assert input.payload.text == "hello receipt"
    assert byte_size(input.payload.input_receipt_id) == 22
    receipt_id = input.payload.input_receipt_id
    {:ok, server_flow} = accept_client(server_flow, input)

    {status, server_flow} =
      daemon_frame(server_flow, :status, %{
        render_revision: 0,
        state: :thinking,
        text: "Input is in progress.",
        input_receipt_id: receipt_id
      })

    send(task.pid, {:tcp, :receipt_socket, :erlang.term_to_binary(status)})
    status_events = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(status_events, :ack))

    {completion, server_flow} =
      daemon_frame(server_flow, :completion, %{
        input_receipt_id: receipt_id,
        outcome: :completed,
        duplicate?: false,
        result_ref: nil,
        lines: ["done"]
      })

    send(task.pid, {:tcp, :receipt_socket, :erlang.term_to_binary(completion)})
    completed = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    assert write_text(completed) =~ "Input completed."
    {:ok, server_flow} = accept_client(server_flow, wire!(completed, :ack))

    finish_normally(task, :receipt_socket, server_flow)
  end

  test "only daemon-issued approve and deny ids become confirmation frames" do
    {open_result, server_flow} = session(:confirmation_socket, 19)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)

    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    {confirmation, server_flow} =
      daemon_frame(server_flow, :confirmation, %{
        confirmation_id: "confirm-safe",
        prompt: "Allow the bounded action?",
        expires_at_unix_ms: 9_999_999_999_999
      })

    send(task.pid, {:tcp, :confirmation_socket, :erlang.term_to_binary(confirmation)})
    issued = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    assert write_text(issued) =~ "ALLBERT:DENY:confirm-safe"
    {:ok, server_flow} = accept_client(server_flow, wire!(issued, :ack))

    send(task.pid, {:tui_input_line, self(), "ALLBERT:APPROVE:unknown"})
    unknown = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    refute Enum.any?(unknown, &match?({:wire, _frame}, &1))
    assert write_text(unknown) =~ "not issued by this daemon session"

    send(task.pid, {:tui_input_line, self(), "ALLBERT:DENY:confirm-safe"})
    denied = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    decision = wire!(denied, :confirmation)
    assert decision.payload == %{confirmation_id: "confirm-safe", decision: :deny}
    {:ok, server_flow} = accept_client(server_flow, decision)

    finish_normally(task, :confirmation_socket, server_flow)
  end

  test "punctuation and Unicode confirmation ids round-trip by exact issued-id match" do
    {open_result, server_flow} = session(:unicode_confirmation_socket, 29)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)

    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))
    confirmation_id = "confirm.東京/α:7"

    {confirmation, server_flow} =
      daemon_frame(server_flow, :confirmation, %{
        confirmation_id: confirmation_id,
        prompt: "Allow the precisely identified action?",
        expires_at_unix_ms: 9_999_999_999_999
      })

    send(task.pid, {:tcp, :unicode_confirmation_socket, :erlang.term_to_binary(confirmation)})
    issued = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    assert write_text(issued) =~ "ALLBERT:APPROVE:#{confirmation_id}"
    {:ok, server_flow} = accept_client(server_flow, wire!(issued, :ack))

    send(task.pid, {:tui_input_line, self(), "ALLBERT:APPROVE:#{confirmation_id}"})
    approved = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    decision = wire!(approved, :confirmation)
    assert decision.payload == %{confirmation_id: confirmation_id, decision: :approve}
    {:ok, server_flow} = accept_client(server_flow, decision)

    finish_normally(task, :unicode_confirmation_socket, server_flow)
  end

  test "a daemon confirmation id containing a terminal control fails closed before acknowledgement" do
    {open_result, server_flow} = session(:control_confirmation_socket, 30)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    client = task.pid

    ready = collect_until(client, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    {confirmation, _server_flow} =
      daemon_frame(server_flow, :confirmation, %{
        confirmation_id: "confirm\e]52;c;unsafe\a",
        prompt: "This prompt must never become actionable.",
        expires_at_unix_ms: 9_999_999_999_999
      })

    send(client, {:tcp, :control_confirmation_socket, :erlang.term_to_binary(confirmation)})

    assert {:error, :unrepresentable_confirmation_id} = Task.await(task, 5_000)
    assert_receive {:client_event, :restore_terminal, ^client}
    assert_receive {:client_event, :uninstall_signals, ^client}
    assert_receive {:client_event, {:close, :control_confirmation_socket}, ^client}
    refute_receive {:client_event, {:wire, %{frame: :ack, ack: 2}}, ^client}
  end

  test "a confirmation expanding above the logical-line budget fails before acknowledgement" do
    {open_result, server_flow} = session(:confirmation_line_budget_socket, 34)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    client = task.pid

    ready = collect_until(client, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    {confirmation, _server_flow} =
      daemon_frame(server_flow, :confirmation, %{
        confirmation_id: "too.many.lines",
        prompt: Enum.join(List.duplicate("review", 257), "\n"),
        expires_at_unix_ms: 9_999_999_999_999
      })

    send(client, {
      :tcp,
      :confirmation_line_budget_socket,
      :erlang.term_to_binary(confirmation)
    })

    assert {:error, :client_confirmation_capacity} = Task.await(task, 5_000)
    assert_receive {:client_event, :restore_terminal, ^client}
    assert_receive {:client_event, :uninstall_signals, ^client}
    assert_receive {:client_event, {:close, :confirmation_line_budget_socket}, ^client}
    refute_receive {:client_event, {:wire, %{frame: :ack, ack: 2}}, ^client}
  end

  test "daemon line breaks render structurally while other controls are neutralized" do
    {open_result, server_flow} = session(:terminal_text_socket, 31)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)

    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    dangerous =
      "first\nsecond\r\n\nfourth\rbare \e[31mred\e[0m \e]52;c;clipboard\a suffix"

    {delta, server_flow} =
      daemon_frame(server_flow, :delta, %{
        render_revision: 1,
        mode: :append,
        lines: [dangerous]
      })

    send(task.pid, {:tcp, :terminal_text_socket, :erlang.term_to_binary(delta)})
    static = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    static_text = write_text(static)
    assert static_text =~ "first\nsecond\n\nfourth�bare"
    refute static_text =~ "first�second"
    assert_terminal_controls_neutralized(static_text)
    {:ok, server_flow} = accept_client(server_flow, wire!(static, :ack))

    {status, server_flow} =
      daemon_frame(server_flow, :status, %{
        render_revision: 1,
        state: :thinking,
        text: dangerous,
        input_receipt_id: nil
      })

    send(task.pid, {:tcp, :terminal_text_socket, :erlang.term_to_binary(status)})
    live = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    live_text = write_text(live)
    assert live_text =~ "[thinking] first\n[thinking] second\n[thinking] \n[thinking] fourth�bare"
    assert_terminal_controls_neutralized(live_text)
    {:ok, server_flow} = accept_client(server_flow, wire!(live, :ack))

    {confirmation, server_flow} =
      daemon_frame(server_flow, :confirmation, %{
        confirmation_id: "multiline.confirmation",
        prompt: "Review:\r\nline two\n\nline four\rbare\e[31mred\a",
        expires_at_unix_ms: 9_999_999_999_999
      })

    send(task.pid, {:tcp, :terminal_text_socket, :erlang.term_to_binary(confirmation)})
    confirmation_render = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    confirmation_text = write_text(confirmation_render)
    assert confirmation_text =~ "Review:\nline two\n\nline four�bare�[31mred�"
    assert_terminal_controls_neutralized(confirmation_text)
    {:ok, server_flow} = accept_client(server_flow, wire!(confirmation_render, :ack))

    finish_normally(task, :terminal_text_socket, server_flow)
  end

  test "pre-open and daemon-close error messages never reproduce terminal controls" do
    dangerous = "failure\e[31mred\e[0m\e]52;c;clipboard\a"

    messages = [
      Tui.error_message({:open_rejected, :runtime_unavailable, dangerous}),
      Tui.error_message({:daemon_closed, :runtime_unavailable, dangerous})
    ]

    Enum.each(messages, &assert_terminal_controls_neutralized/1)
  end

  test "aggregate live presentation status and confirmations stay within the terminal budget" do
    {open_result, server_flow} = session(:aggregate_live_socket, 32)
    parent = self()

    callbacks =
      callbacks(parent,
        open: fn _profile, _terminal -> open_result end,
        write_live: fn driver, columns, lines ->
          send(parent, {:client_event, {:live_lines, driver, columns, lines}, self()})
          :ok
        end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    client = task.pid
    ready = collect_until(client, &match?({:prompt, _, _}, &1))
    assert_live_budget(ready)
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    protocol_limit_lines =
      Enum.map(1..256, fn index ->
        String.pad_leading(Integer.to_string(index), 190, "x")
      end)

    {delta, server_flow} =
      daemon_frame(server_flow, :delta, %{
        render_revision: 1,
        mode: :replace_live,
        lines: protocol_limit_lines
      })

    send(task.pid, {:tcp, :aggregate_live_socket, :erlang.term_to_binary(delta)})
    replaced = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    assert_live_budget(replaced)
    {:ok, server_flow} = accept_client(server_flow, wire!(replaced, :ack))

    {status, server_flow} =
      daemon_frame(server_flow, :status, %{
        render_revision: 1,
        state: :thinking,
        text: String.duplicate("s", 4_096),
        input_receipt_id: nil
      })

    send(task.pid, {:tcp, :aggregate_live_socket, :erlang.term_to_binary(status)})
    status_render = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    assert_live_budget(status_render)
    {:ok, server_flow} = accept_client(server_flow, wire!(status_render, :ack))

    {confirmation, server_flow} =
      daemon_frame(server_flow, :confirmation, %{
        confirmation_id: "aggregate.confirmation",
        prompt: String.duplicate("p", 12 * 1_024),
        expires_at_unix_ms: 9_999_999_999_999
      })

    send(task.pid, {:tcp, :aggregate_live_socket, :erlang.term_to_binary(confirmation)})
    confirmation_render = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    assert_live_budget(confirmation_render)
    {:ok, server_flow} = accept_client(server_flow, wire!(confirmation_render, :ack))

    finish_normally(task, :aggregate_live_socket, server_flow)
  end

  test "socket loss restores first and one attended reconnect reuses the exact receipt" do
    {first_open, _first_server_flow} = session(:first_socket, 20)
    {second_open, second_server_flow} = session(:second_socket, 21)
    opens = start_supervised!({Agent, fn -> [first_open, second_open] end})
    parent = self()

    callbacks =
      callbacks(parent,
        open: fn profile, terminal ->
          result = Agent.get_and_update(opens, fn [next | rest] -> {next, rest} end)
          send(parent, {:client_event, {:open, profile, terminal, elem(result, 1)}, self()})
          result
        end,
        reconnect: fn reason, count ->
          send(parent, {:client_event, {:reconnect, reason, count}, self()})
          true
        end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    _ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))

    send(task.pid, {:tui_input_line, self(), "reconcile me"})
    submitted = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    first_input = wire!(submitted, :input)

    send(task.pid, {:tcp_closed, :first_socket})

    reattached =
      collect_until(task.pid, fn
        {:prompt, _driver, _prompt} ->
          true

        _event ->
          false
      end)

    assert event_index(reattached, :restore_terminal) <
             event_index(reattached, {:reconnect, :any})

    replay = wire!(reattached, :input)
    assert replay.payload == first_input.payload
    assert replay.payload.input_receipt_id == first_input.payload.input_receipt_id

    client_frames = Enum.filter(reattached, &match?({:wire, _frame}, &1))

    second_server_flow =
      Enum.reduce(client_frames, second_server_flow, fn {:wire, frame}, flow ->
        {:ok, flow} = accept_client(flow, frame)
        flow
      end)

    {completion, second_server_flow} =
      daemon_frame(second_server_flow, :completion, %{
        input_receipt_id: replay.payload.input_receipt_id,
        outcome: :completed,
        duplicate?: true,
        result_ref: nil,
        lines: []
      })

    send(task.pid, {:tcp, :second_socket, :erlang.term_to_binary(completion)})
    completed = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    {:ok, second_server_flow} = accept_client(second_server_flow, wire!(completed, :ack))

    finish_normally(task, :second_socket, second_server_flow)
  end

  test "an attended reconnect replays exactly 32 retained receipts without losing one to the initial ack" do
    {first_open, _first_server_flow} = session(:replay_limit_first_socket, 25)
    {second_open, _second_server_flow} = session(:replay_limit_second_socket, 26)
    opens = start_supervised!({Agent, fn -> [first_open, second_open] end})

    callbacks =
      callbacks(self(),
        open: fn _profile, _terminal ->
          Agent.get_and_update(opens, fn [next | rest] -> {next, rest} end)
        end,
        reconnect: fn _reason, _count -> true end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    _ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))

    originals =
      Enum.map(1..32, fn index ->
        send(task.pid, {:tui_input_line, self(), "receipt at replay limit #{index}"})

        submitted =
          if index == 32 do
            collect_until(task.pid, &capacity_paused_event?/1)
          else
            collect_until(task.pid, &match?({:prompt, _, _}, &1))
          end

        wire!(submitted, :input)
      end)

    send(task.pid, {:tcp_closed, :replay_limit_first_socket})
    reattached = collect_until(task.pid, &capacity_paused_event?/1, 5_000)
    replays = wire_frames(reattached, :input)

    assert length(replays) == 32
    assert Enum.map(replays, & &1.payload) == Enum.map(originals, & &1.payload)
    assert replays |> Enum.map(& &1.payload.input_receipt_id) |> Enum.uniq() |> length() == 32

    send(task.pid, {:tcp_closed, :replay_limit_second_socket})

    assert {:error, {:ambiguous_close, :daemon_connection_closed, 32}} =
             Task.await(task, 5_000)

    # The attended-interrupt test in this suite proves cancellation is sent
    # before detach; together they bind one release pressure contract.
    AssertBinding.check!("v121-tui-pressure-cancel-001", [
      :count_bound_pauses,
      :next_line_admitted_once,
      :cancel_precedes_detach
    ])
  end

  test "completion render failure retains the unresolved receipt and does not acknowledge completion" do
    {open_result, server_flow} = session(:completion_render_socket, 27)
    parent = self()

    callbacks =
      callbacks(parent,
        open: fn _profile, _terminal -> open_result end,
        write_input: fn driver, data ->
          text = IO.iodata_to_binary(data)
          send(parent, {:client_event, {:write, driver, text}, self()})

          if String.contains?(text, "completion that cannot render"),
            do: {:error, :device_unavailable},
            else: :ok
        end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    client = task.pid
    ready = collect_until(client, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    send(client, {:tui_input_line, self(), "retain on render failure"})
    submitted = collect_until(client, &match?({:prompt, _, _}, &1))
    input = wire!(submitted, :input)
    {:ok, server_flow} = accept_client(server_flow, input)

    {completion, _server_flow} =
      daemon_frame(server_flow, :completion, %{
        input_receipt_id: input.payload.input_receipt_id,
        outcome: :completed,
        duplicate?: false,
        result_ref: nil,
        lines: ["completion that cannot render"]
      })

    send(client, {:tcp, :completion_render_socket, :erlang.term_to_binary(completion)})

    assert {:error, {:ambiguous_close, {:terminal_render_failed, :device_unavailable}, 1}} =
             Task.await(task, 5_000)

    refute_receive {:client_event, {:wire, %{frame: :ack, ack: 2}}, ^client}
  end

  test "accepted reconciliation followed by a second open failure reports the unresolved count" do
    {first_open, _server_flow} = session(:reconnect_open_failure_socket, 28)
    opens = start_supervised!({Agent, fn -> [first_open, {:error, :not_available}] end})

    callbacks =
      callbacks(self(),
        open: fn _profile, _terminal ->
          Agent.get_and_update(opens, fn [next | rest] -> {next, rest} end)
        end,
        reconnect: fn _reason, 1 -> true end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    _ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))

    send(task.pid, {:tui_input_line, self(), "unresolved across failed reopen"})
    _submitted = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    send(task.pid, {:tcp_closed, :reconnect_open_failure_socket})

    assert {:error, {:ambiguous_close, {:reconnect_failed, :not_available}, 1}} =
             Task.await(task, 5_000)
  end

  test "receipt pressure pauses at the frozen count bound and admits the next line after completion" do
    {open_result, server_flow} = session(:pressure_socket, 22)

    callbacks =
      callbacks(self(),
        open: fn _profile, _terminal -> open_result end,
        reconnect: fn _reason, _count -> false end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    submitted =
      Enum.flat_map(1..32, fn index ->
        send(task.pid, {:tui_input_line, self(), "queued input #{index}"})

        if index == 32 do
          collect_until(task.pid, &capacity_paused_event?/1)
        else
          collect_until(task.pid, &match?({:prompt, _, _}, &1))
        end
      end)

    inputs = wire_frames(submitted, :input)
    assert length(inputs) == 32

    server_flow =
      Enum.reduce(inputs, server_flow, fn input, flow ->
        {:ok, flow} = accept_client(flow, input)
        flow
      end)

    assert Enum.any?(submitted, &match?({:pause, _driver}, &1))
    assert write_text(submitted) =~ "terminal input is paused"

    first = hd(inputs)

    {completion, server_flow} =
      daemon_frame(server_flow, :completion, %{
        input_receipt_id: first.payload.input_receipt_id,
        outcome: :completed,
        duplicate?: false,
        result_ref: nil,
        lines: []
      })

    send(task.pid, {:tcp, :pressure_socket, :erlang.term_to_binary(completion)})
    resumed = collect_until(task.pid, &match?({:prompt, _, "allbert> "}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(resumed, :ack))

    send(task.pid, {:tui_input_line, self(), "queued input 33"})
    admitted = collect_until(task.pid, &capacity_paused_event?/1)
    thirty_third = wire!(admitted, :input)

    assert thirty_third.payload.text == "queued input 33"
    assert {:ok, _server_flow} = accept_client(server_flow, thirty_third)

    send(task.pid, {:tcp_closed, :pressure_socket})

    assert {:error, {:ambiguous_close, :daemon_connection_closed, 32}} =
             Task.await(task, 5_000)
  end

  test "byte-bound receipt custody replays every admitted maximum-size input" do
    {first_open, _first_server_flow} = session(:byte_replay_first_socket, 37)
    {second_open, _second_server_flow} = session(:byte_replay_second_socket, 38)
    opens = start_supervised!({Agent, fn -> [first_open, second_open] end})

    callbacks =
      callbacks(self(),
        open: fn _profile, _terminal ->
          Agent.get_and_update(opens, fn [next | rest] -> {next, rest} end)
        end,
        reconnect: fn _reason, _count -> true end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    _ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    maximum_input = String.duplicate("x", 32_000)

    originals =
      Enum.map(1..8, fn index ->
        send(task.pid, {:tui_input_line, self(), maximum_input})

        submitted =
          if index == 8 do
            collect_until(task.pid, &capacity_paused_event?/1, 5_000)
          else
            collect_until(task.pid, &match?({:prompt, _, _}, &1), 5_000)
          end

        wire!(submitted, :input)
      end)

    send(task.pid, {:tcp_closed, :byte_replay_first_socket})
    reattached = collect_until(task.pid, &capacity_paused_event?/1, 5_000)
    replays = wire_frames(reattached, :input)

    assert length(replays) == 8
    assert Enum.map(replays, & &1.payload) == Enum.map(originals, & &1.payload)

    send(task.pid, {:tcp_closed, :byte_replay_second_socket})

    assert {:error, {:ambiguous_close, :daemon_connection_closed, 8}} =
             Task.await(task, 5_000)
  end

  test "partial terminal setup still invokes the single restoration path" do
    {open_result, _server_flow} = session(:setup_socket, 23)
    parent = self()

    callbacks =
      callbacks(parent,
        open: fn _profile, _terminal -> open_result end,
        enter_terminal: fn ->
          send(parent, {:client_event, :enter_terminal, self()})
          {:error, :write_failed}
        end
      )

    assert {:error, {:terminal_setup_failed, :write_failed}} =
             Tui.launch(callbacks: callbacks)

    assert_receive {:client_event, :restore_terminal, _client}
    assert_receive {:client_event, :uninstall_signals, _client}
    assert_receive {:client_event, {:close, :setup_socket}, _client}
    refute_receive {:client_event, :start_input, _client}
  end

  test "unexpected input driver exit restores the terminal and closes the attachment" do
    {open_result, _server_flow} = session(:driver_exit_socket, 24)
    parent = self()

    driver =
      spawn(fn ->
        receive do
          :fail -> exit(:reader_failed)
        end
      end)

    callbacks =
      callbacks(parent,
        open: fn _profile, _terminal -> open_result end,
        start_input: fn _owner, _terminal ->
          send(parent, {:client_event, :start_input, self()})
          {:ok, driver}
        end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    _ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    send(driver, :fail)

    assert {:error, {:input_driver_stopped, :reader_failed}} = Task.await(task, 5_000)
    assert_receive {:client_event, :restore_terminal, _client}
    assert_receive {:client_event, :uninstall_signals, _client}
    assert_receive {:client_event, {:close, :driver_exit_socket}, _client}
  end

  test "demand-driven input pause retains the one in-flight character" do
    parent = self()

    reader =
      spawn(fn ->
        receive do
          {:reader_ready, driver} -> reader_loop(parent, driver)
        end
      end)

    start_reader = fn driver, _read_fun ->
      send(reader, {:reader_ready, driver})
      {:ok, reader}
    end

    assert {:ok, driver} =
             InputDriver.start(self(),
               enable_raw: fn -> :ok end,
               disable_raw: fn -> :ok end,
               start_reader: start_reader,
               output_fun: fn _data -> :ok end
             )

    InputDriver.prompt(driver, "allbert:default> ")
    assert_receive {:reader_demand, ^driver}

    assert :ok = InputDriver.pause(driver)
    send(driver, {:tui_input_driver_char, reader, "a"})
    refute_receive {:reader_demand, ^driver}, 50

    assert :ok = InputDriver.resume(driver)
    assert_receive {:reader_demand, ^driver}
    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:tui_input_line, ^driver, "a"}

    GenServer.stop(driver)
  end

  test "paused single-submission input arms one read and defers Ctrl-C until resume" do
    parent = self()

    reader =
      spawn(fn ->
        receive do
          {:reader_ready, driver} -> reader_loop(parent, driver)
        end
      end)

    start_reader = fn driver, _read_fun ->
      send(reader, {:reader_ready, driver})
      {:ok, reader}
    end

    assert {:ok, driver} =
             InputDriver.start(self(),
               enable_raw: fn -> :ok end,
               disable_raw: fn -> :ok end,
               start_reader: start_reader,
               single_submission?: true,
               output_fun: fn _data -> :ok end
             )

    InputDriver.prompt(driver, "allbert:pressure> ")
    assert_receive {:reader_demand, ^driver}
    send(driver, {:tui_input_driver_char, reader, "x"})
    assert_receive {:reader_demand, ^driver}
    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:tui_input_line, ^driver, "x"}
    refute_receive {:reader_demand, ^driver}, 50

    assert :ok = InputDriver.pause(driver)
    assert_receive {:reader_demand, ^driver}
    send(driver, {:tui_input_driver_char, reader, <<3>>})
    refute_receive {:reader_demand, ^driver}, 50
    refute_receive {:tui_input_quit, ^driver, :ctrl_c}, 50

    assert :ok = InputDriver.resume(driver)
    assert_receive {:tui_input_quit, ^driver, :ctrl_c}
    refute_receive {:reader_demand, ^driver}, 50

    GenServer.stop(driver)
  end

  test "input driver enforces its byte cap and ignores C1 control characters" do
    parent = self()

    reader =
      spawn(fn ->
        receive do
          {:reader_ready, driver} -> reader_loop(parent, driver)
        end
      end)

    start_reader = fn driver, _read_fun ->
      send(reader, {:reader_ready, driver})
      {:ok, reader}
    end

    assert {:ok, driver} =
             InputDriver.start(self(),
               enable_raw: fn -> :ok end,
               disable_raw: fn -> :ok end,
               start_reader: start_reader,
               max_buffer_bytes: 4,
               output_fun: fn data ->
                 output = IO.iodata_to_binary(data)
                 if output == "\a", do: send(parent, {:driver_bell, self()})
                 :ok
               end
             )

    on_exit(fn ->
      if Process.alive?(driver), do: GenServer.stop(driver)
    end)

    InputDriver.prompt(driver, "allbert:default> ")
    assert_receive {:reader_demand, ^driver}

    Enum.each(String.graphemes("abcd"), fn char ->
      send(driver, {:tui_input_driver_char, reader, char})
    end)

    send(driver, {:tui_input_driver_char, reader, "e"})
    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:tui_input_line, ^driver, "abcd"}
    assert_receive {:driver_bell, ^driver}

    InputDriver.prompt(driver, "allbert:default> ")
    send(driver, {:tui_input_driver_char, reader, <<0xC2, 0x80>>})
    send(driver, {:tui_input_driver_char, reader, "z"})
    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:tui_input_line, ^driver, "z"}
    refute_receive {:driver_bell, ^driver}, 50
  end

  test "queued confirmation custody survives pressure and Ctrl-C emits cancel before detach" do
    {open_result, server_flow} = session(:confirmation_custody_socket, 33)
    dimensions = start_supervised!({Agent, fn -> 100 end})

    callbacks =
      callbacks(self(),
        open: fn _profile, _terminal -> open_result end,
        dimensions: fn ->
          columns = Agent.get_and_update(dimensions, fn current -> {current + 1, current + 1} end)
          {:ok, %{columns: columns, rows: 30}}
        end
      )

    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)
    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    initial_ack = wire!(ready, :ack)

    resizes =
      Enum.map(101..132, fn expected_columns ->
        send(task.pid, :tui_resize_poll)
        resized = collect_until(task.pid, &match?({:wire, %{frame: :resize}}, &1))
        resize = wire!(resized, :resize)
        assert resize.payload == %{columns: expected_columns, rows: 30}
        resize
      end)

    confirmation_id = "queued.confirmation"

    {confirmation, server_flow} =
      daemon_frame(server_flow, :confirmation, %{
        confirmation_id: confirmation_id,
        prompt: "Keep this confirmation in client custody under pressure.",
        expires_at_unix_ms: 9_999_999_999_999
      })

    send(task.pid, {:tcp, :confirmation_custody_socket, :erlang.term_to_binary(confirmation)})
    issued = collect_until(task.pid, &match?({:wire, %{frame: :ack}}, &1))
    confirmation_ack = wire!(issued, :ack)

    server_flow =
      Enum.reduce([initial_ack | resizes] ++ [confirmation_ack], server_flow, fn frame, flow ->
        {:ok, flow} = accept_client(flow, frame)
        flow
      end)

    send(task.pid, {:tui_input_line, self(), "ALLBERT:DENY:#{confirmation_id}"})

    pressured =
      collect_until(
        task.pid,
        fn
          {:live, _driver, _columns, text} -> String.contains?(text, "Transport backpressure")
          _event -> false
        end,
        5_000
      )

    refute Enum.any?(pressured, &match?({:wire, %{frame: :confirmation}}, &1))

    {window_ack, server_flow} =
      daemon_frame(server_flow, :status, %{
        render_revision: 0,
        state: :confirming,
        text: "Transport window acknowledged.",
        input_receipt_id: nil
      })

    send(task.pid, {:tcp, :confirmation_custody_socket, :erlang.term_to_binary(window_ack)})
    released = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    decision = wire!(released, :confirmation)
    status_ack = wire!(released, :ack)
    assert decision.payload == %{confirmation_id: confirmation_id, decision: :deny}

    send(task.pid, {:tui_input_quit, self(), :ctrl_c})
    interrupted = collect_until(task.pid, &match?({:wire, %{frame: :detach}}, &1))
    cancel = wire!(interrupted, :cancel)
    detach = wire!(interrupted, :detach)

    assert event_index(interrupted, {:wire, :cancel}) <
             event_index(interrupted, {:wire, :detach})

    assert cancel.payload == %{reason: :operator_interrupt}
    assert detach.payload == %{reason: :operator_exit}

    {:ok, server_flow} = accept_client(server_flow, decision)
    {:ok, server_flow} = accept_client(server_flow, status_ack)
    {:ok, server_flow} = accept_client(server_flow, cancel)
    {:ok, server_flow} = accept_client(server_flow, detach)

    {close, _server_flow} =
      daemon_frame(server_flow, :close, %{code: :client_detach, message: "Detached."})

    send(task.pid, {:tcp, :confirmation_custody_socket, :erlang.term_to_binary(close)})
    assert :ok = Task.await(task, 5_000)
  end

  test "idle Ctrl-C detaches without manufacturing a cancellation" do
    {open_result, server_flow} = session(:idle_ctrl_c_socket, 37)
    callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
    task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)

    ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
    {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

    send(task.pid, {:tui_input_quit, self(), :ctrl_c})
    detaching = collect_until(task.pid, &match?({:wire, %{frame: :detach}}, &1))
    detach = wire!(detaching, :detach)

    refute Enum.any?(detaching, &match?({:wire, %{frame: :cancel}}, &1))
    assert detach.payload == %{reason: :operator_exit}
    {:ok, server_flow} = accept_client(server_flow, detach)

    {close, _server_flow} =
      daemon_frame(server_flow, :close, %{code: :client_detach, message: "Detached."})

    send(task.pid, {:tcp, :idle_ctrl_c_socket, :erlang.term_to_binary(close)})
    assert :ok = Task.await(task, 5_000)
  end

  test "handled SIGTERM and SIGHUP detach and restore the terminal lifecycle" do
    Enum.each([{:sigterm, :sigterm_socket, 34}, {:sighup, :sighup_socket, 35}], fn
      {signal, socket, byte} ->
        {open_result, server_flow} = session(socket, byte)
        callbacks = callbacks(self(), open: fn _profile, _terminal -> open_result end)
        task = Task.async(fn -> Tui.launch(callbacks: callbacks) end)

        ready = collect_until(task.pid, &match?({:prompt, _, _}, &1))
        {:ok, server_flow} = accept_client(server_flow, wire!(ready, :ack))

        acknowledgement_ref = make_ref()
        send(task.pid, {:tui_signal, signal, {self(), acknowledgement_ref}})
        detaching = collect_until(task.pid, &match?({:wire, %{frame: :detach}}, &1))
        detach = wire!(detaching, :detach)
        assert detach.payload == %{reason: :operator_exit}
        {:ok, server_flow} = accept_client(server_flow, detach)

        {close, _server_flow} =
          daemon_frame(server_flow, :close, %{code: :client_detach, message: "Detached."})

        send(task.pid, {:tcp, socket, :erlang.term_to_binary(close)})
        assert :ok = Task.await(task, 5_000)

        teardown = collect_until(task.pid, &(&1 == {:close, socket}))

        assert event_index(teardown, :restore_terminal) <
                 index_of(teardown, &(&1 == :uninstall_signals))

        assert index_of(teardown, &(&1 == :uninstall_signals)) <
                 index_of(teardown, &(&1 == {:close, socket}))

        assert_receive {:tui_terminal_restored, ^acknowledgement_ref}
    end)

    # The setup-failure test exercises the same restoration path; the operator
    # request flow supplies recovery for uncatchable termination.
    AssertBinding.check!("v121-tui-terminal-restore-001", [
      :setup_failure_restores,
      :signals_restore_before_close,
      :manual_recovery_documented
    ])
  end

  test "partial signal installation failure closes the attachment before terminal mutation" do
    {open_result, _server_flow} = session(:partial_signal_socket, 36)
    parent = self()

    callbacks =
      callbacks(parent,
        open: fn _profile, _terminal -> open_result end,
        install_signals: fn _owner ->
          send(parent, {:client_event, {:signal_installed, :sigterm}, self()})
          send(parent, {:client_event, {:partial_signal_cleanup, :sigterm}, self()})
          {:error, {:sighup, :not_supported}}
        end
      )

    assert {:error, {:signal_setup_failed, {:sighup, :not_supported}}} =
             Tui.launch(callbacks: callbacks)

    assert_receive {:client_event, {:signal_installed, :sigterm}, _client}
    assert_receive {:client_event, {:partial_signal_cleanup, :sigterm}, _client}
    assert_receive {:client_event, {:close, :partial_signal_socket}, _client}
    refute_receive {:client_event, :enter_terminal, _client}
    refute_receive {:client_event, :restore_terminal, _client}
    refute_receive {:client_event, :start_input, _client}
    refute_receive {:client_event, :uninstall_signals, _client}
  end

  defp callbacks(parent, overrides) do
    base = %{
      terminal_info: fn -> {:ok, @terminal} end,
      dimensions: fn -> {:ok, Map.take(@terminal, [:columns, :rows])} end,
      open: fn _profile, _terminal -> elem(session(:default_socket, 99), 0) end,
      setopts: fn socket, opts ->
        send(parent, {:client_event, {:setopts, socket, opts}, self()})
        :ok
      end,
      send: fn _socket, payload ->
        frame = :erlang.binary_to_term(payload, [:safe])
        send(parent, {:client_event, {:wire, frame}, self()})
        :ok
      end,
      close: fn socket ->
        send(parent, {:client_event, {:close, socket}, self()})
        :ok
      end,
      enter_terminal: fn ->
        send(parent, {:client_event, :enter_terminal, self()})
        :ok
      end,
      restore_terminal: fn ->
        send(parent, {:client_event, :restore_terminal, self()})
        :ok
      end,
      install_signals: fn _owner ->
        send(parent, {:client_event, :install_signals, self()})
        {:ok, :signals}
      end,
      uninstall_signals: fn _token ->
        send(parent, {:client_event, :uninstall_signals, self()})
        :ok
      end,
      start_resize_poll: fn -> :disabled end,
      stop_resize_poll: fn _token -> :ok end,
      start_input: fn _owner, _terminal ->
        send(parent, {:client_event, :start_input, self()})
        {:ok, parent}
      end,
      stop_input: fn driver ->
        send(parent, {:client_event, {:stop_input, driver}, self()})
        :ok
      end,
      prompt_input: fn driver, prompt ->
        send(parent, {:client_event, {:prompt, driver, prompt}, self()})
        :ok
      end,
      write_input: fn driver, data ->
        send(parent, {:client_event, {:write, driver, IO.iodata_to_binary(data)}, self()})
        :ok
      end,
      write_live: fn driver, columns, lines ->
        text = lines |> Enum.intersperse("\n") |> IO.iodata_to_binary()
        send(parent, {:client_event, {:live, driver, columns, text}, self()})
        :ok
      end,
      pause_input: fn driver ->
        send(parent, {:client_event, {:pause, driver}, self()})
        :ok
      end,
      resume_input: fn driver ->
        send(parent, {:client_event, {:resume, driver}, self()})
        :ok
      end,
      reconnect: fn reason, count ->
        send(parent, {:client_event, {:reconnect, reason, count}, self()})
        false
      end
    }

    Map.merge(base, Map.new(overrides))
  end

  defp session(socket, byte) do
    session_id = :binary.copy(<<byte>>, 32)
    {:ok, server_flow} = TUIProtocol.new_flow(session_id)

    {:ok, snapshot, server_flow} =
      TUIProtocol.send_frame(server_flow, :daemon_to_client, :snapshot, %{
        render_revision: 0,
        state: :idle,
        lines: [],
        gap?: false
      })

    {:ok, client_flow} = TUIProtocol.new_flow(session_id)
    {:ok, client_flow} = TUIProtocol.accept_frame(client_flow, :daemon_to_client, snapshot)
    {{:ok, socket, snapshot, client_flow}, server_flow}
  end

  defp daemon_frame(server_flow, frame, payload) do
    {:ok, envelope, server_flow} =
      TUIProtocol.send_frame(server_flow, :daemon_to_client, frame, payload)

    {envelope, server_flow}
  end

  defp accept_client(server_flow, frame),
    do: TUIProtocol.accept_frame(server_flow, :client_to_daemon, frame)

  defp finish_normally(task, socket, server_flow) do
    send(task.pid, {:tui_input_line, self(), "/quit"})
    detached = collect_until(task.pid, &match?({:wire, %{frame: :detach}}, &1))
    detach = wire!(detached, :detach)
    {:ok, server_flow} = accept_client(server_flow, detach)

    {close, _server_flow} =
      daemon_frame(server_flow, :close, %{code: :client_detach, message: "Detached."})

    send(task.pid, {:tcp, socket, :erlang.term_to_binary(close)})
    assert :ok = Task.await(task, 5_000)
    assert_receive {:client_event, :restore_terminal, _client}
  end

  defp collect_until(client, predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_until(client, predicate, deadline, [])
  end

  defp do_collect_until(client, predicate, deadline, events) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:client_event, event, ^client} ->
        events = events ++ [event]

        if predicate.(event),
          do: events,
          else: do_collect_until(client, predicate, deadline, events)
    after
      remaining -> flunk("timed out waiting for client event; received #{inspect(events)}")
    end
  end

  defp capacity_paused_event?({:live, _driver, _columns, text}),
    do: String.contains?(text, "terminal input is paused")

  defp capacity_paused_event?(_event), do: false

  defp wire!(events, frame) do
    case Enum.find(events, &match?({:wire, %{frame: ^frame}}, &1)) do
      {:wire, envelope} -> envelope
      nil -> flunk("missing #{frame} wire frame in #{inspect(events)}")
    end
  end

  defp wire_frames(events, frame) do
    Enum.flat_map(events, fn
      {:wire, %{frame: ^frame} = envelope} -> [envelope]
      _event -> []
    end)
  end

  defp assert_live_budget(events) do
    lines =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:live_lines, _driver, _columns, lines} -> lines
        _event -> nil
      end)

    assert is_list(lines), "missing bounded live-region render in #{inspect(events)}"
    assert length(lines) <= 256

    assert Enum.reduce(lines, 0, fn line, bytes -> bytes + byte_size(line) + 2 end) <=
             48 * 1_024
  end

  defp assert_terminal_controls_neutralized(text) do
    refute String.contains?(text, <<27>>)
    refute String.contains?(text, <<7>>)
    refute String.contains?(text, <<0xC2, 0x80>>)
    assert String.valid?(text)
  end

  defp write_text(events) do
    events
    |> Enum.flat_map(fn
      {:write, _driver, text} -> [text]
      {:live, _driver, _columns, text} -> [text]
      _event -> []
    end)
    |> Enum.join()
  end

  defp event_index(events, :install_signals), do: index_of(events, &(&1 == :install_signals))
  defp event_index(events, :enter_terminal), do: index_of(events, &(&1 == :enter_terminal))
  defp event_index(events, :start_input), do: index_of(events, &(&1 == :start_input))

  defp event_index(events, {:write, :any}),
    do: index_of(events, &match?({:write, _driver, _text}, &1))

  defp event_index(events, {:wire, frame}),
    do: index_of(events, &match?({:wire, %{frame: ^frame}}, &1))

  defp event_index(events, {:reconnect, :any}),
    do: index_of(events, &match?({:reconnect, _reason, _count}, &1))

  defp event_index(events, :restore_terminal), do: index_of(events, &(&1 == :restore_terminal))

  defp index_of(events, predicate) do
    Enum.find_index(events, predicate) || flunk("missing event in #{inspect(events)}")
  end

  defp hosted_selection do
    %{
      profile: "fast",
      provider: "openai",
      provider_class: :hosted,
      verification: :configured_unverified
    }
  end

  defp with_disclosure_home(fun) do
    saved_paths = Application.get_env(:allbert_assist, Paths)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-disclosure-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)

    try do
      fun.()
    after
      if saved_paths,
        do: Application.put_env(:allbert_assist, Paths, saved_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(root)
    end
  end

  defp reader_loop(parent, driver) do
    receive do
      {:tui_input_driver_read, ^driver} ->
        send(parent, {:reader_demand, driver})
        reader_loop(parent, driver)

      {:tui_input_driver_stop, ^driver} ->
        :ok
    end
  end
end
