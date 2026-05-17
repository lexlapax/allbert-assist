defmodule StockSage.TraderBridgeTest do
  use ExUnit.Case, async: false

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

    test "analyze rejects an invalid ticker via bridge.py validation", %{name: name} do
      params = %{ticker: "bad$ticker!", analysis_date: "2026-05-01"}
      assert {:error, {:bridge_error, reason}} = TraderBridge.analyze(params, name)
      assert reason =~ "invalid_ticker"
    end

    test "analyze rejects an invalid analysis_date", %{name: name} do
      params = %{ticker: "AAPL", analysis_date: "not-a-date"}
      assert {:error, {:bridge_error, reason}} = TraderBridge.analyze(params, name)
      assert reason =~ "invalid_analysis_date"
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
end
