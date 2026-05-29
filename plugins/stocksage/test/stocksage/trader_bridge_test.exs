defmodule StockSage.TraderBridgeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Settings
  alias StockSage.TraderBridge

  @moduletag :bridge

  setup do
    python = System.find_executable("python3")
    if is_nil(python), do: {:skip, "python3 not available"}, else: :ok
  end

  describe "with bridge enabled" do
    setup do
      put_setting!("stocksage.bridge_enabled", true)
      name = unique_name()
      {:ok, pid} = TraderBridge.start_link(name: name)
      on_exit(fn -> safe_stop(pid) end)
      %{name: name}
    end

    test "ping returns :ok when bridge is running", %{name: name} do
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running
    end

    test "analyze with valid params returns a structured result", %{name: name} do
      # force_stub: true keeps the bridge on the deterministic stub path
      # so the test does not require `tradingagents` in the bridge venv or
      # LLM credentials. The persisted detail row in callers will be
      # labeled `stub: true` for operator visibility.
      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        force_stub: true
      }

      assert {:ok, result} = TraderBridge.analyze(params, name)

      assert result["ticker"] == "AAPL"
      assert result["analysis_date"] == "2026-05-01"
      assert result["engine"] == "tradingagents"
      assert is_binary(result["summary"])
      assert result["truncated"] in [true, false]
      assert result["stub"] == true
      assert is_binary(result["decision"])
    end

    test "analyze without force_stub returns tradingagents_import_failed when " <>
           "tradingagents is not available in the bridge venv",
         %{name: name} do
      # When the bridge's Python interpreter cannot import tradingagents
      # and force_stub is not set, bridge.py returns a loud
      # tradingagents_import_failed error rather than silently degrading
      # to stub mode. This matches the M2 audit closeout posture.
      params = %{ticker: "AAPL", analysis_date: "2026-05-01", engine: "tradingagents"}

      assert {:error, {:bridge_error, reason}} = TraderBridge.analyze(params, name)
      assert reason =~ "tradingagents_import_failed"
    end

    test "analyze rejects an invalid ticker before bridge dispatch", %{name: name} do
      params = %{ticker: "bad$ticker!", analysis_date: "2026-05-01"}
      assert {:error, :invalid_bridge_ticker} = TraderBridge.analyze(params, name)
    end

    test "analyze rejects an invalid analysis_date before bridge dispatch", %{name: name} do
      params = %{ticker: "AAPL", analysis_date: "not-a-date"}
      assert {:error, :invalid_bridge_analysis_date} = TraderBridge.analyze(params, name)
    end

    test "analyze rejects config keys outside the bounded bridge allowlist", %{name: name} do
      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        config: %{"results_dir" => "../../private"}
      }

      assert {:error, {:invalid_bridge_config_key, "results_dir"}} =
               TraderBridge.analyze(params, name)
    end
  end

  describe "with bridge disabled" do
    setup do
      put_setting!("stocksage.bridge_enabled", false)
      on_exit(fn -> put_setting!("stocksage.bridge_enabled", true) end)
      name = unique_name()
      {:ok, pid} = TraderBridge.start_link(name: name)
      on_exit(fn -> safe_stop(pid) end)
      %{name: name}
    end

    test "bridge_status reports :disabled and analyze returns :bridge_disabled", %{name: name} do
      assert TraderBridge.bridge_status(name) == :disabled
      assert {:error, :bridge_disabled} = TraderBridge.ping(name)

      assert {:error, :bridge_disabled} =
               TraderBridge.analyze(%{ticker: "AAPL", analysis_date: "2026-05-01"}, name)
    end
  end

  describe "large bridge response assembly" do
    # v0.22 audit closeout (Gap 2 — large bridge response coverage). Scope
    # note: these tests prove the *buffer assembly path* in handle_info/2,
    # NOT real port/Python integration. They synthesize
    # `{port, {:data, {:noeol, fragment}}}` and `{:eol, last}` messages
    # directly to the GenServer via `send/2`, so the GenServer's framing
    # and pending-caller routing is exercised end-to-end, but the actual
    # Erlang Port + Python stdout pipe is not in the loop. The third
    # validation pass explicitly accepted this as "buffer path proven,"
    # not "real large bridge response proven." A separate operator-run
    # real-bridge verification (see `docs/plans/v0.22-request-flow.md`
    # "Real-Bridge Verification") covers the live integration side. The
    # bridge port is opened with `{:line, 16_384}`, so any single line
    # longer than 16 KB is split into one or more `:noeol` fragments
    # followed by a trailing `:eol`. The existing stub tests stay under
    # 16 KB, so without these synthetic tests the buffer-assembly path
    # would have no automated coverage.
    setup do
      put_setting!("stocksage.bridge_enabled", true)
      name = unique_name()
      {:ok, pid} = TraderBridge.start_link(name: name)
      on_exit(fn -> safe_stop(pid) end)
      %{name: name}
    end

    test "assembles a >16 KB response fragmented across :noeol + :eol deliveries " <>
           "and routes it to the pending caller",
         %{name: name} do
      # Bring the bridge up so the GenServer has a real port reference;
      # the port pattern-match in handle_info/2 requires the inbound
      # message's port term to equal state.port.
      assert :ok = TraderBridge.ping(name)
      state = :sys.get_state(name)
      assert is_port(state.port)

      # Inject a fake pending entry whose `from` is the test process so
      # the GenServer's route_response will GenServer.reply back to us.
      test_pid = self()
      fake_ref = make_ref()
      fake_from = {test_pid, fake_ref}
      fake_id = "large_response_audit_#{System.unique_integer([:positive])}"

      :sys.replace_state(name, fn s ->
        pending = Map.put(s.pending, fake_id, %{from: fake_from, timer: nil})
        %{s | pending: pending}
      end)

      # Build a single-line JSON response well over the 16 KB line limit
      # by stuffing a multi-tens-of-KB summary field. The whole payload
      # must be one JSON object on one line — the bridge's framing is
      # newline-delimited, and only the {:eol, _} terminator triggers
      # route_response.
      large_summary = String.duplicate("A", 60_000)

      response =
        Jason.encode!(%{
          "id" => fake_id,
          "status" => "ok",
          "result" => %{
            "ticker" => "AAPL",
            "analysis_date" => "2026-05-01",
            "engine" => "tradingagents",
            "summary" => large_summary,
            "decision" => "Hold",
            "truncated" => false,
            "stub" => false
          }
        })

      assert byte_size(response) > 16_384,
             "fixture must exceed the bridge's 16 KB line limit to exercise fragmentation"

      # Slice the response into 8 KB fragments and deliver them as
      # `{:noeol, chunk}` followed by a final `{:eol, last_chunk}` to
      # mimic exactly what the Erlang VM produces in {:line, 16_384}
      # mode for an oversize line.
      port = state.port
      chunks = chunk_binary(response, 8_192)
      {leading, [last]} = Enum.split(chunks, -1)

      Enum.each(leading, fn fragment ->
        send(name, {port, {:data, {:noeol, fragment}}})
      end)

      send(name, {port, {:data, {:eol, last}}})

      # The route_response path: decodes the assembled line, looks up the
      # pending entry by id, and replies. GenServer.reply delivers a
      # `{ref, reply}` message to the from's pid.
      assert_receive {^fake_ref, {:ok, result}}, 2_000

      assert result["ticker"] == "AAPL"
      assert result["analysis_date"] == "2026-05-01"
      assert result["decision"] == "Hold"
      assert result["summary"] == large_summary

      # Buffer should be drained on :eol so the next response starts clean.
      final_state = :sys.get_state(name)
      assert final_state.buffer == ""
      refute Map.has_key?(final_state.pending, fake_id)
    end

    test "assembles a response split into many small :noeol fragments before the :eol",
         %{name: name} do
      # Stress the buffer with a long stream of tiny fragments (256 B
      # each) totaling >16 KB. The VM never produces fragments this
      # small in practice, but the buffer-append path should not care
      # about chunk size — only that {:eol, _} terminates the line.
      assert :ok = TraderBridge.ping(name)
      state = :sys.get_state(name)
      assert is_port(state.port)

      test_pid = self()
      fake_ref = make_ref()
      fake_from = {test_pid, fake_ref}
      fake_id = "many_fragments_audit_#{System.unique_integer([:positive])}"

      :sys.replace_state(name, fn s ->
        pending = Map.put(s.pending, fake_id, %{from: fake_from, timer: nil})
        %{s | pending: pending}
      end)

      large_summary = String.duplicate("B", 20_000)

      response =
        Jason.encode!(%{
          "id" => fake_id,
          "status" => "ok",
          "result" => %{
            "ticker" => "MSFT",
            "analysis_date" => "2026-05-01",
            "engine" => "tradingagents",
            "summary" => large_summary,
            "decision" => "Overweight",
            "truncated" => false,
            "stub" => false
          }
        })

      port = state.port
      chunks = chunk_binary(response, 256)
      {leading, [last]} = Enum.split(chunks, -1)

      Enum.each(leading, fn fragment ->
        send(name, {port, {:data, {:noeol, fragment}}})
      end)

      send(name, {port, {:data, {:eol, last}}})

      assert_receive {^fake_ref, {:ok, result}}, 2_000
      assert result["ticker"] == "MSFT"
      assert result["summary"] == large_summary

      final_state = :sys.get_state(name)
      assert final_state.buffer == ""
    end
  end

  describe "crash recovery" do
    setup do
      put_setting!("stocksage.bridge_enabled", true)
      name = unique_name()
      {:ok, pid} = TraderBridge.start_link(name: name)
      on_exit(fn -> safe_stop(pid) end)
      %{name: name, pid: pid}
    end

    test "closing the underlying port marks the bridge :crashed and recovers on next call",
         %{name: name} do
      # Bring the bridge up.
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running

      # Force the port to exit by sending a malformed close signal via Port.close.
      pid = Process.whereis(name)

      :sys.replace_state(pid, fn state ->
        if is_port(state.port), do: Port.close(state.port)
        state
      end)

      # Wait briefly for the {:EXIT, port, ...} message to be processed.
      Process.sleep(50)

      # Subsequent call lazily reopens the port.
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running
    end

    # v0.22 audit closeout (moderate gap 9): the existing test above proves
    # that a subsequent call recovers the port, but does not prove that
    # in-flight callers get :bridge_crashed. The plan's safety story
    # requires both.
    test "in-flight callers receive :bridge_crashed when the port exits mid-flight",
         %{name: name} do
      # Bring the bridge up.
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running

      # Inject a fake pending entry whose `from` is our test process. This
      # represents an in-flight caller waiting on GenServer.call. We bypass
      # actually issuing a Port.command because the stub bridge responds
      # quickly enough that there's no reliable mid-flight window — but the
      # GenServer's mark_crashed/flush_pending logic is what we want to
      # exercise, and a real pending entry has the same shape regardless of
      # how it was registered.
      test_pid = self()
      fake_ref = make_ref()
      fake_from = {test_pid, fake_ref}
      fake_id = "in_flight_audit_test_#{System.unique_integer([:positive])}"

      :sys.replace_state(name, fn state ->
        pending = Map.put(state.pending, fake_id, %{from: fake_from, timer: nil})
        %{state | pending: pending}
      end)

      # Synchronously deliver the :EXIT message to simulate a port crash.
      # handle_info({:EXIT, port, ...}) → mark_crashed → flush_pending →
      # GenServer.reply(fake_from, {:error, :bridge_crashed}).
      state = :sys.get_state(name)
      send(name, {:EXIT, state.port, :test_crash})

      # GenServer.reply delivers a message of shape {ref, reply} to from's pid.
      assert_receive {^fake_ref, {:error, :bridge_crashed}}, 1_000

      # And the bridge should be in :crashed status, ready for lazy recovery
      # on the next call.
      Process.sleep(10)
      assert TraderBridge.bridge_status(name) == :crashed

      # Recovery still works.
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running
    end
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end

  defp unique_name do
    :"stocksage_trader_bridge_test_#{System.unique_integer([:positive])}"
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp chunk_binary(binary, chunk_size)
       when is_binary(binary) and is_integer(chunk_size) and chunk_size > 0 do
    do_chunk_binary(binary, chunk_size, [])
  end

  defp do_chunk_binary(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(binary, chunk_size, acc) when byte_size(binary) <= chunk_size do
    Enum.reverse([binary | acc])
  end

  defp do_chunk_binary(binary, chunk_size, acc) do
    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    do_chunk_binary(rest, chunk_size, [chunk | acc])
  end
end
